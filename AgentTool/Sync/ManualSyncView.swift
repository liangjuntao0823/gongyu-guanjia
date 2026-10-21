import SwiftUI
import SwiftData
import VisionKit

@MainActor
final class ManualSyncViewModel: ObservableObject {
    enum Phase { case idle, checking, preview, syncing, finished }
    @Published var host = ""
    @Published var port = "8765"
    @Published var code = ""
    @Published var phase: Phase = .idle
    @Published var remoteName = ""
    @Published var pending: [PendingChangeDTO] = []
    @Published var conflicts: [SyncConflict] = []
    @Published var remoteCount = 0
    @Published var message = "不会自动联网"
    @Published var result: SyncResultSummary?
    @Published var showScanner = false

    private let client = ManualSyncClient()
    private let store = SyncStore.shared
    private let deviceId: UUID = {
        let key = "manualSyncDeviceId"
        if let value = UserDefaults.standard.string(forKey: key), let id = UUID(uuidString: value) { return id }
        let id = UUID(); UserDefaults.standard.set(id.uuidString, forKey: key); return id
    }()

    func load(modelContext: ModelContext) async {
        do {
            let state = await store.snapshot()
            pending = try SwiftDataSyncSnapshot.makePendingChanges(
                modelContext: modelContext,
                deviceId: deviceId,
                revisions: state.revisions
            )
            conflicts = state.conflicts
        } catch {
            message = "读取 iPhone 数据失败：\(error.localizedDescription)"
        }
    }

    func applyScanned(_ text: String) {
        guard let info = SyncConnectionInfo.parse(text) else { message = "二维码不是有效的同步连接信息"; return }
        host = info.host; port = String(info.port); code = info.code; message = "已读取连接信息，尚未联网"
    }

    func preflight(modelContext: ModelContext) async {
        guard phase == .idle || phase == .finished else { return }
        phase = .checking; message = "正在统计 iPhone 数据并检查连接…"
        do {
            let state = await store.snapshot()
            let localPending = try SwiftDataSyncSnapshot.makePendingChanges(
                modelContext: modelContext,
                deviceId: deviceId,
                revisions: state.revisions
            )
            let info = SyncConnectionInfo(host: host, port: Int(port) ?? 8765, code: code)
            let response = try await client.preflight(
                connection: info,
                deviceId: deviceId,
                cursor: state.cursor,
                pendingUploadCount: localPending.count
            )
            pending = localPending
            conflicts = state.conflicts
            remoteName = response.remoteDeviceName; remoteCount = response.pendingDownloadCount
            phase = .preview; message = "预检完成，请确认后同步"
        } catch { phase = .idle; message = error.localizedDescription }
    }

    func synchronize() async {
        guard phase == .preview else { return }
        phase = .syncing; message = "正在同步…"
        do {
            let state = await store.snapshot()
            let pushed = try await client.push(pending)
            try await store.markAccepted(pushed.accepted, from: pending)
            try await store.addConflicts(pushed.conflicts)
            let pulled = try await client.pull(cursor: state.cursor)
            // 远端实体只进入可见预览/冲突层；没有稳定模型 ID 前绝不覆盖 SwiftData。
            let protective = pulled.entities.map { entity in
                SyncConflict(id: UUID(), entityType: entity.entityType, entityId: entity.id, local: nil, remote: entity, reason: "远端变更待人工确认导入，未覆盖本机数据", detectedAt: Date())
            }
            try await store.addConflicts(pulled.conflicts + protective)
            try await client.ack(changeIds: pushed.accepted, cursor: pulled.cursor)
            try await store.setCursor(pulled.cursor)
            let updated = await store.snapshot(); pending = []; conflicts = updated.conflicts
            result = SyncResultSummary(uploaded: pushed.accepted.count, downloaded: pulled.entities.count, merged: 0, conflicts: pushed.conflicts.count + pulled.conflicts.count + protective.count, failed: 0)
            phase = .finished; message = "同步请求已完成；冲突和远端变更需人工处理"
        } catch {
            try? await store.incrementRetry(pending.map(\.id))
            phase = .preview; message = error.localizedDescription
        }
    }

