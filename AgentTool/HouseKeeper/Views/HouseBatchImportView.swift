import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// MARK: - v1.58/v1.59 批量录入：房源清单导入 / 媒体包导入 / 扫描补录

/// 批量导入的单个房源项（预览用）
struct BatchImportItem: Identifiable {
    let id = UUID()
    var rawRoomNo = ""          // v1.61 预览回显：CSV 原始输入 / zip·目录名（用户写什么显示什么）
    var roomNo: String          // 房号本体（不带 2-/1- 前缀；tower 单独记录）
    var tower: Int
    var landlord = ""
    var layout = ""
    var price = 0
    var password = ""
    var remark = ""
    var statusRaw = HouseStatus.available.rawValue
    var mediaDirKey: String?    // 媒体来源目录（zip 解压临时目录 或 media/ 下已有目录）
    var duplicate = false       // 已收录（同座同房号且未进回收站）
    var diskFileCount = 0       // 目录内媒体文件数
    var existingRecordCount = 0 // 已收录房已有的 MediaItem 记录数
    var missingRecordCount = 0  // 待补记录数（磁盘有、记录没有）
}

/// 批量导入结果汇总
struct BatchImportSummary {
    var created = 0            // 新建房源
    var skippedDuplicate = 0   // 跳过重复
    var mediaAttached = 0      // 补挂媒体的房源数
    var mediaFiles = 0         // 复制/补建的媒体文件数
    var errors: [String] = []
}

/// v1.59：批量录入页（房源列表右上角「批量导入」进入）
/// 三个模式：
///  1. 清单导入：粘贴 CSV（房号,座号,房东,户型,租金,密码,备注,状态）或从文件 App 选 .csv/.txt；可导出模板
///  2. 媒体包导入：选 zip（根 = 房号目录，每目录放照片视频）
///  3. 扫描补录：扫描 Documents/media/ 下已存在的房号目录，自动建房源/补媒体
/// v1.59 修复：文件选择改用 UIKit 文档选择器（SwiftUI fileImporter 在 sheet 内无反应）；
///            扫描补录只补缺失记录（不再复制文件，根治重复提示补媒体）；解析预览每行写清动作
struct HouseBatchImportView: View {
    @Environment(\.houseModelContext) private var houseModelContext
    @Environment(\.dismiss) private var dismiss

    enum Mode: String, CaseIterable, Identifiable {
        case list = "清单导入"
        case zip = "媒体包导入"
        case scan = "扫描补录"
        var id: String { rawValue }
    }
    @State private var mode: Mode = .list

    // —— 清单导入 ——
    @State private var csvText = ""
    @State private var previewItems: [BatchImportItem] = []
    @State private var parseInfo = ""

    // —— 媒体包导入 ——
    @State private var pickedZip: URL?
    @State private var zipTempRoot: URL?
    @State private var zipItems: [BatchImportItem] = []
    @State private var zipParseInfo = ""
    @State private var zipErrorHint = ""   // v1.69：媒体包无前缀目录提示

    // —— 扫描补录 ——
    @State private var scanItems: [BatchImportItem] = []
    @State private var scanInfo = ""
    @State private var scanBadHint = ""   // v1.69：扫描无前缀目录提示

    // —— 文件选择（v1.59：UIKit 文档选择器，替代无反应的 fileImporter） ——
    enum PickerTarget: String, Identifiable {
        case csv, zip
        var id: String { rawValue }
        var types: [UTType] {
            switch self {
            case .csv: return [.commaSeparatedText, .plainText, .text, .data]
            // v1.61：支持 zip / 通用归档 / 直接选文件夹（媒体包可不压缩）
            case .zip: return [.zip, .archive, .folder, .data]
            }
        }
    }
    @State private var activePicker: PickerTarget?
    @State private var templateURL: URL?
    @State private var pickedIsFolder = false   // v1.61：所选 zip 实为文件夹时标记

    // —— 通用 ——
    @State private var isImporting = false
    // v1.71（#87/#97）：文档选择器延迟挂载——SwiftUI sheet 动画期间直接初始化
    // UIDocumentPickerViewController（FileProvider 加载）会白屏数秒甚至卡死；先显示占位，
    // 等 sheet 呈现稳定后再挂载真选择器，消除「打开选择框就白屏、要重启 App」。
    @State private var pickerReady = false
    @State private var summary: BatchImportSummary?
    @State private var showSummary = false
    @State private var showError = false
    @State private var errorMessage = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("模式", selection: $mode) {
                        ForEach(Mode.allCases) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)

