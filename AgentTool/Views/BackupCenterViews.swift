import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// MARK: - v1.12 备份中心（设置页）
// 统一查看/恢复入口：
//   · 备份文件查看器：快速/全量 zip（云端状态、上传、删除）+ 云端备份列表 + 旧版 JSON 分组
//   · 恢复选择器：本地 zip / 云端备份（下载后恢复）/ 旧版 JSON（按文件名自动识别板块）
// 恢复流程：二级确认 → 校验 → 安全快照 → 导入 → 分行统计弹窗；失败自动回滚。

/// 备份文件查看器（mode: browse=查看管理；restore=选一个恢复）
struct BackupFileBrowseViewV5: View {
    var mode: BrowseMode = .browse
    enum BrowseMode { case browse, restore }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.houseModelContext) private var houseModelContext
    @Environment(\.dismiss) private var dismiss

    // 列表
    @State private var fastBackups: [URL] = []
    @State private var fullBackups: [URL] = []
    @State private var legacyJSONs: [(type: DataBackupManager.BackupType, url: URL)] = []
    @State private var cloudRecords: [CloudBackupService.CloudRecord] = []
    @State private var reloadTick = 0

    // 上传进度
    @State private var uploadingName: String?
    @State private var uploadProgress: Double = 0
    @State private var uploadStage = ""

    // 删除/恢复确认
    @State private var deleteTarget: DeleteTarget?
    @State private var showDeleteConfirm = false
    @State private var restoreTarget: RestoreTarget?
    @State private var showRestoreConfirm = false

    // 恢复进度与统计
    @State private var isRestoring = false
    @State private var restoreProgress: Double = 0
    @State private var restoreStage = ""
    @State private var restoreStats: RestoreStatsV5?
    @State private var restoreError: String?

    struct DeleteTarget { let name: String; let isCloud: Bool }
    struct RestoreTarget {
        let localURL: URL?
        let legacyData: Data?
        let legacyScope: DataBackupManager.ImportScope?
        let cloudName: String?
        var displayName: String
    }

    var body: some View {
        NavigationStack {
            List {
                if mode == .browse {
                    Section {
                        Button {
                            // 快速备份（含账本+房源+清单，自动上传云端）
                            performBackup(kind: .fast)
                        } label: {
                            Label("快速备份", systemImage: "bolt.circle")
                        }
                        Button {
                            // 全量备份（含照片视频），完成后手动上传
                            performBackup(kind: .full)
                        } label: {
                            Label("全量备份", systemImage: "externaldrive.fill")
                        }
                    } footer: {
                        Text("快速备份：账本 + 房源信息 + 媒体清单（不含照片视频文件），备份后自动上传云端。\n全量备份：账本 + 房源 + 全部照片视频，备份后可在下方手动上传云端。")
                    }
                }

                if !fastBackups.isEmpty {
                    Section("快速备份") {
                        ForEach(fastBackups, id: \.path) { url in
                            backupRow(url: url, kind: .fast)
                        }
                    }
                }

                if !fullBackups.isEmpty {
                    Section("全量备份") {
                        ForEach(fullBackups, id: \.path) { url in
                            backupRow(url: url, kind: .full)
                        }
                    }
                }

                if !cloudRecords.isEmpty {
                    Section("云端备份") {
                        ForEach(cloudRecords, id: \.name) { record in
                            cloudRow(record)
                        }
                    } footer: {
                        Text("云端备份保留最近 10 份自动备份（快速_ 前缀），全量手动上传的备份不会自动清理。")
                    }
                }

                if !legacyJSONs.isEmpty {
                    Section("旧版备份（JSON）") {
                        ForEach(legacyJSONs, id: \.url.path) { item in
                            legacyRow(item)
                        }
                    } footer: {
                        Text("旧版分板块 JSON 备份（v1.11 及更早），可继续查看、恢复或删除，数据不丢失。")
                    }
                }

                if mode == .restore && fastBackups.isEmpty && fullBackups.isEmpty && legacyJSONs.isEmpty && cloudRecords.isEmpty {
                    Section {
                        Text("暂无备份文件。请先到「设置 → 备份数据」做一次备份。")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle(mode == .browse ? "备份文件" : "恢复备份")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                }
            }
            .overlay {
                if isRestoring {
                    RestoreProgressOverlay(progress: restoreProgress, stage: restoreStage)
                }
            }
            .overlay {
                if uploadingName != nil {
                    UploadProgressOverlay(name: uploadingName ?? "", progress: uploadProgress, stage: uploadStage)
                }
            }
            .confirmationDialog("删除这个备份？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("删除", role: .destructive) { performDelete() }
                Button("取消", role: .cancel) {}
            } message: {
                if let t = deleteTarget {
                    Text(t.isCloud ? "将删除云端备份「\(t.name)」（不影响本地文件）。" : "将删除本地备份「\(t.name)」（不影响云端）。")
                } else {
                    Text("")
                }
            }
            .confirmationDialog("用这个备份恢复？", isPresented: $showRestoreConfirm, titleVisibility: .visible) {
                Button("恢复", role: .destructive) { startRestore() }
                Button("取消", role: .cancel) {}
            } message: {
                if let t = restoreTarget {
                    Text("将用「\(t.displayName)」覆盖当前全部数据。恢复前会自动打包当前数据做安全备份，失败自动还原；成功后再清理。确定继续吗？")
                } else {
                    Text("")
                }
            }
            .alert("恢复完成", isPresented: Binding(
                get: { restoreStats != nil && restoreError == nil },
                set: { if !$0 { restoreStats = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                if let stats = restoreStats {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(stats.summaryLines, id: \.self) { line in
                            Text(line)
                        }
                        Text("全部核对无误")
                    }
                }
            }
            .alert("恢复失败", isPresented: Binding(
                get: { restoreError != nil },
                set: { if !$0 { restoreError = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(restoreError ?? "")
            }
            .onAppear { reload() }
            .onChange(of: reloadTick) { _, _ in reload() }
        }
    }

    // MARK: - 行

    private func backupRow(url: URL, kind: BackupKindV5) -> some View {
        let name = url.lastPathComponent
        let size = BackupV5Manager.fileSize(at: url)
        let cloudState = CloudBackupService.uploadState(of: name)
        let dateText = fileDateText(url)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text("\(sizeText(size)) · \(dateText)")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text(cloudState)
                .font(.footnote)
                .foregroundColor(cloudState == "已上传云端" ? .green : .orange)
            if mode == .browse {
                Menu {
                    if kind == .full {
                        Button("上传到云端") { uploadFullBackup(url: url) }
                    }
                    Button("删除", role: .destructive) {
                        deleteTarget = DeleteTarget(name: name, isCloud: false)
                        showDeleteConfirm = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundColor(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if mode == .restore {
                restoreTarget = RestoreTarget(localURL: url, legacyData: nil, legacyScope: nil, cloudName: nil, displayName: name)
                showRestoreConfirm = true
            }
        }
    }

    private func cloudRow(_ record: CloudBackupService.CloudRecord) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text("\(sizeText(record.size)) · \(record.date.formatted(date: .abbreviated, time: .shortened))\(record.isAuto ? " · 自动备份" : " · 手动上传")")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text("云端")
                .font(.footnote)
                .foregroundColor(.green)
            if mode == .browse {
                Menu {
                    Button("下载到本机") { downloadCloud(record) }
                    Button("删除云端", role: .destructive) {
                        deleteTarget = DeleteTarget(name: record.name, isCloud: true)
                        showDeleteConfirm = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundColor(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if mode == .restore {
                restoreTarget = RestoreTarget(localURL: nil, legacyData: nil, legacyScope: nil, cloudName: record.name, displayName: record.name)
                showRestoreConfirm = true
            }
        }
    }

    private func legacyRow(_ item: (type: DataBackupManager.BackupType, url: URL)) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.url.lastPathComponent)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text("\(item.type.rawValue) · \(fileDateText(item.url))")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if mode == .browse {
                Button("删除", role: .destructive) {
                    deleteTarget = DeleteTarget(name: item.url.lastPathComponent, isCloud: false)
                    showDeleteConfirm = true
                }
                .font(.footnote)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if mode == .restore {
                if let data = try? Data(contentsOf: item.url) {
                    restoreTarget = RestoreTarget(localURL: nil, legacyData: data, legacyScope: scopeForLegacy(item.type), cloudName: nil, displayName: item.url.lastPathComponent)
                    showRestoreConfirm = true
                }
            }
        }
    }

    // MARK: - 刷新

    private func reload() {
        let all = BackupV5Manager.listLocalBackups()
        fastBackups = all.filter { $0.lastPathComponent.hasPrefix("快速_") }
        fullBackups = all.filter { $0.lastPathComponent.hasPrefix("全量_") }
        cloudRecords = CloudBackupService.cloudRecords()
        legacyJSONs = listLegacyBackups()
    }

    private func listLegacyBackups() -> [(type: DataBackupManager.BackupType, url: URL)] {
        let dm = DataBackupManager()
        var result: [(type: DataBackupManager.BackupType, url: URL)] = []
        for type in [DataBackupManager.BackupType.total, .deals, .properties, .payouts] {
            for url in dm.listBackups(in: type) {
                result.append((type: type, url: url))
            }
        }
        return result.sorted { a, b in
            (try? a.url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast >
            (try? b.url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
        }
    }

    private func scopeForLegacy(_ type: DataBackupManager.BackupType) -> DataBackupManager.ImportScope {
        switch type {
        case .deals: return .deals
        case .properties: return .properties
        case .payouts: return .payouts
        case .total: return .all
        }
    }

    // MARK: - 操作

    private func performBackup(kind: BackupKindV5) {
        guard let houseCtx = houseModelContext else { return }
        if kind == .fast {
            if let url = BackupV5Manager.createFastBackup(mainContext: modelContext, houseContext: houseCtx) {
                BackupLogStore.log(category: "备份", action: "快速备份", result: "成功", detail: url.lastPathComponent, checksum: BackupV5Manager.sha1OfFile(at: url) ?? "")
                // 自动上传云端（后台；失败自动入队重试）
                Task {
                    await CloudBackupService.autoUploadFastBackup(zipURL: url, config: nil)
                    await MainActor.run { reloadTick += 1 }
                }
                showMessageInContext("快速备份成功：\(url.lastPathComponent)\n已自动上传云端（若网络失败会在下次打开 App 时自动重试）")
            } else {
                showMessageInContext("快速备份失败，请检查存储空间")
            }
        } else {
            // 全量备份：进度 overlay
            uploadingName = "全量备份生成中…"
            uploadProgress = 0
            uploadStage = "正在打包账本与照片视频…"
            Task {
                let url = await BackupV5Manager.createFullBackup(mainContext: modelContext, houseContext: houseCtx) { p in
                    Task { @MainActor in
                        self.uploadProgress = p
                    }
                }
                await MainActor.run {
                    uploadingName = nil
                    if let url = url {
                        BackupLogStore.log(category: "备份", action: "全量备份", result: "成功", detail: url.lastPathComponent, checksum: BackupV5Manager.sha1OfFile(at: url) ?? "")
                        showMessageInContext("全量备份成功：\(url.lastPathComponent)\n可在备份列表中手动上传到云端")
                        reloadTick += 1
                    } else {
                        showMessageInContext("全量备份失败，请检查存储空间")
                    }
                }
            }
        }
    }

    private func uploadFullBackup(url: URL) {
        guard let config = CosConfig.load(), config.isValid else {
            showMessageInContext("未配置云端（腾讯云 COS）。请到「设置 → 远程配置」填写并保存验证后再上传。")
            return
        }
        uploadingName = url.lastPathComponent
        uploadProgress = 0
        uploadStage = "正在上传备份文件…"
        Task {
            do {
                try await CloudBackupService.uploadZip(url: url, config: config) { p in
                    Task { @MainActor in self.uploadProgress = p }
                }
                // 媒体增量（按 sha1 去重，已存在跳过）
                await MainActor.run {
                    uploadProgress = 0.99
                    uploadStage = "正在核对照片视频（增量上传）…"
                }
                try await CloudBackupService.uploadFullMedia(zipURL: url, config: config) { p in
                    Task { @MainActor in self.uploadProgress = 0.99 + p * 0.01 }
                }
                await MainActor.run {
                    CloudBackupService.recordUpload(name: url.lastPathComponent, size: BackupV5Manager.fileSize(at: url), date: Date(), isAuto: false)
                    uploadingName = nil
                    BackupLogStore.log(category: "上传", action: "全量备份上传", result: "成功", detail: url.lastPathComponent)
                    showMessageInContext("已上传云端：\(url.lastPathComponent)")
                    reloadTick += 1
                }
            } catch {
                await MainActor.run {
                    uploadingName = nil
                    BackupLogStore.log(category: "上传", action: "全量备份上传", result: "失败", detail: error.localizedDescription)
                    showMessageInContext("上传失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private func downloadCloud(_ record: CloudBackupService.CloudRecord) {
        guard let config = CosConfig.load(), config.isValid else {
            showMessageInContext("未配置云端（腾讯云 COS）。")
            return
        }
        uploadingName = record.name
        uploadProgress = 0
        uploadStage = "正在从云端下载…"
        Task {
            do {
                let local = try await CloudBackupService.downloadBackup(name: record.name, config: config)
                await MainActor.run {
                    uploadingName = nil
                    showMessageInContext("已下载到本机：\(local.lastPathComponent)")
                    reloadTick += 1
                }
            } catch {
                await MainActor.run {
                    uploadingName = nil
                    showMessageInContext("下载失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private func performDelete() {
        guard let target = deleteTarget else { return }
        if target.isCloud {
            guard let config = CosConfig.load(), config.isValid else {
                showMessageInContext("未配置云端（腾讯云 COS）。")
                return
            }
            Task {
                do {
                    try await CloudBackupService.deleteRemoteBackup(name: target.name, config: config)
                    await MainActor.run {
                        BackupLogStore.log(category: "删除", action: "云端删除", result: "成功", detail: target.name)
                        reloadTick += 1
                    }
                } catch {
                    await MainActor.run { showMessageInContext("云端删除失败：\(error.localizedDescription)") }
                }
            }
        } else {
            // 本地删除：快速/全量 zip 或旧 JSON
            let dm = DataBackupManager()
            let localDir = BackupV5Manager.backupsDirectory
            let legacyDir: URL? = legacyJSONs.first { $0.url.lastPathComponent == target.name }?.url
            if let legacy = legacyDir {
                // 旧 JSON：从对应类型目录删除
                let type = legacyJSONs.first { $0.url.path == legacy.path }?.type ?? .total
                _ = dm.deleteBackup(legacy, type: type)
            } else {
                try? FileManager.default.removeItem(at: localDir.appendingPathComponent(target.name))
            }
            CloudBackupService.removePendingUpload(name: target.name)
            BackupLogStore.log(category: "删除", action: "本地删除", result: "成功", detail: target.name)
            reloadTick += 1
        }
        deleteTarget = nil
    }

    private func startRestore() {
        guard let target = restoreTarget else { return }
        guard let houseCtx = houseModelContext else {
            restoreError = "房源数据容器不可用"
            return
        }
        isRestoring = true
        restoreProgress = 0
        restoreStage = "正在校验备份…"
        Task {
            do {
                if let cloudName = target.cloudName {
                    // 云端：先下载（进本地）再恢复
                    guard let config = CosConfig.load(), config.isValid else {
                        throw BackupV5Error.invalidBackup("未配置云端（腾讯云 COS）")
                    }
                    let local = try await CloudBackupService.downloadBackup(name: cloudName, config: config)
                    let stats = try await BackupV5Manager.restore(
                        zipURL: local, mainContext: modelContext, houseContext: houseCtx,
                        phaseProgress: { p in Task { @MainActor in self.restoreProgress = p } },
                        stageMessage: { s in Task { @MainActor in self.restoreStage = s } }
                    )
                    await MainActor.run {
                        isRestoring = false
                        restoreStats = stats
                        BackupLogStore.log(category: "恢复", action: "云端恢复", result: "成功", detail: stats.summaryLines.joined(separator: " / "))
                    }
                } else if let url = target.localURL {
                    let stats = try await BackupV5Manager.restore(
                        zipURL: url, mainContext: modelContext, houseContext: houseCtx,
                        phaseProgress: { p in Task { @MainActor in self.restoreProgress = p } },
                        stageMessage: { s in Task { @MainActor in self.restoreStage = s } }
                    )
                    await MainActor.run {
                        isRestoring = false
                        restoreStats = stats
                        BackupLogStore.log(category: "恢复", action: "本地恢复", result: "成功", detail: stats.summaryLines.joined(separator: " / "))
                    }
                } else if let data = target.legacyData, let scope = target.legacyScope {
                    let stats = try await BackupV5Manager.restoreLegacyJSON(data: data, mainContext: modelContext, scope: scope)
                    await MainActor.run {
                        isRestoring = false
                        restoreStats = stats
                        BackupLogStore.log(category: "恢复", action: "旧版恢复", result: "成功", detail: stats.summaryLines.joined(separator: " / "))
                    }
                } else {
                    throw BackupV5Error.invalidBackup("未选择备份")
                }
            } catch {
                await MainActor.run {
                    isRestoring = false
                    restoreError = error.localizedDescription
                    BackupLogStore.log(category: "恢复", action: "恢复", result: "失败", detail: error.localizedDescription)
                }
            }
        }
        restoreTarget = nil
    }

    // MARK: - 提示（用环境变量传递的 alert 通道）

    @State private var message = ""
    private func showMessageInContext(_ text: String) {
        // 通过通知传给 SettingsView 的 alert 通道
        NotificationCenter.default.post(name: .backupCenterMessage, object: nil, userInfo: ["message": text])
    }

    private func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func fileDateText(_ url: URL) -> String {
        if let date = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate {
            return date.formatted(date: .abbreviated, time: .shortened)
        }
        return ""
    }
}

// MARK: - 恢复进度 overlay

struct RestoreProgressOverlay: View {
    let progress: Double
    let stage: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(.white)
                Text(stage)
                    .font(.footnote.weight(.medium))
                    .foregroundColor(.white)
                Text("\(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.85))
            }
            .padding(22)
            .frame(maxWidth: 300)
            .background(Color.black.opacity(0.65))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }
}

struct UploadProgressOverlay: View {
    let name: String
    let progress: Double
    let stage: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 14) {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(.white)
                Text(stage)
                    .font(.footnote)
                    .foregroundColor(.white)
                Text("\(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.85))
            }
            .padding(22)
            .frame(maxWidth: 300)
            .background(Color.black.opacity(0.65))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }
}

// MARK: - 操作日志视图

struct BackupLogsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var logs = BackupLogStore.all()

    var body: some View {
        NavigationStack {
            List {
                if logs.isEmpty {
                    Text("暂无操作日志")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(Array(logs.enumerated()), id: \.offset) { _, entry in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(entry.category)
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(entry.result == "成功" ? Color.green.opacity(0.15) : Color.red.opacity(0.15))
                                    .foregroundColor(entry.result == "成功" ? .green : .red)
                                    .clipShape(Capsule())
                                Text(entry.action)
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                                Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Text(entry.detail.isEmpty ? entry.result : entry.detail)
                                .font(.footnote)
                                .foregroundColor(.secondary)
                            if !entry.checksum.isEmpty {
                                Text("校验和：\(entry.checksum.prefix(12))…")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("操作日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("清空") { BackupLogStore.clear(); logs = [] }
                }
            }
        }
    }
}

// MARK: - 通知通道（SettingsView alert 复用）

extension Notification.Name {
    static let backupCenterMessage = Notification.Name("backupCenterMessage")
}

// MARK: - 系统分享（导出崩溃日志）

struct SystemShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        return controller
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