    func dismissConflict(_ id: UUID) async { try? await store.resolveConflict(id); conflicts = await store.snapshot().conflicts }
}

struct ManualSyncView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @StateObject private var model = ManualSyncViewModel()

    var body: some View {
        NavigationStack {
            Form {
                Section("手动连接") {
                    TextField("IP 或服务器地址", text: $model.host).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("端口", text: $model.port).keyboardType(.numberPad)
                    SecureField("连接码（短期令牌由预检换取）", text: $model.code)
                    Button { model.showScanner = true } label: { Label("扫描连接二维码", systemImage: "qrcode.viewfinder") }
                    if !DataScannerViewController.isSupported || !DataScannerViewController.isAvailable {
                        Text("本机不可使用系统 DataScanner，可手动填写连接信息。").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("同步预览") {
                    LabeledContent("iPhone 待上传", value: "\(model.pending.count) 条")
                    LabeledContent("Windows 待下发", value: "\(model.remoteCount) 条")
                    LabeledContent("未解决冲突", value: "\(model.conflicts.count) 条")
                    if !model.remoteName.isEmpty { LabeledContent("远端设备", value: model.remoteName) }
                    Text(model.message).font(.footnote).foregroundStyle(.secondary)
                }
                if !model.conflicts.isEmpty {
                    Section("可见冲突（绝不静默覆盖）") {
                        ForEach(model.conflicts) { conflict in
                            VStack(alignment: .leading, spacing: 5) {
                                Text("\(conflict.entityType.rawValue) · \(conflict.entityId.uuidString.prefix(8))").font(.headline)
                                Text(conflict.reason).font(.caption).foregroundStyle(.secondary)
                                Button("仅从列表移除") { Task { await model.dismissConflict(conflict.id) } }.font(.caption)
                            }
                        }
                    }
                }
                if let result = model.result {
                    Section("结果") {
                        LabeledContent("上传", value: "\(result.uploaded)")
                        LabeledContent("下载待确认", value: "\(result.downloaded)")
                        LabeledContent("冲突", value: "\(result.conflicts)")
                        LabeledContent("失败", value: "\(result.failed)")
                    }
                }
                Section {
                    if model.phase == .preview {
                        Button("确认并执行同步") { Task { await model.synchronize() } }.buttonStyle(.borderedProminent)
                    } else {
                        Button("检查连接并生成预览") { Task { await model.preflight(modelContext: modelContext) } }
                            .disabled(model.host.trimmingCharacters(in: .whitespaces).isEmpty || model.code.isEmpty || model.phase == .checking || model.phase == .syncing)
                    }
                } footer: { Text("只有点击上方按钮才会调用 URLSession；没有启动、定时或后台联网逻辑。") }
            }
            .navigationTitle("手动数据同步")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("关闭") { dismiss() } } }
            .task { await model.load(modelContext: modelContext) }
            .sheet(isPresented: $model.showScanner) { SyncCodeScanner { model.applyScanned($0); model.showScanner = false } }
        }
    }
}

@available(iOS 16.0, *)
private struct ScannerRepresentable: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false, isPinchToZoomEnabled: true, isGuidanceEnabled: true, isHighlightingEnabled: true)
        controller.delegate = context.coordinator; try? controller.startScanning(); return controller
    }
    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void; init(onCode: @escaping (String) -> Void) { self.onCode = onCode }
        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            if case .barcode(let barcode) = item, let value = barcode.payloadStringValue { onCode(value) }
        }
    }
}

private struct SyncCodeScanner: View {
    @Environment(\.dismiss) private var dismiss
    let onCode: (String) -> Void
    var body: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable { ScannerRepresentable(onCode: onCode) }
                else { ContentUnavailableView("扫码不可用", systemImage: "camera.fill", description: Text("请返回后手动输入 IP 和连接码。")) }
            }
            .navigationTitle("扫描二维码").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("取消") { dismiss() } } }
        }
    }
}