                    switch mode {
                    case .list: listModeView
                    case .zip: zipModeView
                    case .scan: scanModeView
                    }
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("批量录入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .sheet(item: $activePicker) { target in
            Group {
                if pickerReady {
                    DocPicker(types: target.types) { url in
                        switch target {
                        case .csv: loadCsvFile(url)
                        case .zip:
                            // v1.61：支持直接选文件夹（不压缩的媒体包）
                            var isDir: ObjCBool = false
                            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                            if isDir.boolValue { parseFolder(url) } else { parseZip(url) }
                        }
                    }
                    .ignoresSafeArea()
                } else {
                    ProgressView("正在打开文件选择…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                pickerReady = true
                            }
                        }
                }
            }
        }
        .alert("导入结果", isPresented: $showSummary) {
            Button("好", role: .cancel) {
                if summary?.created ?? 0 > 0 { dismiss() }
            }
        } message: {
            if let s = summary {
                Text(resultText(s))
            }
        }
        .alert("导入失败", isPresented: $showError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .overlay {
            if isImporting {
                ProgressView("正在导入…").padding(24).background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .onAppear {
            if templateURL == nil {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("房源导入模板.csv")
                let text = "房号,座号,房东,户型,租金,密码,备注,状态\n1-2334上,,康,单间,1100,,,待租\n2-1418下,,业主,单间,900,,,已租\n"
                // v1.60：加 UTF-8 BOM，Windows 的 Excel/记事本打开不再乱码
                var bytes = Data([0xEF, 0xBB, 0xBF])
                if let body = text.data(using: .utf8) { bytes.append(body) }
                try? bytes.write(to: url)
                templateURL = url
            }
        }
    }

    // MARK: - 清单导入

    private var listModeView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("粘贴房源清单（每行一间，逗号分隔）：\n房号,座号,房东,户型,租金,密码,备注,状态\n例：1-2334上,,康,单间,1100,,,待租\n2-1418下,,业主,单间,900,,,已租\n房号带 1-/2- 前缀自动识别座号（座号留空也可）；状态留空默认「待租」")
                .font(.footnote)
                .foregroundColor(.secondary)
            TextEditor(text: $csvText)
                .frame(minHeight: 120)
                .font(.system(.callout, design: .monospaced))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(.systemGray4)))
            HStack(spacing: 12) {
                if let templateURL = templateURL {
                    ShareLink(item: templateURL) {
                        Label("导出模板", systemImage: "square.and.arrow.up")
                    }
                    .font(.subheadline)
                }
                Spacer()
                Button("从文件选择 CSV") { activePicker = .csv }
                    .font(.subheadline)
                Button("解析预览") { parseCsv() }
                    .buttonStyle(.borderedProminent)
            }
            if !parseInfo.isEmpty {
                Text(parseInfo).font(.footnote).foregroundColor(.secondary)
            }
            if !previewItems.isEmpty { previewList(items: previewItems, mode: .list) }
            if !previewItems.isEmpty {
                Button("确认导入 \(previewItems.filter { !$0.duplicate }.count) 间") {
                    runImport(items: previewItems)
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                .disabled(isImporting)
            }
        }
    }

    private func loadCsvFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            errorMessage = "无法读取该文件"
            showError = true
            return
        }
        guard let text = decodeCSV(data) else {
            errorMessage = "无法识别该文件编码（支持 UTF-8 / GBK / Unicode）"
            showError = true
            return
        }
        csvText = text
        parseCsv()
    }

    /// v1.60：CSV 编码自动识别——UTF-8（含 BOM）→ GB18030/GBK（Excel 中文版另存）→ UTF-16（Excel 另存 Unicode）
    private func decodeCSV(_ data: Data) -> String? {
        // UTF-8 BOM
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            if let s = String(data: data.dropFirst(3), encoding: .utf8) { return s }
        }
        // UTF-8（无 BOM，校验非法序列）
        if let s = String(data: data, encoding: .utf8), !s.contains("\u{FFFD}") { return s }
        // GB18030（GBK 超集）
        let gbk = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        if let s = String(data: data, encoding: gbk) { return s }
        // UTF-16（Excel 另存 Unicode）
        if let s = String(data: data, encoding: .utf16) { return s }
        return nil
    }

    /// CSV 解析：忽略表头（首行若含「房号/房间」关键字则跳过），兼容中文逗号/制表符/引号包裹
    private func parseCsv() {
        parseInfo = ""
        var items: [BatchImportItem] = []
        var badLines: [String] = []
        let all = (try? houseModelContext?.fetch(FetchDescriptor<House>())) ?? []
        for (idx, rawLine) in csvText.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            var cols = line.components(separatedBy: [",", "，", "\t"])
            cols = cols.map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "") }
            if idx == 0 && (cols.contains("房号") || cols.contains("房间") || cols.contains("room")) { continue }
            guard cols.count >= 1, !cols[0].isEmpty else { badLines.append("第\(idx + 1)行：缺房号"); continue }
            let rawRoom = cols[0]
            // v1.69：清单房号必须以 1-/2- 座号前缀开头，无前缀不识别（防止无前缀脏数据）
            let rawRoomNorm = rawRoom.replacingOccurrences(of: "2－", with: "2-").replacingOccurrences(of: "1－", with: "1-")
            guard rawRoomNorm.hasPrefix("1-") || rawRoomNorm.hasPrefix("2-") else {
                badLines.append("第\(idx + 1)行：房号「\(rawRoom)」未带座号前缀（需 1- 或 2-），已跳过")
                continue
            }
            let (roomNo, tower) = BatchImporter.parseRoom(rawRoom, explicitTower: cols.count > 1 ? Int(cols[1].replacingOccurrences(of: "座", with: "")) ?? 0 : 0)
            guard !roomNo.isEmpty else { badLines.append("第\(idx + 1)行：房号无效"); continue }
            var item = BatchImportItem(roomNo: roomNo, tower: tower)
            item.rawRoomNo = rawRoom   // v1.61：预览回显用户原始输入（含 1-/2- 前缀原样显示）
            if cols.count > 2 { item.landlord = cols[2] }
            if cols.count > 3 { item.layout = cols[3] }
            if cols.count > 4 { item.price = Int(cols[4].replacingOccurrences(of: "元", with: "")) ?? 0 }
            if cols.count > 5 { item.password = cols[5] }
            if cols.count > 6 { item.remark = cols[6] }
            if cols.count > 7 {
                let st = cols[7].lowercased()
                if st.contains("已租") || st == "rented" { item.statusRaw = HouseStatus.rented.rawValue }
                else if st.contains("待租") || st == "available" || st.isEmpty { item.statusRaw = HouseStatus.available.rawValue }
                else { item.statusRaw = HouseStatus.available.rawValue }
            }
            item.duplicate = BatchImporter.findDuplicate(roomNo: roomNo, tower: tower, in: all) != nil
            items.append(item)
        }
        previewItems = items
        var info = "解析出 \(items.count) 间（重复 \(items.filter { $0.duplicate }.count) 间将跳过）"
        if !badLines.isEmpty { info += "；无法识别 \(badLines.count) 行：\(badLines.prefix(3).joined(separator: "；"))" }
        parseInfo = info
    }

    // MARK: - 媒体包导入

    private var zipModeView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("选择一个 zip 媒体包，或直接选一个文件夹（不压缩也行）：\nzip 根目录 / 文件夹里按房号建子文件夹（如 1-2334上/、2-1418下/），子文件夹内放照片视频（jpg/png/heic/mov/mp4）。\n已收录房号 → 自动补挂媒体；未收录房号 → 自动新建房源（字段留空待补）。")
                .font(.footnote)
                .foregroundColor(.secondary)
            HStack(spacing: 12) {
                Button("选择 zip 或文件夹") { activePicker = .zip }
                    .font(.subheadline)
                Spacer()
                if let name = pickedZip?.lastPathComponent {
                    Text("\(name)\(pickedIsFolder ? "（文件夹）" : "")").font(.footnote).foregroundColor(.secondary)
                } else {
                    Text("未选择").foregroundColor(.secondary)
                }
            }
            if !zipParseInfo.isEmpty {
                Text(zipParseInfo).font(.footnote).foregroundColor(.secondary)
            }
            if !zipErrorHint.isEmpty {
                Text(zipErrorHint).font(.footnote).foregroundColor(.red)
            }
            if !zipItems.isEmpty { previewList(items: zipItems, mode: .zip) }
            if !zipItems.isEmpty {
                Button("确认导入（新建 \(zipItems.filter { !$0.duplicate }.count) 间，补媒体 \(zipItems.filter { $0.duplicate && $0.missingRecordCount > 0 }.count) 间）") {
                    runImport(items: zipItems)
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                .disabled(isImporting)
            }
        }
    }

    private func parseZip(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let extracted = MediaStore.extractMediaZipToTemp(url: url) else {
            errorMessage = "无法解析该 zip（不是有效的压缩包，或使用了不支持的压缩方式）"
            showError = true
            return
        }
        pickedZip = url
        pickedIsFolder = false
        zipTempRoot = extracted.tempRoot
        buildZipItems(from: extracted.tempRoot, keys: extracted.roomKeys)
    }

    /// v1.61：直接选文件夹作为媒体包（无需压缩）——文件夹根 = 房号子目录集合
    private func parseFolder(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let keys = MediaStore.subdirNames(at: url)
        guard !keys.isEmpty else {
            errorMessage = "该文件夹下没有按房号建好的子文件夹"
            showError = true
            return
        }
        pickedZip = url
        pickedIsFolder = true
        zipTempRoot = url
        buildZipItems(from: url, keys: keys)
    }

    /// 媒体包解析公共逻辑：从根目录 + 房号 key 列表构建预览项
    private func buildZipItems(from root: URL, keys: [String]) {
        zipErrorHint = ""
        let all = (try? houseModelContext?.fetch(FetchDescriptor<House>())) ?? []
        var items: [BatchImportItem] = []
        var badKeys: [String] = []
        for key in keys {
            // v1.69：目录名必须以 1-/2- 前缀开头，无前缀不识别（提示哪些房号不符合规范）
            let norm = key.replacingOccurrences(of: "2－", with: "2-").replacingOccurrences(of: "1－", with: "1-")
            guard norm.hasPrefix("1-") || norm.hasPrefix("2-") else {
                badKeys.append(key)
                continue
            }
            let (roomNo, tower) = BatchImporter.parseRoom(key, explicitTower: key.hasPrefix("2-") ? 2 : 0)
            guard !roomNo.isEmpty else { continue }
            var item = BatchImportItem(roomNo: roomNo, tower: tower)
            item.rawRoomNo = key
            item.mediaDirKey = key
            let src = root.appendingPathComponent(key, isDirectory: true)
            item.diskFileCount = MediaStore.mediaFileNames(in: src).count
            if let house = BatchImporter.findDuplicate(roomNo: roomNo, tower: tower, in: all) {
                item.duplicate = true
                item.existingRecordCount = house.mediaItems.count
                let disk = Set(MediaStore.mediaFileNames(in: src))
                let exist = Set(house.mediaItems.map { $0.fileName })
                item.missingRecordCount = disk.subtracting(exist).count
            }
            items.append(item)
        }
        zipItems = items
        var info = "识别到 \(items.count) 个房号目录：新建 \(items.filter { !$0.duplicate }.count) 间，补媒体 \(items.filter { $0.duplicate && $0.missingRecordCount > 0 }.count) 间，媒体齐全 \(items.filter { $0.duplicate && $0.missingRecordCount == 0 }.count) 间"
        if !badKeys.isEmpty {
            info += "\n未识别（房号未带 1-/2- 前缀）：\(badKeys.joined(separator: "，"))"
            zipErrorHint = "以下目录名不符合规范（未带座号前缀），已跳过不识别：\(badKeys.joined(separator: "，"))"
        }
        zipParseInfo = info
    }

    // MARK: - 扫描补录

    private var scanModeView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("扫描 Documents/media/ 下已按房号建好的文件夹：\n已收录房号 → 比对磁盘与记录，缺失的补建媒体记录；未收录房号 → 自动新建房源（字段留空待补）。\n电脑导入方法：连接电脑后在「访达/文件」里找到「公寓管家」App 的 Documents/media/，把按房号的文件夹整体拖进去，再回这里点扫描。文件夹名建议带座号前缀（1-xxx / 2-xxx）。")
                .font(.footnote)
                .foregroundColor(.secondary)
            Button("扫描 media 目录") { runScan() }
                .buttonStyle(.borderedProminent)
            if !scanInfo.isEmpty {
                Text(scanInfo).font(.footnote).foregroundColor(.secondary)
            }
            if !scanBadHint.isEmpty {
                Text(scanBadHint).font(.footnote).foregroundColor(.red)
            }
            if !scanItems.isEmpty { previewList(items: scanItems, mode: .scan) }
            if !scanItems.isEmpty {
                Button("确认导入（新建 \(scanItems.filter { !$0.duplicate }.count) 间，补媒体 \(scanItems.filter { $0.duplicate && $0.missingRecordCount > 0 }.count) 间）") {
                    runImport(items: scanItems)
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                .disabled(isImporting)
            }
        }
    }

    private func runScan() {
        scanInfo = ""
        scanBadHint = ""
        let keys = MediaStore.scanMediaDirectoryKeys()
        guard !keys.isEmpty else {
            scanInfo = "media 目录下没有房号文件夹"
            scanItems = []
            return
        }
        let all = (try? houseModelContext?.fetch(FetchDescriptor<House>())) ?? []
        var items: [BatchImportItem] = []
        var badKeys: [String] = []
        for key in keys {
            // v1.69：media 目录名必须以 1-/2- 前缀开头，无前缀不识别并提示
            let norm = key.replacingOccurrences(of: "2－", with: "2-").replacingOccurrences(of: "1－", with: "1-")
            guard norm.hasPrefix("1-") || norm.hasPrefix("2-") else {
                badKeys.append(key)
                continue
            }
            let (roomNo, tower) = BatchImporter.parseRoom(key, explicitTower: key.hasPrefix("2-") ? 2 : 0)
            guard !roomNo.isEmpty else { continue }
            var item = BatchImportItem(roomNo: roomNo, tower: tower)
            item.rawRoomNo = key   // v1.61：预览回显目录名原样（含 2- 前缀）
            item.mediaDirKey = key
            // v1.69：目录名强制带前缀，与 House.mediaRoomKey 一致，不再做无前缀迁移
            let dir = MediaStore.houseDirectory(roomKey: key)
            item.diskFileCount = MediaStore.mediaFileNames(in: dir).count
            if let house = BatchImporter.findDuplicate(roomNo: roomNo, tower: tower, in: all) {
                item.duplicate = true
                item.existingRecordCount = house.mediaItems.count
                let disk = Set(MediaStore.mediaFileNames(in: dir))
                let exist = Set(house.mediaItems.map { $0.fileName })
                item.missingRecordCount = disk.subtracting(exist).count
            }
            items.append(item)
        }
        scanItems = items
        var info = "发现 \(keys.count) 个房号目录：新建 \(items.filter { !$0.duplicate }.count) 间，补媒体 \(items.filter { $0.duplicate && $0.missingRecordCount > 0 }.count) 间，媒体齐全 \(items.filter { $0.duplicate && $0.missingRecordCount == 0 }.count) 间"
        if !badKeys.isEmpty {
            info += "\n未识别（房号未带 1-/2- 前缀）：\(badKeys.joined(separator: "，"))"
            scanBadHint = "以下目录名不符合规范（未带座号前缀），已跳过不识别：\(badKeys.joined(separator: "，"))"
        }
        scanInfo = info
    }

    // MARK: - 预览列表（每行写清动作）

    private func previewList(items: [BatchImportItem], mode: Mode) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        // v1.61：优先回显用户原始输入（CSV 写 1-2245上 就显示 1-2245上，不再"被删"）
                        Text(item.rawRoomNo.isEmpty ? (item.tower == 2 ? "2-\(item.roomNo)" : item.roomNo) : item.rawRoomNo)
                            .font(.subheadline).fontWeight(.medium)
                        Spacer()
                        if !item.layout.isEmpty { Text(item.layout).font(.footnote).foregroundColor(.secondary) }
                        if item.price > 0 { Text("\(item.price)元").font(.footnote).foregroundColor(.secondary) }
                        Text(item.statusRaw == HouseStatus.rented.rawValue ? "已租" : "待租")
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(item.statusRaw == HouseStatus.rented.rawValue ? Color.orange.opacity(0.15) : Color.green.opacity(0.15))
                            .cornerRadius(4)
                    }
                    Text(actionText(for: item, mode: mode))
                        .font(.caption)
                        .foregroundColor(actionColor(for: item))
                }
                .padding(.vertical, 4)
                Divider().opacity(0.4)
            }
        }
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    /// 每行的动作说明：新建 / 补挂 K 个 / 已齐全 / 重复跳过
    private func actionText(for item: BatchImportItem, mode: Mode) -> String {
        if !item.duplicate {
            if item.diskFileCount > 0 {
                return "未收录 · 将新建房源（目录含 \(item.diskFileCount) 个媒体文件）"
            }
            return "未收录 · 将新建房源（无媒体）"
        }
        if mode == .list {
            return "已收录 · 重复房号，将跳过"
        }
        if item.missingRecordCount > 0 {
            return "已收录 · 磁盘 \(item.diskFileCount) 个媒体 · 已有记录 \(item.existingRecordCount) 条 · 将补挂 \(item.missingRecordCount) 个"
        }
        return "已收录 · 媒体记录齐全（\(item.diskFileCount) 个）"
    }

    private func actionColor(for item: BatchImportItem) -> Color {
        if !item.duplicate { return Color.accentColor }
        if item.missingRecordCount > 0 { return Color.orange }
        return Color(.systemGreen)
    }

    // MARK: - 执行导入

    private func runImport(items: [BatchImportItem]) {
        guard let ctx = houseModelContext else { return }
        isImporting = true
        Task { @MainActor in
            // v1.61：文件夹模式需在任务内重新持有安全作用域（复制文件时保持可读）
            let scoped = pickedIsFolder ? (pickedZip?.startAccessingSecurityScopedResource() ?? false) : false
            defer { if scoped { pickedZip?.stopAccessingSecurityScopedResource() } }
            var summary = BatchImportSummary()
            var all = (try? ctx.fetch(FetchDescriptor<House>())) ?? []
            for item in items where !item.duplicate {
                let dup = BatchImporter.findDuplicate(roomNo: item.roomNo, tower: item.tower, in: all)
                guard dup == nil else { summary.skippedDuplicate += 1; continue }
                let house = House(
                    roomNo: item.roomNo,
                    tower: item.tower,
                    landlord: item.landlord,
                    layout: item.layout,
                    price: item.price,
                    password: item.password,
                    remark: item.remark,
                    status: HouseStatus(rawValue: item.statusRaw) ?? .available
                )
                ctx.insert(house)
                all.append(house)
                summary.created += 1
                // 挂媒体（媒体包/扫描模式）：zip=复制文件+建记录；scan=文件已在正式目录，只建记录
                if let key = item.mediaDirKey {
                    let files = mediaFilesToAttach(for: item)
                    for f in files {
                        let lower = f.lowercased()
                        let media = MediaItem(fileName: f, kind: (lower.hasSuffix(".mp4") || lower.hasSuffix(".mov")) ? "video" : "image")
                        media.house = house
                        ctx.insert(media)
                        summary.mediaFiles += 1
                    }
                    if !files.isEmpty { summary.mediaAttached += 1 }
                }
            }
            // 已收录房号：补挂缺失媒体（zip=复制+补记录；scan=只补记录）
            for item in items where item.duplicate {
                guard let key = item.mediaDirKey,
                      let house = BatchImporter.findDuplicate(roomNo: item.roomNo, tower: item.tower, in: all) else { continue }
                let files = mediaFilesToAttach(for: item)
                    .filter { f in !house.mediaItems.contains(where: { $0.fileName == f }) }
                var added = 0
                for f in files {
                    let lower = f.lowercased()
                    let media = MediaItem(fileName: f, kind: (lower.hasSuffix(".mp4") || lower.hasSuffix(".mov")) ? "video" : "image")
                    media.house = house
                    ctx.insert(media)
                    added += 1
                }
                if added > 0 { summary.mediaAttached += 1; summary.mediaFiles += added }
            }
            try? ctx.save()
            isImporting = false
            summary.skippedDuplicate += items.filter { $0.duplicate && $0.mediaDirKey == nil }.count
            self.summary = summary
            // 导入后逐间：上传媒体到云端 + 自动生成分享 H5（与编辑保存后同机制；
            // 新建房与补挂媒体的房都刷新 H5，保证媒体变化立即可见）
            let houses = (try? ctx.fetch(FetchDescriptor<House>())) ?? []
            let imported = houses.filter { h in
                items.contains { $0.roomNo == h.roomNo && $0.tower == h.tower }
            }
            if let config = CosConfig.load(), config.isValid, !imported.isEmpty {
                for h in imported {
                    let files = h.mediaItems.map { ShareMediaFile(name: $0.fileName, kind: $0.kind) }
                    let profile = CosUploader.loadShareProfile()
                    let info = ShareHouseInfo(
                        displayRoomNo: h.displayRoomNo, towerLabel: h.towerLabel,
                        layout: h.layout, statusLabel: h.status.label, priceText: h.priceText,
                        landlord: h.landlord, password: h.password, remark: h.remark,
                        name: profile.name, phone: profile.phone
                    )
                    let roomKey = h.mediaRoomKey
                    _ = Task {
                        _ = try? await CosUploader.autoRegenerateMaskedShare(mediaFiles: files, roomKey: roomKey, info: info, config: config)
                    }
                }
            }
            // v1.63：批量导入/恢复接入本地操作日志
            BackupLogStore.log(category: "房源", action: "批量导入", result: "成功",
                                detail: resultText(summary).replacingOccurrences(of: "\n", with: "；"))
            showSummary = true
            // v1.62：导入完成后通知房源列表刷新（否则需退出重进才能看到新房源）
            NotificationCenter.default.post(name: HouseListView.houseStoreChanged, object: nil)
        }
    }

    /// 该房源要挂的媒体文件列表：
    /// zip 模式 = 从临时目录复制进正式目录（返回实际复制的文件名）；
    /// scan 模式 = 磁盘已在正式目录，返回磁盘里全部媒体文件名（由调用方按已有记录去重）
    /// v1.63：目标目录统一用带前缀 mediaRoomKey（1 座「1-」、2 座「2-」）——用户 zip/文件夹里的目录名
    ///         无论带不带前缀，导入后目录名与 House.mediaRoomKey 一致，避免媒体读不到/恢复错乱
    private func mediaFilesToAttach(for item: BatchImportItem) -> [String] {
        guard let key = item.mediaDirKey else { return [] }
        let normalized = item.tower == 2 ? "2-\(item.roomNo)" : "1-\(item.roomNo)"
        if let zipRoot = zipTempRoot {
            let src = zipRoot.appendingPathComponent(key, isDirectory: true)
            return MediaStore.importMediaFiles(fromTempDir: src, toRoomKey: normalized)
        }
        // scan：源目录在正式 media/ 下（v1.69 起只认带前缀目录，无前缀目录导入前已被拦截提示）
        let dir = MediaStore.houseDirectory(roomKey: item.tower == 2 ? "2-\(item.roomNo)" : "1-\(item.roomNo)")
        return MediaStore.mediaFileNames(in: dir)
    }

    private func resultText(_ s: BatchImportSummary) -> String {
        var lines = ["新建房源 \(s.created) 间"]
        if s.mediaAttached > 0 { lines.append("补挂媒体 \(s.mediaAttached) 间（\(s.mediaFiles) 个文件）") }
        if s.skippedDuplicate > 0 { lines.append("跳过重复 \(s.skippedDuplicate) 间") }
        lines.append("已触发云端上传与分享页生成")
        return lines.joined(separator: "\n")
    }
}

