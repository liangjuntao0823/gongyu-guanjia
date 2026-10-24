import Foundation

/// v1.39：房源媒体待上传重试队列（参照云端备份重试队列 CloudBackupService 的模式）。
/// 分享上传媒体失败（弱网/断网/进程被杀）时自动入队，App 启动/回前台自动补传；
/// 补传成功后移除并写操作日志。任务持久化在 UserDefaults（按用户名分 key，多用户互不干扰）。
enum HouseMediaUploadQueue {
    struct Item: Codable, Equatable {
        let roomKey: String
        let fileName: String
        let kind: String
    }

    private static var pendingKey: String { "houseMediaPending.\(CloudUser.safeName)" }

    static func pendingItems() -> [Item] {
        guard let data = UserDefaults.standard.data(forKey: pendingKey),
              let list = try? JSONDecoder().decode([Item].self, from: data) else { return [] }
        return list
    }

    private static func save(_ list: [Item]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: pendingKey)
        }
    }

    /// 媒体上传失败时入队（同房同文件只保留一条）
    static func enqueue(roomKey: String, fileName: String, kind: String) {
        var list = pendingItems()
        let item = Item(roomKey: roomKey, fileName: fileName, kind: kind)
        guard !list.contains(item) else { return }
        list.append(item)
        if list.count > 200 { list = Array(list.suffix(200)) }
        save(list)
    }

    static func remove(roomKey: String, fileName: String) {
        var list = pendingItems()
        list.removeAll { $0.roomKey == roomKey && $0.fileName == fileName }
        save(list)
    }

    /// 启动/回前台：补传全部待上传媒体。单个失败保留队列下次再试；本地文件已删除的（媒体/房源被删）直接清队。
    static func retryAll(config: CosConfig? = nil) async {
        let cfg = config ?? CosConfig.load()
        guard let cfg, cfg.isValid else { return }
        let items = pendingItems()
        guard !items.isEmpty else { return }
        let compress = shareCompressionEnabled
        var successCount = 0
        for item in items {
            let localURL = MediaStore.url(for: item.fileName, roomKey: item.roomKey)
            guard FileManager.default.fileExists(atPath: localURL.path) else {
                remove(roomKey: item.roomKey, fileName: item.fileName)
                continue
            }
            do {
                _ = try await CosUploader.uploadHouseMedia(fileName: item.fileName, kind: item.kind, roomKey: item.roomKey, config: cfg, compress: compress)
                remove(roomKey: item.roomKey, fileName: item.fileName)
                successCount += 1
            } catch {
                // 保留队列，下次启动/回前台再试
            }
        }
        if successCount > 0 {
            BackupLogStore.log(category: "房源", action: "补传媒体", result: "成功", detail: "自动补传 \(successCount) 个媒体", cloud: true)
        }
    }
}
