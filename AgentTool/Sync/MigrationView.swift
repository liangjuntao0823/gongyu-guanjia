import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import CoreImage.CIFilterBuiltins
import VisionKit

extension UTType {
    static let zfgjMigration = UTType(exportedAs: "com.agenttool.zfgj", conformingTo: .json)
}

struct ZFGJMigrationDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.zfgjMigration, .json] }
    var data: Data

    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

@MainActor
final class MigrationViewModel: ObservableObject {
    @Published var exportDocument = ZFGJMigrationDocument()
    @Published var isExporting = false
    @Published var isImporting = false
    @Published var showScanner = false
    @Published var message = "迁移只会在你主动导出或导入时执行"
    @Published var connection = SyncConnectionInfo(host: "", port: 8765, code: "")
    @Published var importReady = false
    @Published var stagedImport: Data?

    func prepareExport(context: ModelContext) {
        do {
            exportDocument = ZFGJMigrationDocument(data: try DataBackupManager.shared.exportAllData(modelContext: context))
            isExporting = true
            message = "迁移包已生成，请选择保存位置"
        } catch { message = "导出失败：\(error.localizedDescription)" }
    }

    func stageImport(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard (values.fileSize ?? 0) <= 10 * 1024 * 1024 else { throw MigrationError.fileTooLarge }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["schemaVersion"] != nil else { throw MigrationError.invalidPackage }
            stagedImport = data; importReady = true
            message = "文件校验通过。点击确认后会先备份当前数据，再导入。"
        } catch { stagedImport = nil; importReady = false; message = "读取失败：\(error.localizedDescription)" }
    }

    func confirmImport(context: ModelContext) {
        guard let data = stagedImport else { return }
        do {
            let current = try DataBackupManager.shared.exportAllData(modelContext: context)
            guard DataBackupManager.shared.saveBackup(current, type: .total, name: "迁移前自动备份", isAuto: true) != nil else {
                throw MigrationError.backupFailed
            }
            importReady = false
            DataBackupManager.shared.importAllData(from: data, modelContext: context, scope: .all) { [weak self] success, text in
                Task { @MainActor in
                    self?.message = success ? "导入完成：\(text)" : "导入失败，未完成迁移：\(text)"
                    if success { self?.stagedImport = nil }
                }
            }
        } catch { message = "导入前备份失败，已停止导入：\(error.localizedDescription)" }
    }

    func applyScanned(_ text: String) {
        guard let value = SyncConnectionInfo.parse(text) else { message = "二维码不是有效迁移连接信息"; return }
        connection = value; message = "已读取迁移连接信息；不会自动联网"
    }
}

private enum MigrationError: LocalizedError {
    case fileTooLarge, invalidPackage, backupFailed
    var errorDescription: String? {
        switch self {
        case .fileTooLarge: return "迁移包超过 10MB"
        case .invalidPackage: return "不是有效的 .zfgj 迁移包"
        case .backupFailed: return "无法保存迁移前备份"
        }
    }
}

struct MigrationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @StateObject private var model = MigrationViewModel()

    var body: some View {
        NavigationStack {
            Form {
                Section("迁移文件") {
                    Button { model.prepareExport(context: modelContext) } label: {
                        Label("导出 .zfgj 到新设备", systemImage: "square.and.arrow.up")
                    }
                    Button { model.isImporting = true } label: {
                        Label("选择 .zfgj 从旧设备导入", systemImage: "square.and.arrow.down")
                    }
                    if model.importReady {
                        Button("确认：先备份本机，再正式导入", role: .destructive) {
                            model.confirmImport(context: modelContext)
                        }
                    }
                    Text(model.message).font(.footnote).foregroundStyle(.secondary)
                }

                Section("迁移连接二维码") {
                    TextField("IP 或服务器地址", text: $model.connection.host)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("端口", value: $model.connection.port, format: .number).keyboardType(.numberPad)
                    SecureField("连接码", text: $model.connection.code)
                    if !model.connection.host.isEmpty && !model.connection.code.isEmpty {
                        QRCodeImage(text: model.connection.qrText)
                            .frame(width: 210, height: 210).frame(maxWidth: .infinity)
                            .accessibilityLabel("迁移连接二维码")
                    }
                    Button { model.showScanner = true } label: {
                        Label("扫描旧设备二维码", systemImage: "qrcode.viewfinder")
                    }
                    Text("二维码只编码 IP、端口和连接码；扫描后不会自动联网。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("说明") {
                    Text("换机迁移是一次性复制，不作为日常多端同步。导入前会检查文件大小和结构，并保存当前全量备份。")
                }
            }
            .navigationTitle("备份与迁移")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("关闭") { dismiss() } } }
            .fileExporter(isPresented: $model.isExporting, document: model.exportDocument, contentType: .zfgjMigration, defaultFilename: "公寓管家迁移包.zfgj") { result in
                model.message = (try? result.get()) != nil ? "迁移包导出完成" : "迁移包导出失败"
            }
            .fileImporter(isPresented: $model.isImporting, allowedContentTypes: [.zfgjMigration, .json], allowsMultipleSelection: false, onCompletion: model.stageImport)
            .sheet(isPresented: $model.showScanner) {
                MigrationCodeScanner { model.applyScanned($0); model.showScanner = false }
            }
        }
    }
}

private struct QRCodeImage: View {
    let text: String
    private let context = CIContext()
    private let filter = CIFilter.qrCodeGenerator()
    var body: some View {
        Group {
            if let image = image { Image(uiImage: image).interpolation(.none).resizable() }
            else { Color.secondary.opacity(0.2) }
        }
    }
    private var image: UIImage? {
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = context.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

private struct MigrationCodeScanner: View {
    @Environment(\.dismiss) private var dismiss
    let onCode: (String) -> Void
    var body: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    MigrationScannerRepresentable(onCode: onCode)
                } else {
                    ContentUnavailableView("扫码不可用", systemImage: "camera.fill", description: Text("请返回后手动输入迁移连接信息。"))
                }
            }
            .navigationTitle("扫描迁移二维码").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("取消") { dismiss() } } }
        }
    }
}

private struct MigrationScannerRepresentable: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false, isPinchToZoomEnabled: true, isGuidanceEnabled: true, isHighlightingEnabled: true)
        controller.delegate = context.coordinator
        try? controller.startScanning()
        return controller
    }
    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }
        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            if case .barcode(let code) = item, let value = code.payloadStringValue { onCode(value) }
        }
    }
}
