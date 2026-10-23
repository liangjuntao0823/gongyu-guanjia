import Foundation

// MARK: - v1.30 数据根目录（全部数据集中在 Documents/备份/ 子文件夹）
/// 微信式备份 v1.30：所有需要备份的数据文件**默认直接存放在「备份」子文件夹**里：
///   housekeeper.store（数据库三件套）、Media/（图片视频按房号分文件夹）、
///   qrcode.png（名片二维码）、ShareCache/（分享缓存）、备份说明.txt
/// 「文件」App 里「公寓管家」根目录保持整洁，只看到一个「备份」文件夹；
/// 复制「备份」子文件夹（或整个「公寓管家」文件夹）= 备份，放回 = 恢复。
enum DataRoot {
    static let name = "备份"

    static func url() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// 房源照片 / 视频文件管理：按房号子目录存到 App 的 Documents/备份/Media/<房号>/ 目录
/// 数据库里只保存文件名，文件本体在磁盘，避免 SwiftData 存储膨胀
/// Documents 已开启文件共享（UIFileSharingEnabled），可在 iOS「文件」App 中查看
/// 文件命名规则：照片「房号-JPG-1.jpg / 房号-JPG-2.jpg …」，视频「房号-MOV-1.mov / 房号-MOV-2.mov …」
///   （序号从 1 开始，取当前第一个空缺序号；删除后自动复用；旧版 UUID 命名的文件仍可正常读取）
enum MediaStore {
    static let mediaDirectoryName = "Media"

    static func mediaDirectory() -> URL {
        let dir = DataRoot.url().appendingPathComponent(mediaDirectoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 某套房源对应的媒体目录（Documents/Media/<房号>/）
    static func houseDirectory(roomKey: String) -> URL {
        let dir = mediaDirectory().appendingPathComponent(roomKey, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 生成「房号-类型-N.扩展名」序号文件名（N 从 1 开始，取当前第一个空缺序号）
    private static func nextFileName(roomKey: String, tag: String, ext: String) -> String {
        let dir = houseDirectory(roomKey: roomKey)
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var n = 1
        while existing.contains("\(roomKey)-\(tag)-\(n).\(ext)") {
            n += 1
        }
        return "\(roomKey)-\(tag)-\(n).\(ext)"
    }

    /// 保存二进制数据（照片转 JPEG 后调用），返回文件名（房号-JPG-N.jpg）
    static func save(data: Data, ext: String, roomKey: String) -> String {
        let cleanExt = ext.lowercased()
        let fileName = nextFileName(roomKey: roomKey, tag: cleanExt.uppercased(), ext: cleanExt)
        let url = houseDirectory(roomKey: roomKey).appendingPathComponent(fileName)
        try? data.write(to: url)
        return fileName
    }

    /// 保存临时文件（相册选中的视频等），拷贝到 App 目录，返回文件名（房号-MOV-N.扩展名）
    static func saveFile(from source: URL, roomKey: String) -> String {
        let ext = source.pathExtension.isEmpty ? "mov" : source.pathExtension
        let cleanExt = ext.lowercased()
        let fileName = nextFileName(roomKey: roomKey, tag: cleanExt.uppercased(), ext: cleanExt)
        let target = houseDirectory(roomKey: roomKey).appendingPathComponent(fileName)
        try? FileManager.default.copyItem(at: source, to: target)
        return fileName
    }

    /// 获取文件完整路径；优先按房号目录读取，兼容旧版平铺目录（Documents/Media/<文件名>）
    static func url(for fileName: String, roomKey: String) -> URL {
        let newURL = houseDirectory(roomKey: roomKey).appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: newURL.path) {
            return newURL
        }
        return mediaDirectory().appendingPathComponent(fileName)
    }

    /// 删除文件（删除房源 / 删除单条媒体时调用），新旧两处路径都清理
    /// 防御：fileName 为空时绝不执行——否则 appendingPathComponent("") 会指向目录本身，removeItem 会误删整个房号目录
    static func delete(fileName: String, roomKey: String) {
        guard !fileName.isEmpty else { return }
        let newURL = houseDirectory(roomKey: roomKey).appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: newURL)
        let legacyURL = mediaDirectory().appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: legacyURL)
    }

    /// 删除房源关联的全部媒体文件
    static func deleteAll(files: [String], roomKey: String) {
        for fileName in files {
            delete(fileName: fileName, roomKey: roomKey)
        }
    }

    /// v1.35：删除整套房源的全部本地文件——整个房号目录 + 旧版平铺文件 + 分享缓存一并清除
    /// （删除房源时调用，保证磁盘不留任何残留）
    static func deleteHouseDirectory(roomKey: String) {
        guard !roomKey.isEmpty else { return }
        // 1) 删除 Documents/备份/Media/<房号>/ 整个目录
        let dir = mediaDirectory().appendingPathComponent(roomKey, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        // 2) 删除该房号分享缓存（<房号>_masked.json / <房号>_full.json / 旧版 <房号>.json）
        let cacheDir = DataRoot.url().appendingPathComponent("ShareCache", isDirectory: true)
        for suffix in ["_masked.json", "_full.json", ".json"] {
            let cache = cacheDir.appendingPathComponent(roomKey + suffix)
            try? FileManager.default.removeItem(at: cache)
        }
    }

    /// v1.35：已收录房源套数——以 Media/ 下房号文件夹数量为准（旧版平铺文件不计入）
    static func houseCount() -> Int {
        let dir = mediaDirectory()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return 0 }
        var count = 0
        for name in names {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path, isDirectory: &isDir), isDir.boolValue {
                count += 1
            }
        }
        return count
    }

