import Foundation

// MARK: - v1.30 数据根目录（全部数据集中在 Documents/备份/ 子文件夹）
/// 微信式备份 v1.30：所有需要备份的数据文件**默认直接存放在「备份」子文件夹**里：
///   housekeeper.store（数据库三件套）、Media/（图片视频按房号分文件夹）、
///   qrcode.png（名片二维码）、ShareCache/（分享缓存）、备份说明.txt
/// 「文件」App 里「公寓管家」根目录保持整洁，只看到一个「备份」文件夹；
/// 复制「备份」子文件夹（或整个「公寓管家」文件夹）= 备份，放回 = 恢复。
/// v1.40 第9点（本地根目录重建）：软件根目录下平级两个子文件夹——「备份」与「media」。
/// 「备份」= 数据库/备份包/配置/说明/缓存；「media」= 房源媒体（原 备份/Media 整体移出）。
enum DataRoot {
    static let name = "备份"

    static func url() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// 房源照片 / 视频文件管理：按房号子目录存到 App 的 Documents/media/<房号>/ 目录
/// （v1.40 前为 Documents/备份/Media/<房号>/，升级启动时自动整体迁移，读取兼容旧位置）
/// 数据库里只保存文件名，文件本体在磁盘，避免 SwiftData 存储膨胀
/// Documents 已开启文件共享（UIFileSharingEnabled），可在 iOS「文件」App 中查看
/// 文件命名规则：照片「房号-JPG-1.jpg / 房号-JPG-2.jpg …」，视频「房号-MOV-1.mov / 房号-MOV-2.mov …」
///   （序号从 1 开始，取当前第一个空缺序号；删除后自动复用；旧版 UUID 命名的文件仍可正常读取）
enum MediaStore {
    static let mediaDirectoryName = "media"

    static func mediaDirectory() -> URL {
        // v1.40 第9点：媒体独立到 Documents/media/，与「备份」平级，不再挂在备份文件夹下
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent(mediaDirectoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// v1.40 旧版媒体目录（Documents/备份/Media/，升级前的位置，迁移后仅用于兼容读取/清理）
    static var legacyMediaDirectory: URL {
        DataRoot.url().appendingPathComponent("Media", isDirectory: true)
    }

    /// v1.40 第9点：启动时幂等迁移——把 备份/Media 整体搬到 Documents/media/
    /// 目标已存在（迁移过/新装）则跳过；只搬不移删，不丢数据
    static func migrateLegacyMediaIfNeeded() {
        let fm = FileManager.default
        let legacy = legacyMediaDirectory
        let target = mediaDirectory()
        guard fm.fileExists(atPath: legacy.path) else { return }   // 无旧目录 = 全新安装
        guard !fm.fileExists(atPath: target.path) else { return }  // 新目录已有内容 = 已完成，跳过
        try? fm.moveItem(at: legacy, to: target)
    }

    /// 某套房源对应的媒体目录（Documents/media/<房号>/）
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

    /// 获取文件完整路径；优先按新目录读取，兼容旧版目录结构（备份/Media/<房号>/）与旧版平铺目录（备份/Media/<文件名>）
    static func url(for fileName: String, roomKey: String) -> URL {
        let newURL = houseDirectory(roomKey: roomKey).appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: newURL.path) {
            return newURL
        }
        // v1.40 兼容：升级前旧目录 备份/Media/<房号>/<文件>（迁移未完成或读取旧备份时）
        let legacyHouseURL = legacyMediaDirectory.appendingPathComponent(roomKey, isDirectory: true).appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: legacyHouseURL.path) {
            return legacyHouseURL
        }
        // 旧版平铺目录（备份/Media/<文件名>；迁移后平铺文件已随目录一起进入 media/）
        return mediaDirectory().appendingPathComponent(fileName)
    }

    /// 删除文件（删除房源 / 删除单条媒体时调用），新旧两处路径都清理
    /// 防御：fileName 为空时绝不执行——否则 appendingPathComponent("") 会指向目录本身，removeItem 会误删整个房号目录
    static func delete(fileName: String, roomKey: String) {
        guard !fileName.isEmpty else { return }
        let newURL = houseDirectory(roomKey: roomKey).appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: newURL)
        // v1.40：旧目录结构与平铺路径一并清理
        let legacyHouseURL = legacyMediaDirectory.appendingPathComponent(roomKey, isDirectory: true).appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: legacyHouseURL)
        let legacyURL = legacyMediaDirectory.appendingPathComponent(fileName)
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

    /// v1.37：列出某房号目录下实际存在的媒体文件名（用于检测本地媒体是否缺失、是否需要从云端回补）
    static func existingFileNames(roomKey: String) -> Set<String> {
        let dir = houseDirectory(roomKey: roomKey)
        return Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
    }

    /// v1.37：按指定文件名写入媒体数据（云端同步回补用；已存在则覆盖），返回是否写入成功
    static func write(data: Data, fileName: String, roomKey: String) -> Bool {
        guard !fileName.isEmpty else { return false }
        let url = houseDirectory(roomKey: roomKey).appendingPathComponent(fileName)
        do {
            try data.write(to: url)
            return true
        } catch {
            return false
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
/// v1.40 第9点：根目录重建后更新说明——media 独立在「公寓管家」根目录，与「备份」平级
enum BackupGuide {
    static func ensureExists() {
        let url = DataRoot.url().appendingPathComponent("备份说明.txt")
        // v1.40：文件不存在，或还是旧结构说明（不含「media/」标记）→ 重写为新版说明
        if let existing = try? String(contentsOf: url, encoding: .utf8), existing.contains("media/") {
            return
        }
        let text = """
        「公寓管家」数据目录说明
        ========================

        App 数据放在「文件」App → 我的 iPhone → 公寓管家 下，分两个子文件夹：

        · 备份/ —— 房源信息数据库（housekeeper.store）、备份包（Backups/）、
          恢复前快照（PreRestore/）、云端配置（CosConfig/）、分享缓存（ShareCache/）、
          名片二维码（qrcode.png）、操作日志（Logs/）、本说明文件
        · media/ —— 所有房源图片和视频，按房号分文件夹

        【备份】把「备份」和「media」两个文件夹一起拷贝/共享到电脑、网盘或微信（建议存两处），
        一个都不能少。

        【恢复】重装 App 后，把之前备份的「备份」「media」两个文件夹放回
        「文件」App → 我的 iPhone → 公寓管家 目录内，再打开 App，房源信息和图片视频全部还原。

        【注意】图片视频在 media/ 里，不在 备份/ 里——备份必须两个文件夹一起复制。
        更省心的是用 App 内的「一键备份」（快速备份：数据+日志；全量备份：数据+日志+全部媒体）。
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
