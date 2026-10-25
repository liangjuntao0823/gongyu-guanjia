import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// MARK: - v1.58 批量录入：房源清单导入 / 媒体包导入 / 扫描补录

/// 批量导入的单个房源项（预览用）
struct BatchImportItem: Identifiable {
    let id = UUID()
    var roomNo: String          // 房号本体（不带 2- 前缀；tower 单独记录）
    var tower: Int
    var landlord = ""
    var layout = ""
    var price = 0
    var password = ""
    var remark = ""
    var statusRaw = HouseStatus.available.rawValue
    var mediaDirKey: String?    // 媒体来源目录（zip 解压临时目录 或 media/ 下已有目录）
    var duplicate = false       // 已收录（同座同房号且未进回收站）
}

/// 批量导入结果汇总
struct BatchImportSummary {
    var created = 0            // 新建房源
    var skippedDuplicate = 0   // 跳过重复
    var mediaAttached = 0      // 补挂媒体的房源数
    var mediaFiles = 0         // 复制/补建的媒体文件数
    var errors: [String] = []
}

/// v1.58：批量录入页（房源列表右上角「批量导入」进入）
/// 三个模式：
///  1. 清单导入：粘贴 CSV（房号,座号,房东,户型,租金,密码,备注,状态）或从文件 App 选 .csv/.txt
///  2. 媒体包导入：选 zip（根 = 房号目录，每目录放照片视频）
///  3. 扫描补录：扫描 Documents/media/ 下已存在的房号目录，自动建房源/补媒体
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

    // —— 扫描补录 ——
    @State private var scanItems: [BatchImportItem] = []
    @State private var scanInfo = ""

    // —— 通用 ——
    @State private var isImporting = false
    @State private var summary: BatchImportSummary?
    @State private var showSummary = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var showCsvPicker = false
    @State private var showZipPicker = false

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
        .fileImporter(isPresented: $showCsvPicker, allowedContentTypes: [.commaSeparatedText, .plainText], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                loadCsvFile(url)
            }
        }
        .fileImporter(isPresented: $showZipPicker, allowedContentTypes: [.zip, .archive], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                parseZip(url)
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
    }

    // MARK: - 清单导入

    private var listModeView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("粘贴房源清单（每行一间，逗号分隔）：\n房号,座号,房东,户型,租金,密码,备注,状态\n例：2334上,1,康,单间,1100,,,待租\n2-1418下,2,业主,单间,900,,,已租")
                .font(.footnote)
                .foregroundColor(.secondary)
            TextEditor(text: $csvText)
                .frame(minHeight: 120)
                .font(.system(.callout, design: .monospaced))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(.systemGray4)))
            HStack(spacing: 12) {
                Button("从文件选择 CSV") { showCsvPicker = true }
                Spacer()
                Button("解析预览") { parseCsv() }
                    .buttonStyle(.borderedProminent)
            }
            if !parseInfo.isEmpty {
                Text(parseInfo).font(.footnote).foregroundColor(.secondary)
            }
            if !previewItems.isEmpty { previewList(items: previewItems) }
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
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            errorMessage = "无法读取该文件，请确认是 UTF-8 编码的文本/CSV"
            showError = true
            return
        }
        csvText = text
        parseCsv()
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
            let (roomNo, tower) = BatchImporter.parseRoom(rawRoom, explicitTower: cols.count > 1 ? Int(cols[1].replacingOccurrences(of: "座", with: "")) ?? 0 : 0)
            guard !roomNo.isEmpty else { badLines.append("第\(idx + 1)行：房号无效"); continue }
            var item = BatchImportItem(roomNo: roomNo, tower: tower)
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
            Text("选择一个 zip 媒体包：\nzip 根目录下按房号建文件夹（如 2334上/、2-1418下/），文件夹内放照片视频（jpg/png/heic/mov/mp4）。\n没有对应房号的文件夹会自动新建房源（字段留空待补），也可关闭该开关仅挂媒体到已有房。")
                .font(.footnote)
                .foregroundColor(.secondary)
            HStack(spacing: 12) {
                Button("选择 zip 媒体包") { showZipPicker = true }
                Spacer()
                if zipParseInfo.isEmpty && pickedZip == nil {
                    Text("未选择").foregroundColor(.secondary)
                } else {
                    Text(pickedZip?.lastPathComponent ?? "").font(.footnote).foregroundColor(.secondary)
                }
            }
            if !zipParseInfo.isEmpty {
                Text(zipParseInfo).font(.footnote).foregroundColor(.secondary)
            }
            if !zipItems.isEmpty {
                previewList(items: zipItems)
                Button("确认导入（新建 \(zipItems.filter { !$0.duplicate }.count) 间，补媒体 \(zipItems.count) 间）") {
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
            errorMessage = "无法解析该 zip（不是有效的压缩包）"
            showError = true
            return
        }
        zipTempRoot = extracted.tempRoot
        pickedZip = url
        let all = (try? houseModelContext?.fetch(FetchDescriptor<House>())) ?? []
        var items: [BatchImportItem] = []
        for key in extracted.roomKeys {
            let (roomNo, tower) = BatchImporter.parseRoom(key, explicitTower: key.hasPrefix("2-") ? 2 : 0)
            guard !roomNo.isEmpty else { continue }
            var item = BatchImportItem(roomNo: roomNo, tower: tower)
            item.mediaDirKey = key
            item.duplicate = BatchImporter.findDuplicate(roomNo: roomNo, tower: tower, in: all) != nil
            items.append(item)
        }
        zipItems = items
        zipParseInfo = "识别到 \(items.count) 个房号目录：已有 \(items.filter { $0.duplicate }.count) 间将补挂媒体，未收录 \(items.filter { !$0.duplicate }.count) 间将自动新建"
    }

    // MARK: - 扫描补录

    private var scanModeView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("扫描 Documents/media/ 下已按房号建好的文件夹：\n已收录的房号 → 补挂照片视频记录；未收录的房号 → 自动新建房源（字段留空待补）。\n电脑导入方法：连接电脑后在「访达/文件」里找到「公寓管家」App 的 Documents/media/，把按房号的文件夹整体拖进去，再回这里点扫描。")
                .font(.footnote)
                .foregroundColor(.secondary)
            Button("扫描 media 目录") { runScan() }
                .buttonStyle(.borderedProminent)
            if !scanInfo.isEmpty {
                Text(scanInfo).font(.footnote).foregroundColor(.secondary)
            }
            if !scanItems.isEmpty {
                previewList(items: scanItems)
                Button("确认导入（新建 \(scanItems.filter { !$0.duplicate }.count) 间，补媒体 \(scanItems.count) 间）") {
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
        let keys = MediaStore.scanMediaDirectoryKeys()
        guard !keys.isEmpty else {
            scanInfo = "media 目录下没有房号文件夹"
            scanItems = []
            return
        }
        let all = (try? houseModelContext?.fetch(FetchDescriptor<House>())) ?? []
        var items: [BatchImportItem] = []
        for key in keys {
            let (roomNo, tower) = BatchImporter.parseRoom(key, explicitTower: key.hasPrefix("2-") ? 2 : 0)
            guard !roomNo.isEmpty else { continue }
            var item = BatchImportItem(roomNo: roomNo, tower: tower)
            item.mediaDirKey = key
            item.duplicate = BatchImporter.findDuplicate(roomNo: roomNo, tower: tower, in: all) != nil
            items.append(item)
        }
        scanItems = items
        scanInfo = "发现 \(keys.count) 个房号目录：已有 \(items.filter { $0.duplicate }.count) 间将补挂媒体，未收录 \(items.filter { !$0.duplicate }.count) 间将自动新建"
    }

    // MARK: - 预览列表

    private func previewList(items: [BatchImportItem]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items) { item in
                HStack {
                    Text(item.duplicate ? "\(item.tower == 2 ? "2-" : "")\(item.roomNo)（已收录）" : "\(item.tower == 2 ? "2-" : "")\(item.roomNo)")
                        .foregroundColor(item.duplicate ? .secondary : .primary)
                    Spacer()
                    if !item.layout.isEmpty { Text(item.layout).font(.footnote).foregroundColor(.secondary) }
                    if item.price > 0 { Text("\(item.price)元").font(.footnote).foregroundColor(.secondary) }
                    Text(item.statusRaw == HouseStatus.rented.rawValue ? "已租" : "待租")
                        .font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(item.statusRaw == HouseStatus.rented.rawValue ? Color.orange.opacity(0.15) : Color.green.opacity(0.15))
                        .cornerRadius(4)
                }
                .padding(.vertical, 3)
                Divider().opacity(0.4)
            }
        }
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - 执行导入

    private func runImport(items: [BatchImportItem]) {
        guard let ctx = houseModelContext else { return }
        isImporting = true
        Task { @MainActor in
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
                // 挂媒体（媒体包/扫描模式）
                if let key = item.mediaDirKey {
                    let files = MediaStore.importMediaFiles(fromTempDir: mediaSourceDir(for: item), toRoomKey: house.mediaRoomKey)
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
            // 已有房号：补挂媒体（zip/扫描模式）
            for item in items where item.duplicate {
                guard let key = item.mediaDirKey,
                      let house = BatchImporter.findDuplicate(roomNo: item.roomNo, tower: item.tower, in: all) else { continue }
                let files = MediaStore.importMediaFiles(fromTempDir: mediaSourceDir(for: item), toRoomKey: house.mediaRoomKey)
                var added = 0
                for f in files {
                    guard !house.mediaItems.contains(where: { $0.fileName == f }) else { continue }
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
            showSummary = true
        }
    }

    /// 媒体来源目录：zip 模式 = 临时解压目录/<房号key>；扫描模式 = media/<房号key>
    private func mediaSourceDir(for item: BatchImportItem) -> URL {
        if let root = zipTempRoot, let key = item.mediaDirKey {
            return root.appendingPathComponent(key, isDirectory: true)
        }
        if let key = item.mediaDirKey {
            return MediaStore.houseDirectory(roomKey: key)
        }
        return MediaStore.mediaDirectory()
    }

    private func resultText(_ s: BatchImportSummary) -> String {
        var lines = ["新建房源 \(s.created) 间"]
        if s.mediaAttached > 0 { lines.append("补挂媒体 \(s.mediaAttached) 间（\(s.mediaFiles) 个文件）") }
        if s.skippedDuplicate > 0 { lines.append("跳过重复 \(s.skippedDuplicate) 间") }
        lines.append("已触发云端上传与分享页生成")
        return lines.joined(separator: "\n")
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