    /// 房号变更时，把旧房号目录整体迁移到新房号目录（编辑房号后媒体不丢失）
    static func migrateHouseDirectory(from oldKey: String, to newKey: String) {
        guard oldKey != newKey, !oldKey.isEmpty, !newKey.isEmpty else { return }
        let oldDir = mediaDirectory().appendingPathComponent(oldKey, isDirectory: true)
        let newDir = mediaDirectory().appendingPathComponent(newKey, isDirectory: true)
        guard FileManager.default.fileExists(atPath: oldDir.path) else { return }
        try? FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: oldDir.path)) ?? []
        for name in contents {
            try? FileManager.default.moveItem(
                at: oldDir.appendingPathComponent(name),
                to: newDir.appendingPathComponent(name)
            )
        }
        try? FileManager.default.removeItem(at: oldDir)
    }
}

// MARK: - v1.30 数据备份说明（微信式文件夹备份）

/// 在「备份」子文件夹生成「备份说明.txt」（只写一次），引导用户：备份 = 复制「备份」子文件夹，恢复 = 放回原位。
enum BackupGuide {
    static func ensureExists() {
        let url = DataRoot.url().appendingPathComponent("备份说明.txt")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let text = """
        「公寓管家 · 房源」数据备份说明
        ========================

        本板块的全部数据都放在「备份」这个子文件夹里：
        · housekeeper.store（房源信息数据库）
        · Media/（所有房源图片和视频，按房号分文件夹）
        · qrcode.png（名片二维码）
        · ShareCache/（分享缓存，可忽略）

        【备份】在 iOS「文件」App → 我的 iPhone → 公寓管家 → 备份，长按「备份」文件夹 →
        拷贝/共享到电脑、网盘或微信（建议存两处）。整个「备份」文件夹一起复制，一个都不能少。

        【恢复】重装 App 后，把之前备份的「备份」文件夹放回「文件」App → 我的 iPhone →
        公寓管家 目录内，再打开 App，房源信息和图片视频全部还原。

        【注意】不要只复制 housekeeper.store——图片视频在 Media/ 里，备份必须复制整个「备份」文件夹。
        """
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - 分享链接缓存（v1.18：同一房源的媒体与信息都没变化时，点分享直接复用上次链接，不再重复上传）
// v1.21：缓存按「分享模式」双轨分开（脱敏 masked / 完整 full），两种分享互不影响、各自增量。

/// 缓存的分享卡片记录：媒体清单 + 房源信息快照 + 上次生成的分享链接 + 当时的 COS 配置（换桶/换域名后自动失效）
struct ShareCacheRecord: Codable {
    let mediaFiles: [ShareMediaFile]
    let info: ShareHouseInfo
    let shareURL: String
    let bucket: String
    let region: String
    let customDomain: String?   // v1.19：生成链接时的自定义域名；换域名后旧缓存自动失效（Optional 兼容旧版缓存 JSON）
    var compressOnShare: Bool? = nil          // v1.23：生成链接时的「分享时压缩」开关状态；开关变化 → 缓存失效重新上传（Optional 兼容旧版）
    var collectionRooms: [ShareCollectionItem]? = nil   // v1.22：合集分享缓存——记录合集包含的每套房源快照；任一套变动 → 缓存失效重新生成（Optional 兼容旧版）
    var templateVersion: Int? = nil           // v1.25：生成链接时的 HTML 模板版本；模板改动（改页面设计）→ 旧缓存自动失效重新生成（Optional 兼容旧版）
    var qrcodeSet: Bool? = nil                // v1.27：生成链接时是否已设置微信二维码；设置/清除二维码 → 旧缓存失效重新生成（Optional 兼容旧版）
    var watermarkHash: String? = nil           // v1.36：生成链接时的水印设置哈希；水印开关/文本/样式变化 → 旧缓存失效重新生成（Optional 兼容旧版）
}

enum ShareCacheStore {
    private static var directory: URL {
        let dir = DataRoot.url().appendingPathComponent("ShareCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 按模式分文件：<房号>_masked.json / <房号>_full.json
    private static func fileURL(roomKey: String, mode: String) -> URL {
        directory.appendingPathComponent("\(roomKey)_\(mode).json")
    }

    /// 旧版单文件缓存（v1.18~1.20：<房号>.json，等价于现在的脱敏版缓存）
    private static func legacyFileURL(roomKey: String) -> URL {
        directory.appendingPathComponent("\(roomKey).json")
    }

    private static func decode(_ url: URL) -> ShareCacheRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ShareCacheRecord.self, from: data)
    }

    /// 按分享模式读取缓存；脱敏版优先读新模式文件，其次兼容旧版单文件（升级后第一次分享不重复上传）
    static func load(roomKey: String, mode: String) -> ShareCacheRecord? {
        let primary = fileURL(roomKey: roomKey, mode: mode)
        if let record = decode(primary) { return record }
        if mode == "masked", let record = decode(legacyFileURL(roomKey: roomKey)) { return record }
        return nil
    }

    static func save(roomKey: String, mode: String, record: ShareCacheRecord) {
        if let data = try? JSONEncoder().encode(record) {
            try? data.write(to: fileURL(roomKey: roomKey, mode: mode))
        }
    }

    /// v1.25：清空全部分享缓存（设置页「刷新分享缓存」按钮调用）——
    /// 改了页面样式、名片或想强制重新上传时手动触发；正常情况不需要，模板版本变化会自动失效
    static func clearAll() {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in files where name.hasSuffix(".json") {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