// MARK: - v1.59 UIKit 文档选择器桥接（修复 SwiftUI fileImporter 在 sheet 内无反应）

struct DocPicker: UIViewControllerRepresentable {
    let types: [UTType]
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: types)
        vc.allowsMultipleSelection = false
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocPicker
        init(_ parent: DocPicker) { self.parent = parent }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { parent.onPick(url) }
        }
    }
}

// MARK: - 批量导入工具函数

enum BatchImporter {
    /// 房号解析：剥离「2- / 1-」前缀（2- 前缀 → 2座），返回（房号本体, 座号）
    static func parseRoom(_ raw: String, explicitTower: Int) -> (String, Int) {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "2－", with: "2-")
        var tower = explicitTower
        if t.hasPrefix("2-") { t = String(t.dropFirst(2)); if tower == 0 { tower = 2 } }
        else if t.hasPrefix("1-") { t = String(t.dropFirst(2)); if tower == 0 { tower = 1 } }
        if tower == 0 { tower = 1 }
        return (t, tower)
    }

    /// 查重：同座同房号（排除回收站）返回已存在房源
    static func findDuplicate(roomNo: String, tower: Int, in all: [House]) -> House? {
        all.first { other in
            if other.isDeleted == true { return false }
            return other.tower == tower && normalized(other.roomNo) == roomNo
        }
    }

    private static func normalized(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "2－", with: "2-")
        if t.hasPrefix("2-") { t = String(t.dropFirst(2)) }
        if t.hasPrefix("1-") { t = String(t.dropFirst(2)) }
        return t
    }
}
