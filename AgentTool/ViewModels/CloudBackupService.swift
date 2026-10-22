import Foundation

// MARK: - v1.12 云端备份服务（COS）
// 桶内专门文件夹「backups/」用于备份（与分享链接的根目录隔离）：
//   · 快速备份：备份后自动上传（断网/失败自动加入重试队列，下次启动或回前台自动重试）
//   · 全量备份：查看器里手动上传（zip 本体 PUT + 媒体按 sha1 增量，已存在跳过）
//   · 云端文件清单用本地 UserDefaults 记录维护（避免 ListObjects 签名复杂度）
//   · 云端自动清理：只清「快速_」自动上传的 zip，保留最近 10 份；全量手动上传不自动删除
//   · 未配置 COS：快速备份仅存本地，查看器标记「未上传（未配置云端）」

final class CloudBackupService {
    static let shared = CloudBackupService()
    private init() {}

    static let cloudBackupPrefix = "backups/"          // 备份 zip 云端目录
    static let cloudMediaPrefix = "backups/media/"     // 媒体镜像云端目录（按 sha1 去重）

    // MARK: - 云端记录（本地权威清单）

    struct CloudRecord: Codable {
        var name: String
        var size: Int64
        var date: Date
        var isAuto: Bool
    }

    private static let recordsKey = "cloudBackupRecords.v1"

    static func cloudRecords() -> [CloudRecord] {
        guard let data = UserDefaults.standard.data(forKey: recordsKey),
              let list = try? JSONDecoder().decode([CloudRecord].self, from: data) else { return [] }
        return list.sorted { $0.date > $1.date }
    }

    static func isUploaded(name: String) -> Bool {
        cloudRecords().contains { $0.name == name }
    }

    static func uploadState(of name: String) -> String {
        guard CosConfig.load()?.isValid == true else { return "未上传（未配置云端）" }
        if isUploaded(name: name) { return "已上传云端" }
        if pendingUploadNames().contains(name) { return "未上传（将自动重试）" }
        return "未上传"
    }

    static func recordUpload(name: String, size: Int64, date: Date, isAuto: Bool) {
        var list = cloudRecords()
        list.removeAll { $0.name == name }
        list.append(CloudRecord(name: name, size: size, date: date, isAuto: isAuto))
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: recordsKey)
        }
        removePendingUpload(name: name)
    }

    static func removeCloudRecord(name: String) {
        var list = cloudRecords()
        list.removeAll { $0.name == name }
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: recordsKey)
        }
    }

    // MARK: - 待上传重试队列（断网/被系统杀死后下次启动自动重试）

    private static let pendingKey = "cloudBackupPending.v1"

    static func pendingUploadNames() -> [String] {
        UserDefaults.standard.stringArray(forKey: pendingKey) ?? []
    }

    static func enqueuePendingUpload(name: String) {
        var list = pendingUploadNames()
        guard !list.contains(name) else { return }
        list.append(name)
        UserDefaults.standard.set(list, forKey: pendingKey)
    }

    static func removePendingUpload(name: String) {
        var list = pendingUploadNames()
        list.removeAll { $0 == name }
        UserDefaults.standard.set(list, forKey: pendingKey)
    }

    /// 启动/回前台时重试全部待上传（快速备份 zip）
    static func retryPendingUploads(config: CosConfig? = nil) async {
        guard let config = config ?? CosConfig.load(), config.isValid else { return }
        let pending = pendingUploadNames()
        guard !pending.isEmpty else { return }
        for name in pending {
            let local = BackupV5Manager.backupsDirectory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: local.path) else {
                removePendingUpload(name: name)
                continue
            }
            do {
                try await uploadZip(url: local, config: config) { _ in }
                recordUpload(name: name, size: BackupV5Manager.fileSize(at: local), date: Date(), isAuto: true)
            } catch {
                // 保留队列，下次再试
            }
        }
        await enforceCloudRetention(config: config)
    }

    // MARK: - 上传

    /// 上传备份 zip（流式 fromFile，带进度 0~1）
    static func uploadZip(url: URL, config: CosConfig, progress: @escaping (Double) -> Void) async throws {
        let name = url.lastPathComponent
        let remotePath = cloudBackupPrefix + name
        let contentType = "application/zip"
        let signedURL = try CosUploader.presignedPutURL(for: remotePath, contentType: contentType, config: config)
        var request = URLRequest(url: signedURL)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")

        let delegate = UploadProgressDelegate(onProgress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        let task = session.uploadTask(with: request, fromFile: url)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            delegate.onCompletion = { error in
                if let error = error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            }
            task.resume()
        }
    }

    /// 全量备份媒体增量上传：按 media_manifest 的 sha1 判断是否已在云端（backups/media/<sha1>/<文件名>），
    /// 已存在跳过（省流量），否则从 zip 内提取上传。progress 0~1
    static func uploadFullMedia(zipURL: URL, config: CosConfig, progress: @escaping (Double) -> Void) async throws {
        guard let manifestData = try? ZipStore.extract(at: zipURL, path: "media_manifest.json"),
              let fingerprints = try? JSONDecoder().decode([MediaFingerprintV5].self, from: manifestData) else {
            return  // 无清单（异常备份）视为无可增量上传
        }
        let total = max(fingerprints.count, 1)
        var done = 0
        for fp in fingerprints {
            // 云端对象名：backups/media/<sha1前2位>/<sha1>-<文件名>（sha1 目录避免单目录对象过多）
            let digestPrefix = fp.sha1.isEmpty ? "unknown" : String(fp.sha1.prefix(2))
            let remotePath = cloudMediaPrefix + "\(digestPrefix)/\(fp.sha1)-\(fp.fileName)"
            let exists = await remoteExists(path: remotePath, config: config)
            if !exists {
                let data = try ZipStore.extract(at: zipURL, path: "media/\(fp.roomKey)/\(fp.fileName)")
                try await CosUploader.upload(data: data, to: remotePath, contentType: fp.kind == "video" ? "video/quicktime" : "image/jpeg", config: config)
            }
            done += 1
            progress(Double(done) / Double(total))
        }
        progress(1.0)
    }

    /// 自动上传快速备份（失败入队重试，成功后清理队列并执行云端保留）
    static func autoUploadFastBackup(zipURL: URL, config: CosConfig?) async {
        guard let config = config ?? CosConfig.load(), config.isValid else {
            enqueuePendingUpload(name: zipURL.lastPathComponent)
            return
        }
        do {
            try await uploadZip(url: zipURL, config: config) { _ in }
            recordUpload(name: zipURL.lastPathComponent, size: BackupV5Manager.fileSize(at: zipURL), date: Date(), isAuto: true)
        } catch {
            enqueuePendingUpload(name: zipURL.lastPathComponent)
        }
        await enforceCloudRetention(config: config)
    }

    // MARK: - 存在探测 / 下载 / 删除

    /// GET 探测对象是否存在（200 = 存在）
    static func remoteExists(path: String, config: CosConfig) async -> Bool {
        guard let url = try? CosUploader.presignedGetURL(for: path, expires: 300, config: config) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                return true
            }
            return false
        } catch {
            return false
        }
    }

    /// 下载云端备份 zip 到本地临时文件（流式 downloadTask），返回文件 URL
    static func downloadBackup(name: String, config: CosConfig) async throws -> URL {
        let remotePath = cloudBackupPrefix + name
        guard let url = try? CosUploader.presignedGetURL(for: remotePath, expires: 3600, config: config) else {
            throw CosUploader.CosError.invalidConfig
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (tempURL, response) = try await URLSession.shared.download(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: tempURL)
            throw CosUploader.CosError.uploadFailed("云端下载失败（HTTP \(http.statusCode)）")
        }
        // 移到本地 Backups 目录（前缀「下载_」避免与本地快速/全量备份混淆）
        let dest = BackupV5Manager.backupsDirectory.appendingPathComponent("下载_" + name)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tempURL, to: dest)
        return dest
    }

    /// 删除云端备份对象
    static func deleteRemoteBackup(name: String, config: CosConfig) async throws {
        let remotePath = cloudBackupPrefix + name
        guard let url = try? CosUploader.presignedURL(for: remotePath, method: "DELETE", expires: 600, headers: [], config: config) else {
            throw CosUploader.CosError.invalidConfig
        }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw CosUploader.CosError.uploadFailed("云端删除失败（HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)）" + CosUploader.extractCosError(from: data))
        }
        removeCloudRecord(name: name)
    }

    // MARK: - 云端保留（快速_ 自动备份保留最近 10 份）

    static func enforceCloudRetention(config: CosConfig? = nil) async {
        guard let config = config ?? CosConfig.load(), config.isValid else { return }
        var records = cloudRecords().filter { $0.isAuto && $0.name.hasPrefix("快速_") }
        records.sort { $0.date > $1.date }
        guard records.count > 10 else { return }
        for record in records.dropFirst(10) {
            try? await deleteRemoteBackup(name: record.name, config: config)
        }
    }
}

// MARK: - 上传进度 Delegate

private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate {
    private let onProgress: (Double) -> Void
    var onCompletion: ((Error?) -> Void)?
    private var lastReported: Double = -1

    init(onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        let p = min(Double(totalBytesSent) / Double(totalBytesExpectedToSend), 1.0)
        if p - lastReported >= 0.01 || p >= 1.0 {
            lastReported = p
            onProgress(p)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        onCompletion?(error)
    }
}
