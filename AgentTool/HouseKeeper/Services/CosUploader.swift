import Foundation
import CryptoKit
import Security
import UIKit
import AVFoundation
import SwiftUI
import WebKit

// MARK: - 钥匙串存取（COS 密钥等敏感配置）

/// v1.3：分享压缩开关默认开启——未设置过时按开启处理（省流量、省 COS 费用）
var shareCompressionEnabled: Bool {
    UserDefaults.standard.object(forKey: "compressOnShare") == nil || UserDefaults.standard.bool(forKey: "compressOnShare")
}

enum KeychainKey {
    static let bucket = "cos.bucket"
    static let region = "cos.region"
    static let secretId = "cos.secretId"
    static let secretKey = "cos.secretKey"
    static let customDomain = "cos.customDomain"   // v1.19：自定义域名（可空），空 = 用 COS 默认域名
    static let shareName = "share.name"            // v1.21：分享名片-姓名（可空，空 = 梁涛）
    static let sharePhone = "share.phone"          // v1.21：分享名片-电话（可空，空 = 13288251132）
    static let adminPassword = "cloud.adminPassword"  // v1.40：后台口令改存钥匙串（重装 App 不丢，避免云端后台 401）
}

enum KeychainStore {
    private static let service = "com.zfgj.housekeeper"

    /// v1.20：返回写入结果（true=成功）。此前写入失败被静默吞掉，用户以为保存成功实际没写入。
    /// kSecAttrAccessibleAfterFirstUnlock 提高开机解锁前访问的可靠性
    @discardableResult
    static func save(_ value: String, for key: String) -> Bool {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecDuplicateItem
    }

    static func load(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - COS 配置

struct CosConfig {
    let bucket: String
    let region: String
    let secretId: String
    let secretKey: String
    let customDomain: String   // v1.19：自定义域名（如 share.fangyuan88.site），空 = 用默认域名

    var isValid: Bool {
        !bucket.isEmpty && !region.isEmpty && !secretId.isEmpty && !secretKey.isEmpty
    }

    /// 从钥匙串读取配置（自动去掉首尾空格，避免复制粘贴带入空白导致签名失败）
    static func load() -> CosConfig? {
        let trimSet = CharacterSet.whitespacesAndNewlines
        let bucket = (KeychainStore.load(KeychainKey.bucket) ?? "").trimmingCharacters(in: trimSet)
        let region = (KeychainStore.load(KeychainKey.region) ?? "").trimmingCharacters(in: trimSet)
        let secretId = (KeychainStore.load(KeychainKey.secretId) ?? "").trimmingCharacters(in: trimSet)
        let secretKey = (KeychainStore.load(KeychainKey.secretKey) ?? "").trimmingCharacters(in: trimSet)
        let customDomain = (KeychainStore.load(KeychainKey.customDomain) ?? "").trimmingCharacters(in: trimSet)
        let config = CosConfig(bucket: bucket, region: region, secretId: secretId, secretKey: secretKey, customDomain: customDomain)
        return config.isValid ? config : nil
    }
}

// MARK: - 分享模式（v1.21：脱敏 / 完整 双模板、双缓存、双链接）

/// masked = 脱敏版（发给找房客户）：只显示户型 + 位置导航 + 实拍 + 名片，隐藏房号/价格/房东
/// full   = 完整版（发给同事）：显示房号/房东/价格/密码/户型/备注全部信息
enum ShareMode: String {
    case masked = "masked"
    case full = "full"

    /// 分享页固定路径后缀：两个模式独立页面互不覆盖
    var pageSuffix: String {
        switch self {
        case .masked: return "share"
        case .full: return "share-full"
        }
    }

    /// v1.36：文件名/记录用的中文模式标签
    var modeLabel: String {
        switch self {
        case .masked: return "脱敏版"
        case .full: return "完整版"
        }
    }
}

// MARK: - 名片微信二维码（v1.27）

/// 微信二维码存储：设置页「名片信息」上传保存为 Documents/备份/qrcode.png（v1.30 随数据一起进「备份」子文件夹）。
/// 分享时若已设置二维码，统一压缩后上传 COS 固定路径 h/_qrcode/qr.jpg（覆盖写），
/// 所有 H5 名片板块用该固定路径的签名 URL 引用——二维码更换后，
/// 之前已发出的分享链接会自动显示新二维码（路径不变，读取的是当前对象内容），无需重新分享。
enum QrcodeStore {
    static let fileName = "qrcode.png"

    static var fileURL: URL {
        DataRoot.url().appendingPathComponent(fileName)
    }

    @discardableResult
    static func save(_ data: Data) -> Bool {
        do {
            try data.write(to: fileURL)
            return true
        } catch {
            return false
        }
    }

    static func loadData() -> Data? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try? Data(contentsOf: fileURL)
    }

    static func exists() -> Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

// MARK: - 腾讯云 COS V5 预签名上传（HMAC-SHA1，零第三方依赖）

enum CosUploader {

    /// 分享链接有效期：永久（10 年，COS 预签名 URL 上限内足够长，视为长期有效）
    static let shareLinkExpires: Int = 3650 * 86400

    /// v1.25：HTML 模板版本号。每次修改 H5 页面模板（buildMaskedHTML / buildFullHTML / buildCollectionHTML /
    /// mediaBlockHTML 等）后必须 +1——缓存校验会比对模板版本，版本变了旧缓存自动失效，
    /// 下次分享自动重新生成并上传新页面，无需任何手动操作。
    /// 这就解决了「改了网页设计但房源信息没变化、缓存命中还是旧链接」的问题。
    /// v1.27：名片板块改版（二维码 + 新底色）→ 2→3；且二维码是否存在也纳入缓存校验（qrcodeSet），
    /// 用户设置/清除二维码后旧缓存自动失效重新生成页面。
    /// v1.28：二维码下方新增「长按二维码加我好友」小字提示 → 3→4
    /// v1.29：视频统一转 mp4 上传（安卓/微信可播），云端视频路径改 .mp4 → 4→5，旧缓存全部失效重传
    static let htmlTemplateVersion = 5

    enum CosError: LocalizedError {
        case invalidConfig
        case missingMedia
        case customDomainMissing      // v1.20：未填自定义域名，微信无法渲染卡片
        case uploadFailed(String)
        case responseInvalid

        var errorDescription: String? {
            switch self {
            case .invalidConfig:
                return "云存储配置不完整，请先在设置页填写并保存验证"
            case .missingMedia:
                return "这套房源还没有照片或视频，先编辑添加素材再分享"
            case .customDomainMissing:
                return "未填写自定义域名，分享链接会被微信识别成文件而不是卡片。请到设置页把 share.fangyuan88.site 填入「自定义域名」栏并保存"
            case .uploadFailed(let msg):
                return "上传失败：" + msg
            case .responseInvalid:
                return "上传服务返回异常，请稍后重试"
            }
        }
    }

    /// 为房源生成 H5 分享卡片（v1.21：按 mode 生成脱敏版 / 完整版，各自独立页面、独立缓存、独立链接）
    /// - v1.17：og 标签 / 媒体 src 全部用绝对签名 URL（10 年有效），微信能抓到封面渲染成卡片
    /// - v1.18：分享页路径改为【无扩展名】h/<roomKey>/share（微信不再按 index.html 文件识别）；
    ///   同一房源媒体与信息未变化时【零上传】直接复用上次链接；只新增媒体/只改信息时仅上传增量
    /// - v1.19（方案 A 准备）：①支持【自定义域名】；②og:image 改用【压缩封面】cover（最长边 400px）；③链接追加版本参数 v
    /// - v1.20：①分享前强制校验自定义域名已填；②host 自动剥离用户误填的 https:// 前缀与尾部斜杠
    /// - v1.21：①分享模式双轨（脱敏/完整），模板按设计稿定稿（隐藏版/完整版）；
    ///   ②缓存按模式分文件（_masked / _full），互不影响、各自增量；升级后脱敏版兼容旧单文件缓存；
    ///   ③媒体排序视频置顶、图片单列（模板要求）；④名片姓名/电话来自设置页（可编辑）；
    ///   ⑤图片改 CSS 背景图渲染 + 全局禁右键/禁长按选择，视频 controlsList=nodownload（防保存下载）
    /// - v1.22：①微信卡片描述：名字电话放在最底下一行（脱敏=位置行+名片行，完整=信息行+名片行）；
    ///   ②完整版信息板块重排：第一行房号+户型、第二行租金+密码（密码：xxx）+房东（最右）、第三行备注；
    ///   ③H5 图片点击放大后支持左右滑动切换上一张/下一张；④视频不自动播放（点击才播，preload=none）；
    ///   ⑤户型标题去重（户型已含「上/下」时不再重复拼接房号后缀）
    /// 入参全部为值类型（ShareMediaFile / ShareHouseInfo），Task 内不触碰 SwiftData 模型，避免跨线程访问闪退
    /// v1.13 需求13：progress 回调（0~1），按「需上传媒体数 + 固定任务」估算总进度；缓存命中复用链接时直接回调 1.0
    static func shareCard(mediaFiles: [ShareMediaFile], roomKey: String, info: ShareHouseInfo, mode: ShareMode, config: CosConfig, progress: ((Double) -> Void)? = nil) async throws -> URL {
        guard !mediaFiles.isEmpty else { throw CosError.missingMedia }
        // v1.20：微信渲染卡片必须走自定义域名；没填就不生成链接，直接告诉用户去哪填
        guard !config.customDomain.isEmpty else { throw CosError.customDomainMissing }

        // 0. 缓存命中（按模式）：v1.40 第7点简化——用户私有目录里已有缓存且关键渲染参数
        //    （桶/域名/压缩开关/模板版本/二维码/水印）未变 → 直接复用上次链接，零上传；
        //    不再逐项比对媒体清单与房源信息（媒体新增走下方增量上传；信息变化只重生成页面，不重复传媒体）
        let compressOnShare = shareCompressionEnabled
        let hasQR = QrcodeStore.exists()
        if let cached = ShareCacheStore.load(roomKey: roomKey, mode: mode.rawValue),
           cached.bucket == config.bucket,
           cached.region == config.region,
           (cached.customDomain ?? "") == config.customDomain,
           (cached.compressOnShare ?? false) == compressOnShare,
           (cached.templateVersion ?? 0) == htmlTemplateVersion,
           (cached.qrcodeSet ?? false) == hasQR,
           (cached.watermarkHash ?? "") == Self.watermarkHash(WatermarkSettingsStore.current),
           let cachedURL = URL(string: cached.shareURL) {
            progress?(1.0)
            return cachedURL
        }

        // 1. 确定需上传的媒体：桶/地域未变时只上传新增媒体（媒体对象与信息无关，信息变化只重生成页面与链接）
        var toUpload = mediaFiles
        if let cached = ShareCacheStore.load(roomKey: roomKey, mode: mode.rawValue),
           cached.bucket == config.bucket,
           cached.region == config.region,
           (cached.compressOnShare ?? false) == compressOnShare {
            let cachedSet = Set(cached.mediaFiles)
            toUpload = mediaFiles.filter { !cachedSet.contains($0) }
        }

        // v1.13 需求13：进度按「需上传任务数」估算——媒体（每项含压缩+上传+可能缩略图）1 项 + 封面 1 项 + 二维码 1 项 + 页面 1 项
        let totalTasks = max(1, toUpload.count + (mediaFiles.contains { $0.kind == "image" } ? 1 : 0) + (hasQR ? 1 : 0) + 1)
        var completedTasks = 0
        func reportProgress(_ taskFraction: Double) {
            progress?(min(Double(completedTasks) + taskFraction, Double(totalTasks)) / Double(totalTasks))
        }

        // 2. 媒体排序（v1.21 模板要求）：视频置顶第一位、图片在后
        let ordered = mediaFiles.sorted { lhs, rhs in
            let l = lhs.kind == "video" ? 0 : 1
            let r = rhs.kind == "video" ? 0 : 1
            return l < r
        }

        // 3. 上传新增媒体并生成绝对 GET 签名 URL；视频生成封面播放器（封面用独立首帧图），图片收集 URL 待模板渲染（img 渲染）
        // v1.23：开启「分享时压缩」开关 → 视频压到 720p（H.264 mp4）、图片轻压缩（长边≤1600 JPEG q0.8）后再上传
        // v1.25：视频封面改为独立首帧图（vthumb.jpg）——封面不再用视频 URL 当背景图，彻底避免微信预取视频流；
        //   video 标签无 src 无 poster，微信绝无自动播放的可能，只有点击封面才注入 src 播放
        // v1.40 第2点：上传前先探测桶内是否已有该媒体（HEAD），已有则跳过上传直接引用——换机/清缓存后不再重复覆盖桶内原文件
        // v1.40 第6点：H5 页面/封面/视频首帧图/二维码全部改到用户私有目录 users/<用户名>/，只有房源原始媒体留在共享区 h/<房号>/
        var videoTags: [String] = []
        var imageAbsURLs: [String] = []
        for item in ordered {
            // v1.29：视频云端路径统一用 .mp4（安卓/微信可播）。本地保留原文件，上传/引用的是 mp4
            let isVideo = item.kind == "video"
            let remoteName = isVideo ? cloudVideoName(for: item.name) : item.name
            let remotePath = "h/\(roomKey)/\(remoteName)"
            if toUpload.contains(item) {
                // v1.40：桶内已存在同一对象 → 跳过上传（复用），不重复覆盖
                if await remoteObjectExists(path: remotePath, config: config) == false {
                    let url = MediaStore.url(for: item.name, roomKey: roomKey)
                    guard FileManager.default.fileExists(atPath: url.path) else { continue }
                    var data = try Data(contentsOf: url)
                    var contentType = mimeType(for: item.kind, name: remoteName)
                    if isVideo {
                        // v1.29：无论压缩开关，视频一律转 mp4 上传——安卓微信对 .mov/QuickTime 容器支持差，
                        // mp4（H.264+AAC）iOS/安卓通吃；压缩开关开 → 720p，关 → 原质量转封装（不重编码，秒级）
                        if let mp4 = await uploadVideoData(from: url, compress: compressOnShare) {
                            data = mp4
                            contentType = "video/mp4"
                        }
                    } else if compressOnShare, let compressed = compressedImageData(from: url) {
                        data = compressed
                        contentType = "image/jpeg"
                    }
                    do {
                        try await uploadWithProgress(data: data, to: remotePath, contentType: contentType, config: config) { p in
                            // 媒体项自身进度占 1 个任务
                            reportProgress(Double(p))
                        }
                    } catch {
                        // v1.40 第5点：上传失败入队，App 启动/回前台自动补传
                        HouseMediaUploadQueue.enqueue(roomKey: roomKey, fileName: item.name, kind: item.kind)
                        throw error
                    }
                }
                completedTasks += 1
            }
            // v1.25/v1.40：视频首帧封面图——每个 H5 页面都重新生成上传（用户第 a2 点裁决：不检测云端/本地是否有，
            // 因为创建房源时不会生成该缩略图，检测无意义）；路径改用户私有目录
            if isVideo {
                let thumbRemotePath = "\(CloudUser.sharePagePrefix)\(roomKey)/\(item.name).vthumb.jpg"
                let localURL = MediaStore.url(for: item.name, roomKey: roomKey)
                if FileManager.default.fileExists(atPath: localURL.path),
                   let thumbData = makeVideoThumbJPEG(from: localURL) {
                    try? await upload(data: thumbData, to: thumbRemotePath, contentType: "image/jpeg", config: config)
                }
            }
            let absURL = try presignedGetURL(for: remotePath, expires: shareLinkExpires, config: config).absoluteString
            if isVideo {
                // v1.25：video 无 src、无 poster、无 autoplay；封面用独立首帧图；点击封面 playVideo 才注入 src 并播放
                let thumbRemotePath = "\(CloudUser.sharePagePrefix)\(roomKey)/\(item.name).vthumb.jpg"
                let thumbURL = (try? presignedGetURL(for: thumbRemotePath, expires: shareLinkExpires, config: config).absoluteString) ?? absURL
                videoTags.append("<div class=\"vwrap\" onclick=\"playVideo(this,'\(absURL)')\"><div class=\"vthumb\" style=\"background-image:url('\(thumbURL)')\"></div><div class=\"vplay\">▶</div><video class=\"v\" controls controlsList=\"nodownload\" disablepictureinpicture playsinline webkit-playsinline preload=\"none\"></video></div>")
            } else {
                imageAbsURLs.append(absURL)
            }
        }
        guard !videoTags.isEmpty || !imageAbsURLs.isEmpty else { throw CosError.missingMedia }

        // 4. 压缩封面（v1.19）：第一张照片压缩成最长边 400px JPEG 上传为 h/<roomKey>/cover（两模式共用）
        // v1.40 第6点：封面改存用户私有目录 users/<用户名>/shares/<房号>/cover（仅自己页面引用，微信 og:image 用签名 URL）
        var coverSrc = imageAbsURLs.first ?? ""
        if let firstImage = mediaFiles.first(where: { $0.kind == "image" }),
           let coverData = makeCoverJPEG(from: MediaStore.url(for: firstImage.name, roomKey: roomKey)) {
            let coverPath = "\(CloudUser.sharePagePrefix)\(roomKey)/cover"
            do {
                try await uploadWithProgress(data: coverData, to: coverPath, contentType: "image/jpeg", config: config) { p in
                    reportProgress(Double(p))
                }
                coverSrc = try presignedGetURL(for: coverPath, expires: shareLinkExpires, config: config).absoluteString
            } catch {
                // 封面失败不阻塞：沿用第一张原图
            }
            completedTasks += 1
        }

        // 4.1 名片微信二维码（v1.27）：设置页已上传时，压成小图覆盖写到用户私有目录 users/<用户名>/qrcode.jpg；
        //     v1.40 第6点：从公共 h/_qrcode/qr.jpg 迁移到用户目录，避免其他用户读到自己的二维码
        var qrSrc = ""
        if hasQR, let qrData = makeQRCodeJPEG() {
            try? await uploadWithProgress(data: qrData, to: CloudUser.qrPath, contentType: "image/jpeg", config: config) { p in
                reportProgress(Double(p))
            }
            qrSrc = (try? presignedGetURL(for: CloudUser.qrPath, expires: shareLinkExpires, config: config).absoluteString) ?? ""
            completedTasks += 1
        }

        // 5. 生成并上传分享页。v1.36：文件名=房号+模式+日期时间（空 app 无存量链接，直接换新命名）。
        //    链接追加版本参数 v（内容更新 → v 变 → 微信重新抓卡片）
        //    v1.40 第6点：页面改存用户私有目录 users/<用户名>/shares/<房号>/
        let wm = Self.watermarkOverlayHTML(WatermarkSettingsStore.current)
        let pagePath = "\(CloudUser.sharePagePrefix)\(roomKey)/\(Self.safeFileName(info.displayRoomNo))_\(mode.modeLabel)_\(Self.shareTimeTag()).html"
        let shareURL = try presignedGetURL(for: pagePath, expires: shareLinkExpires, config: config)
        let versionedURL = appendVersionParameter(shareURL, version: "\(Int(Date().timeIntervalSince1970))")

        // 名片姓名/电话：优先取设置页保存值（调用方已填入 info），缺失/旧版缓存时回退默认值
        let name = (info.name ?? "").isEmpty ? "梁涛" : info.name!
        let phone = (info.phone ?? "").isEmpty ? "13288251132" : info.phone!

        let html: String
        switch mode {
        case .masked:
            // 微信卡片：标题=户型（突出）；描述=位置行 + 名字电话行（最底下一行）
            let title = layoutTitle(info.layout, roomNo: info.displayRoomNo)
            let desc = "利保米兰公馆\n\(name)-\(phone)"
            html = buildMaskedHTML(
                title: title, desc: desc,
                name: name, phone: phone,
                videoTags: videoTags, imageURLs: imageAbsURLs,
                coverSrc: coverSrc, qrSrc: qrSrc, shareLink: versionedURL.absoluteString,
                wm: wm, trackScript: Self.cloudTrackScript(room: info.displayRoomNo, mode: mode.modeLabel)
            )
        case .full:
            let title = "\(info.displayRoomNo) · \(info.layout.isEmpty ? "房源" : info.layout)"
            let desc = "\(info.priceText) · \(info.landlord.isEmpty ? "房东信息见页内" : info.landlord)\n\(name)-\(phone)"
            html = buildFullHTML(
                title: title, desc: desc,
                info: info, name: name, phone: phone,
                videoTags: videoTags, imageURLs: imageAbsURLs,
                coverSrc: coverSrc, qrSrc: qrSrc, shareLink: versionedURL.absoluteString,
                wm: wm, trackScript: Self.cloudTrackScript(room: info.displayRoomNo, mode: mode.modeLabel)
            )
        }
        try await uploadWithProgress(data: Data(html.utf8), to: pagePath, contentType: "text/html; charset=utf-8", config: config) { p in
            // 页面是最后一项：占剩余任务
            reportProgress(Double(p))
        }
        completedTasks += 1
        progress?(1.0)

        // 6. 更新缓存（按模式分文件；含自定义域名、压缩开关、模板版本与水印哈希，任一变化后旧缓存自动失效）
        ShareCacheStore.save(roomKey: roomKey, mode: mode.rawValue, record: ShareCacheRecord(
            mediaFiles: mediaFiles,
            info: info,
            shareURL: versionedURL.absoluteString,
            bucket: config.bucket,
            region: config.region,
            customDomain: config.customDomain,
            compressOnShare: compressOnShare,
            templateVersion: htmlTemplateVersion,
            qrcodeSet: hasQR,
            watermarkHash: Self.watermarkHash(WatermarkSettingsStore.current)
        ))

        // v1.36：分享记录云端化——异步写桶内分享记录索引（失败不阻塞分享主流程）
        Task {
            try? await Self.appendShareRecord(roomKey: roomKey, displayRoomNo: info.displayRoomNo, mode: mode, url: versionedURL.absoluteString, config: config)
        }

        return versionedURL
    }

    /// v1.22：多选分享 → 生成【合集 H5 卡片】。一次分享一个链接，好友点开看到 N 套房源列表，
    /// 点某套进入该套详情（视频置顶、图片单列、名片底部）。脱敏/完整两模式各自独立合集页面与缓存。
    /// 缓存：媒体+信息+配置全同 → 零上传复用上次链接；否则全量上传覆盖写（与单套共享媒体对象路径）。
    /// v1.13 需求13：progress 回调（0~1），按「所有套的需上传媒体数 + 固定任务」估算总进度
    static func shareCollection(rooms: [ShareCollectionItem], mode: ShareMode, config: CosConfig, progress: ((Double) -> Void)? = nil) async throws -> URL {
        guard !config.customDomain.isEmpty else { throw CosError.customDomainMissing }
        let validRooms = rooms.filter { !$0.mediaFiles.isEmpty }
        guard !validRooms.isEmpty else { throw CosError.missingMedia }
        let profile = loadShareProfile()
        let name = profile.name
        let phone = profile.phone

        // 0. 集合缓存键：模式 + 房号排序拼接（房号变化 → 键变化 → 自动新链接）
        // v1.23：压缩开关纳入缓存校验——开关变化 → 合集重新压缩上传
        // v1.25：①模板版本纳入校验——模板改动 → 旧合集缓存自动失效重新生成；
        //   ②合集房源比较改为【顺序无关】（Set）——多选点选顺序变化不再误判为变化导致重传
        // v1.27：二维码是否存在（qrcodeSet）纳入校验——设置/清除二维码后旧合集缓存自动失效
        let compressOnShare = shareCompressionEnabled
        let hasQR = QrcodeStore.exists()
        let sortedKeys = validRooms.map { $0.roomKey }.sorted().joined(separator: "_")
        let cacheKey = "collection_\(sortedKeys)"
        let cacheMode = "collection-\(mode.rawValue)"
        if let cached = ShareCacheStore.load(roomKey: cacheKey, mode: cacheMode),
           cached.bucket == config.bucket,
           cached.region == config.region,
           (cached.customDomain ?? "") == config.customDomain,
           (cached.compressOnShare ?? false) == compressOnShare,
           (cached.templateVersion ?? 0) == htmlTemplateVersion,
           (cached.qrcodeSet ?? false) == hasQR,
           (cached.watermarkHash ?? "") == Self.watermarkHash(WatermarkSettingsStore.current),
           cached.info.name == name,
           cached.info.phone == phone,
           Set(cached.collectionRooms ?? []) == Set(validRooms),
           let url = URL(string: cached.shareURL) {
            progress?(1.0)
            return url
        }

        // v1.13 需求13：进度按「所有套的需上传媒体数 + 每套封面 + 二维码 + 页面」估算总任务数
        let mediaTaskCount = validRooms.reduce(0) { $0 + $1.mediaFiles.count }
        let coverTaskCount = validRooms.filter { $0.mediaFiles.contains { $0.kind == "image" } }.count
        let totalTasks = max(1, mediaTaskCount + coverTaskCount + (hasQR ? 1 : 0) + 1)
        var completedTasks = 0
        func reportProgress(_ taskFraction: Double) {
            progress?(min(Double(completedTasks) + taskFraction, Double(totalTasks)) / Double(totalTasks))
        }

        // 1. 上传每套媒体（覆盖写，与单套分享共享 h/<roomKey>/<name> 路径）+ 每套封面
        // v1.40 第2点：上传前先探测桶内是否已有该媒体（HEAD），已有则跳过上传直接引用
        // v1.40 第6点：封面/视频首帧图/合集页/二维码全部改用户私有目录 users/<用户名>/
        var prepared: [PreparedRoom] = []
        for item in validRooms {
            let ordered = item.mediaFiles.sorted { lhs, rhs in
                let l = lhs.kind == "video" ? 0 : 1
                let r = rhs.kind == "video" ? 0 : 1
                return l < r
            }
            var videoTags: [String] = []
            var imageAbsURLs: [String] = []
            for m in ordered {
                let isVideo = m.kind == "video"
                let remoteName = isVideo ? cloudVideoName(for: m.name) : m.name
                let remotePath = "h/\(item.roomKey)/\(remoteName)"
                if await remoteObjectExists(path: remotePath, config: config) == false {
                    let url = MediaStore.url(for: m.name, roomKey: item.roomKey)
                    guard FileManager.default.fileExists(atPath: url.path) else { continue }
                    var data = try Data(contentsOf: url)
                    var contentType = mimeType(for: m.kind, name: remoteName)
                    if isVideo {
                        // v1.29：视频统一转 mp4 上传（安卓/微信可播）；压缩开 → 720p，关 → 原质量转封装
                        if let mp4 = await uploadVideoData(from: url, compress: compressOnShare) {
                            data = mp4
                            contentType = "video/mp4"
                        }
                    } else if compressOnShare, let compressed = compressedImageData(from: url) {
                        data = compressed
                        contentType = "image/jpeg"
                    }
                    do {
                        try await uploadWithProgress(data: data, to: remotePath, contentType: contentType, config: config) { p in
                            reportProgress(Double(p))
                        }
                    } catch {
                        // v1.40 第5点：上传失败入队，App 启动/回前台自动补传
                        HouseMediaUploadQueue.enqueue(roomKey: item.roomKey, fileName: m.name, kind: m.kind)
                        throw error
                    }
                }
                // v1.25/v1.40：视频首帧封面图——每个 H5 页面都重新生成上传（不检测），路径改用户私有目录
                if isVideo {
                    let thumbRemotePath = "\(CloudUser.sharePagePrefix)\(item.roomKey)/\(m.name).vthumb.jpg"
                    let localURL = MediaStore.url(for: m.name, roomKey: item.roomKey)
                    if FileManager.default.fileExists(atPath: localURL.path),
                       let thumbData = makeVideoThumbJPEG(from: localURL) {
                        try? await upload(data: thumbData, to: thumbRemotePath, contentType: "image/jpeg", config: config)
                    }
                }
                completedTasks += 1
                let absURL = try presignedGetURL(for: remotePath, expires: shareLinkExpires, config: config).absoluteString
                if isVideo {
                    // v1.25：video 无 src、无 poster、无 autoplay；封面用独立首帧图；点击封面 playVideo 才注入 src 并播放
                    let thumbRemotePath = "\(CloudUser.sharePagePrefix)\(item.roomKey)/\(m.name).vthumb.jpg"
                    let thumbURL = (try? presignedGetURL(for: thumbRemotePath, expires: shareLinkExpires, config: config).absoluteString) ?? absURL
                    videoTags.append("<div class=\"vwrap\" onclick=\"playVideo(this,'\(absURL)')\"><div class=\"vthumb\" style=\"background-image:url('\(thumbURL)')\"></div><div class=\"vplay\">▶</div><video class=\"v\" controls controlsList=\"nodownload\" disablepictureinpicture playsinline webkit-playsinline preload=\"none\"></video></div>")
                } else {
                    imageAbsURLs.append(absURL)
                }
            }
            var coverSrc = imageAbsURLs.first ?? ""
            if let firstImage = item.mediaFiles.first(where: { $0.kind == "image" }),
               let coverData = makeCoverJPEG(from: MediaStore.url(for: firstImage.name, roomKey: item.roomKey)) {
                let coverPath = "\(CloudUser.sharePagePrefix)\(item.roomKey)/cover"
                do {
                    try await uploadWithProgress(data: coverData, to: coverPath, contentType: "image/jpeg", config: config) { p in
                        reportProgress(Double(p))
                    }
                    coverSrc = try presignedGetURL(for: coverPath, expires: shareLinkExpires, config: config).absoluteString
                } catch {
                }
                completedTasks += 1
            }
            prepared.append(PreparedRoom(item: item, videoTags: videoTags, imageURLs: imageAbsURLs, coverSrc: coverSrc))
        }
        guard !prepared.isEmpty else { throw CosError.missingMedia }

        // 2. 生成并上传合集页。v1.36：文件名=首套房号+模式+日期时间（空 app 无存量链接，直接换新命名）
        // v1.40 第6点：合集页改存用户私有目录 users/<用户名>/shares/_collection/
        let collectionCover = prepared.first?.coverSrc ?? ""
        // v1.27/v1.40：名片微信二维码——用户私有目录覆盖写，旧合集链接自动显示新二维码
        var qrSrc = ""
        if hasQR, let qrData = makeQRCodeJPEG() {
            try? await uploadWithProgress(data: qrData, to: CloudUser.qrPath, contentType: "image/jpeg", config: config) { p in
                reportProgress(Double(p))
            }
            qrSrc = (try? presignedGetURL(for: CloudUser.qrPath, expires: shareLinkExpires, config: config).absoluteString) ?? ""
            completedTasks += 1
        }
        let wm = Self.watermarkOverlayHTML(WatermarkSettingsStore.current)
        let firstRoomLabel = prepared.first?.item.displayRoomNo ?? "合集"
        let pagePath = "\(CloudUser.sharePagePrefix)_collection/\(Self.safeFileName(firstRoomLabel))_\(mode.modeLabel)_\(Self.shareTimeTag()).html"
        let html = buildCollectionHTML(rooms: prepared, mode: mode, name: name, phone: phone, coverSrc: collectionCover, qrSrc: qrSrc,
                                       wm: wm, trackScript: Self.cloudTrackScript(room: firstRoomLabel, mode: mode.modeLabel))
        try await uploadWithProgress(data: Data(html.utf8), to: pagePath, contentType: "text/html; charset=utf-8", config: config) { p in
            reportProgress(Double(p))
        }
        completedTasks += 1
        progress?(1.0)

        let shareURL = try presignedGetURL(for: pagePath, expires: shareLinkExpires, config: config)
        let versionedURL = appendVersionParameter(shareURL, version: "\(Int(Date().timeIntervalSince1970))")

        // 3. 更新集合缓存
        ShareCacheStore.save(roomKey: cacheKey, mode: cacheMode, record: ShareCacheRecord(
            mediaFiles: validRooms.flatMap { $0.mediaFiles },
            info: ShareHouseInfo(
                displayRoomNo: "", towerLabel: "", layout: "", statusLabel: "",
                priceText: "", landlord: "", password: "", remark: "",
                name: name, phone: phone
            ),
            shareURL: versionedURL.absoluteString,
            bucket: config.bucket,
            region: config.region,
            customDomain: config.customDomain,
            compressOnShare: compressOnShare,
            collectionRooms: validRooms,
            templateVersion: htmlTemplateVersion,
            qrcodeSet: hasQR,
            watermarkHash: Self.watermarkHash(WatermarkSettingsStore.current)
        ))

        // v1.36：分享记录云端化——异步写桶内分享记录索引（失败不阻塞分享主流程）
        Task {
            try? await Self.appendShareRecord(roomKey: firstRoomLabel, displayRoomNo: firstRoomLabel, mode: mode, url: versionedURL.absoluteString, config: config)
        }

        return versionedURL
    }

    /// v1.20：连接自检（设置页「保存并验证」调用）。
    /// ①用当前配置上传一个测试文件到桶 → 验证桶名/地域/密钥/签名；
    /// ②再用访问域名（自定义域名或默认域名）读取该文件 → 验证域名解析 + HTTPS 证书 + 私有桶签名访问。
    /// 全部通过返回实际使用的访问域名；任一环节失败抛出带具体错误码的详细信息。
    static func verifyConnection(config: CosConfig) async throws -> String {
        let testPath = "h/_verify/connect.txt"
        let testData = Data("connect-ok-\(Int(Date().timeIntervalSince1970))".utf8)

        // 1. 上传测试对象：失败 = 桶名/地域/密钥/签名有误（错误信息里带 COS 错误码）
        try await upload(data: testData, to: testPath, contentType: "text/plain", config: config)

        // 2. 用访问域名读取测试对象：失败 = 自定义域名未绑定/未生效/证书异常（HTTP 错误或证书错误）
        let getURL = try presignedGetURL(for: testPath, expires: 120, config: config)
        var request = URLRequest(url: getURL)
        request.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CosError.uploadFailed("网络响应无效")
        }
        guard (200...299).contains(http.statusCode), String(data: data, encoding: .utf8)?.hasPrefix("connect-ok") == true else {
            let detail = extractCosError(from: data)
            throw CosError.uploadFailed("读取测试文件失败 HTTP \(http.statusCode)（" + (detail.isEmpty ? "请确认自定义域名已在存储桶「域名与传输管理」绑定并生效（状态为上线/已解析）" : detail) + "）")
        }
        return host(for: config)
    }

    /// 读设置页保存的分享名片信息（姓名/电话）；未设置时用默认值
    /// 默认：梁涛 / 13288251132（名片、微信卡片描述、拨打电话、复制按钮四处统一）
    static func loadShareProfile() -> (name: String, phone: String) {
        let trimSet = CharacterSet.whitespacesAndNewlines
        let name = (KeychainStore.load(KeychainKey.shareName) ?? "").trimmingCharacters(in: trimSet)
        let phone = (KeychainStore.load(KeychainKey.sharePhone) ?? "").trimmingCharacters(in: trimSet)
        return (name.isEmpty ? "梁涛" : name, phone.isEmpty ? "13288251132" : phone)
    }

    // MARK: - HTML 模板（v1.21 设计稿定稿：脱敏版）

    /// v1.28：二维码列（二维码 + 下方小字「长按二维码加我好友」），无二维码时返回空串（该行不显示）
    private static func qrColumnHTML(qrSrc: String) -> String {
        guard !qrSrc.isEmpty else { return "" }
        return "<div class=\"qr-col\"><img class=\"qr\" src=\"\(qrSrc)\" alt=\"微信二维码\"><div class=\"qr-tip\">长按二维码加我好友</div></div>"
    }

    /// 脱敏版（隐藏版）：户型大字 → 位置+导航 → 实拍（视频置顶、图片单列）→ 名片 → 底栏
    /// 无房号/价格/房东/密码/备注；图片用 CSS 背景图渲染（微信长按背景图无「保存图片」），全局禁右键/禁长按选择
    /// v1.27：名片板块换浅蓝底色；微信二维码（真实 <img>，可长按被微信识别）放左侧，原居中信息右移
    private static func buildMaskedHTML(title: String, desc: String, name: String, phone: String, videoTags: [String], imageURLs: [String], coverSrc: String, qrSrc: String, shareLink: String, wm: String = "", trackScript: String = "") -> String {
        let mediaBlock = mediaBlockHTML(videoTags: videoTags, imageURLs: imageURLs, wm: wm)
        let coverMeta = coverSrc.isEmpty ? "" : "<meta property=\"og:image\" content=\"\(coverSrc)\">"
        let urlMeta = shareLink.isEmpty ? "" : "<meta property=\"og:url\" content=\"\(shareLink)\">"
        let galleryJS = imageURLs.map { "'\($0)'" }.joined(separator: ",")
        let qrCol = qrColumnHTML(qrSrc: qrSrc)
        let qrWrapClass = qrSrc.isEmpty ? " qr-wrap center" : " qr-wrap"
        return """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta property="og:title" content="\(escapeHTML(title))">
        <meta property="og:description" content="\(escapeHTML(desc))">
        \(coverMeta)
        \(urlMeta)
        <title>\(escapeHTML(title))</title>
        <style>
        body{font-family:-apple-system,BlinkMacSystemFont,"PingFang SC","Helvetica Neue",sans-serif;margin:0;background:#f4f5f7;color:#1c1c1e;-webkit-touch-callout:none;-webkit-user-select:none;user-select:none;-webkit-tap-highlight-color:transparent;}
        .wrap{max-width:640px;margin:0 auto;padding:0 16px 16px;}
        .hero{background:linear-gradient(135deg,#1f3a5f,#2d5f8a);color:#fff;border-radius:16px;padding:20px 20px 16px;}
        .type{font-size:30px;font-weight:700;margin:0 0 14px;}
        .loc{display:flex;align-items:center;gap:8px;color:rgba(255,255,255,.92);text-decoration:none;}
        .loc-name{font-size:15px;}
        .nav-pill{display:inline-flex;align-items:center;gap:4px;background:rgba(255,255,255,.18);border-radius:999px;padding:6px 12px;font-size:13px;margin-left:auto;}
        .sec{font-size:15px;color:#3a3a3c;margin:18px 4px 10px;font-weight:600;}
        .media{background:#fff;border-radius:16px;padding:12px;}
        .vwrap{position:relative;width:100%;aspect-ratio:4/3;border-radius:10px;overflow:hidden;margin-bottom:10px;background:#000;cursor:pointer;}
        .vthumb{position:absolute;inset:0;background-size:cover;background-position:center;}
        .vplay{position:absolute;left:50%;top:50%;transform:translate(-50%,-50%);width:64px;height:64px;border-radius:50%;background:rgba(0,0,0,.55);display:flex;align-items:center;justify-content:center;color:#fff;font-size:28px;border:2px solid rgba(255,255,255,.85);}
        .vwrap video{width:100%;height:100%;display:none;background:#000;}
        .vwrap.playing .vthumb,.vwrap.playing .vplay{display:none;}
        .vwrap.playing video{display:block;}
        .cellwrap{width:100%;aspect-ratio:4/3;border-radius:10px;overflow:hidden;background-color:#e8e8ec;margin-bottom:10px;cursor:pointer;position:relative;}
        .cell{width:100%;height:100%;object-fit:cover;display:block;pointer-events:none;-webkit-user-drag:none;-webkit-touch-callout:none;}
        .card{background:linear-gradient(180deg,#f7fafd,#e9f1f9);border:1px solid #dfe9f3;border-radius:16px;padding:14px;margin-top:12px;}
        .qr-wrap{display:flex;align-items:center;gap:14px;}
        .qr-wrap.center{justify-content:center;}
        .qr-col{display:flex;flex-direction:column;align-items:center;gap:3px;flex-shrink:0;}
        .qr-tip{font-size:10px;color:#8e8e93;text-align:center;max-width:108px;white-space:nowrap;line-height:1.3;}
        .qr{width:108px;height:108px;border-radius:10px;object-fit:cover;flex-shrink:0;background:#fff;border:1px solid #e3e3e8;-webkit-touch-callout:default;-webkit-user-select:text;user-select:text;-webkit-user-drag:auto;}
        .card-info{flex:1;min-width:0;text-align:center;}
        .tag{color:#8e8e93;font-size:12px;margin-bottom:10px;}
        .row{display:flex;align-items:center;justify-content:center;gap:8px;}
        .name{font-size:17px;font-weight:600;}
        .num{font-size:16px;font-weight:600;color:#b8860b;}
        .note{color:#8e8e93;font-size:12px;margin:10px 0 14px;}
        .btns{display:flex;gap:10px;justify-content:center;}
        .btn{flex:1;max-width:220px;padding:12px 0;border-radius:999px;font-size:15px;font-weight:600;text-align:center;text-decoration:none;}
        .btn.call{background:#1f3a5f;color:#fff;}
        .btn.copy{background:#f0f0f2;color:#1c1c1e;border:none;}
        .foot{text-align:center;color:#8e8e93;font-size:12px;padding:18px 0 26px;}
        #toast{position:fixed;left:50%;bottom:80px;transform:translateX(-50%);background:rgba(0,0,0,.8);color:#fff;padding:10px 18px;border-radius:8px;font-size:14px;z-index:999;display:none;}
        #lb{position:fixed;inset:0;background:rgba(0,0,0,.95);z-index:999;display:none;}
        #lbImg{position:absolute;inset:0;background-size:contain;background-position:center;background-repeat:no-repeat;}
        #lbPrev{position:absolute;left:6px;top:50%;transform:translateY(-50%);color:#fff;font-size:44px;padding:10px 16px;cursor:pointer;user-select:none;}
        #lbNext{position:absolute;right:6px;top:50%;transform:translateY(-50%);color:#fff;font-size:44px;padding:10px 16px;cursor:pointer;user-select:none;}
        #lbClose{position:absolute;top:12px;right:12px;color:#fff;font-size:26px;padding:10px;cursor:pointer;user-select:none;}
        #lbCnt{position:absolute;bottom:22px;left:0;right:0;text-align:center;color:rgba(255,255,255,.85);font-size:14px;user-select:none;}
        </style>
        </head>
        <body oncontextmenu="return false">
        <div class="wrap">
        <section class="hero">
          <h1 class="type">\(escapeHTML(title))</h1>
          <a class="loc" href="https://uri.amap.com/search?keyword=%E5%88%A9%E4%BF%9D%E7%B1%B3%E5%85%B0%E5%85%AC%E5%AF%93" target="_blank" rel="noopener">
            <span class="loc-name">利保米兰公馆</span>
            <span class="nav-pill"><svg width="12" height="12" viewBox="0 0 24 24" fill="currentColor"><path d="M12 2a7 7 0 0 0-4 12.7V17a1 1 0 0 0 2 0v-1h4v1a1 1 0 0 0 2 0v-2.3A7 7 0 0 0 12 2zm0 2a5 5 0 1 1 0 10 5 5 0 0 1 0-10zm0 3a2 2 0 1 0 0 4 2 2 0 0 0 0-4z"/></svg>导航</span>
          </a>
        </section>
        <h2 class="sec">实拍 · 点击放大</h2>
        \(mediaBlock)
        <section class="card">
          <div class="\(qrWrapClass)">
            \(qrCol)
            <div class="card-info">
              <div class="tag">米兰租赁管家 · 专业省心租好房</div>
              <div class="row"><span class="name">\(escapeHTML(name))</span><span class="num">\(escapeHTML(phone))</span></div>
              <div class="note">微信同号 · 24小时可约看房</div>
              <div class="btns">
                <a class="btn call" href="tel:\(escapeHTML(phone))">拨打电话</a>
                <button class="btn copy" type="button" onclick="copyPhone()">复制电话</button>
              </div>
            </div>
          </div>
        </section>
        <div class="foot">更多优质房源请与我联系-\(escapeHTML(phone))</div>
        </div>
        <div id="toast"></div>
        <div id="lb"><div id="lbImg"></div><div id="lbPrev" onclick="lbPrev()">‹</div><div id="lbNext" onclick="lbNext()">›</div><div id="lbClose" onclick="lbClose()">✕</div><div id="lbCnt"></div></div>
        <script>
        var GALLERY=[\(galleryJS)];var gi=0;
        function playVideo(w,src){var v=w.querySelector('video');if(!v.src){v.src=src;}var p=v.play();if(p&&p.catch){p.catch(function(){});}w.className=w.className+' playing';}
        function openImg(i){gi=i;show();}
        function show(){var d=document.getElementById('lb');document.getElementById('lbImg').style.backgroundImage="url('"+GALLERY[gi]+"')";document.getElementById('lbCnt').textContent=(gi+1)+' / '+GALLERY.length;d.style.display='block';}
        function lbPrev(){gi=(gi-1+GALLERY.length)%GALLERY.length;show();}
        function lbNext(){gi=(gi+1)%GALLERY.length;show();}
        function lbClose(){document.getElementById('lb').style.display='none';}
        var _sx=0;(function(){var d=document.getElementById('lb');d.addEventListener('touchstart',function(e){_sx=e.touches[0].clientX},{passive:true});d.addEventListener('touchend',function(e){var dx=e.changedTouches[0].clientX-_sx;if(Math.abs(dx)>50){dx<0?lbNext():lbPrev();}},{passive:true});})();
        function toast(msg){var t=document.getElementById('toast');t.textContent=msg;t.style.display='block';clearTimeout(t._h);t._h=setTimeout(function(){t.style.display='none'},1600);}
        function copyPhone(){var p='\(phone)';function done(){toast('已复制 '+p)}function fb(){var i=document.createElement('input');i.value=p;document.body.appendChild(i);i.select();i.setSelectionRange(0,999);document.execCommand('copy');i.remove();done()}if(navigator.clipboard&&window.isSecureContext){navigator.clipboard.writeText(p).then(done,fb)}else{fb()}}
        </script>
        \(trackScript)
        </body>
        </html>
        """
    }

    // MARK: - HTML 模板（v1.21 设计稿定稿：完整版）

    /// 完整版（不隐藏版）：v1.22 信息板块重排为三行——第一行：房号(左) + 户型(右)；第二行：租金 + 密码（密码：xxx）+ 房东（最右）；
    /// 第三行：备注（有才显示，空则整行隐藏）。实拍 → 名片 → 底栏
    private static func buildFullHTML(title: String, desc: String, info: ShareHouseInfo, name: String, phone: String, videoTags: [String], imageURLs: [String], coverSrc: String, qrSrc: String, shareLink: String, wm: String = "", trackScript: String = "") -> String {
        let mediaBlock = mediaBlockHTML(videoTags: videoTags, imageURLs: imageURLs, wm: wm)
        let coverMeta = coverSrc.isEmpty ? "" : "<meta property=\"og:image\" content=\"\(coverSrc)\">"
        let urlMeta = shareLink.isEmpty ? "" : "<meta property=\"og:url\" content=\"\(shareLink)\">"
        let galleryJS = imageURLs.map { "'\($0)'" }.joined(separator: ",")
        let qrCol = qrColumnHTML(qrSrc: qrSrc)
        let qrWrapClass = qrSrc.isEmpty ? " qr-wrap center" : " qr-wrap"

        let host = info.landlord.isEmpty ? "" : "<span class=\"host\">\(escapeHTML(info.landlord))</span>"
        let pw = info.password.isEmpty ? "" : "<span class=\"pw\">密码：\(escapeHTML(info.password))</span>"
        let remarkLine = info.remark.isEmpty ? "" : "<div class=\"remark\">\(escapeHTML(info.remark))</div>"
        let layoutText = info.layout.isEmpty ? "房源" : escapeHTML(info.layout)
        return """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta property="og:title" content="\(escapeHTML(title))">
        <meta property="og:description" content="\(escapeHTML(desc))">
        \(coverMeta)
        \(urlMeta)
        <title>\(escapeHTML(title))</title>
        <style>
        body{font-family:-apple-system,BlinkMacSystemFont,"PingFang SC","Helvetica Neue",sans-serif;margin:0;background:#f4f5f7;color:#1c1c1e;-webkit-touch-callout:none;-webkit-user-select:none;user-select:none;-webkit-tap-highlight-color:transparent;}
        .wrap{max-width:640px;margin:0 auto;padding:0 16px 16px;}
        .hero{background:linear-gradient(135deg,#1f3a5f,#2d5f8a);color:#fff;border-radius:16px;padding:20px 20px 16px;}
        .l1{display:flex;justify-content:space-between;align-items:baseline;}
        .room{font-size:30px;font-weight:700;}
        .price{font-size:30px;font-weight:700;color:#f5c46b;}
        .l2{display:flex;align-items:baseline;gap:14px;margin-top:12px;}
        .pw{font-size:18px;color:rgba(255,255,255,.9);}
        .layout2{font-size:18px;color:rgba(255,255,255,.9);}
        .host{margin-left:auto;font-size:18px;color:rgba(255,255,255,.9);}
        .remark{margin-top:10px;font-size:13px;color:rgba(255,255,255,.7);}
        .sec{font-size:15px;color:#3a3a3c;margin:18px 4px 10px;font-weight:600;}
        .media{background:#fff;border-radius:16px;padding:12px;}
        .vwrap{position:relative;width:100%;aspect-ratio:4/3;border-radius:10px;overflow:hidden;margin-bottom:10px;background:#000;cursor:pointer;}
        .vthumb{position:absolute;inset:0;background-size:cover;background-position:center;}
        .vplay{position:absolute;left:50%;top:50%;transform:translate(-50%,-50%);width:64px;height:64px;border-radius:50%;background:rgba(0,0,0,.55);display:flex;align-items:center;justify-content:center;color:#fff;font-size:28px;border:2px solid rgba(255,255,255,.85);}
        .vwrap video{width:100%;height:100%;display:none;background:#000;}
        .vwrap.playing .vthumb,.vwrap.playing .vplay{display:none;}
        .vwrap.playing video{display:block;}
        .cellwrap{width:100%;aspect-ratio:4/3;border-radius:10px;overflow:hidden;background-color:#e8e8ec;margin-bottom:10px;cursor:pointer;position:relative;}
        .cell{width:100%;height:100%;object-fit:cover;display:block;pointer-events:none;-webkit-user-drag:none;-webkit-touch-callout:none;}
        .card{background:linear-gradient(180deg,#f7fafd,#e9f1f9);border:1px solid #dfe9f3;border-radius:16px;padding:14px;margin-top:12px;}
        .qr-wrap{display:flex;align-items:center;gap:14px;}
        .qr-wrap.center{justify-content:center;}
        .qr-col{display:flex;flex-direction:column;align-items:center;gap:3px;flex-shrink:0;}
        .qr-tip{font-size:10px;color:#8e8e93;text-align:center;max-width:108px;white-space:nowrap;line-height:1.3;}
        .qr{width:108px;height:108px;border-radius:10px;object-fit:cover;flex-shrink:0;background:#fff;border:1px solid #e3e3e8;-webkit-touch-callout:default;-webkit-user-select:text;user-select:text;-webkit-user-drag:auto;}
        .card-info{flex:1;min-width:0;text-align:center;}
        .tag{color:#8e8e93;font-size:12px;margin-bottom:10px;}
        .row{display:flex;align-items:center;justify-content:center;gap:8px;}
        .name{font-size:17px;font-weight:600;}
        .num{font-size:16px;font-weight:600;color:#b8860b;}
        .note{color:#8e8e93;font-size:12px;margin:10px 0 14px;}
        .btns{display:flex;gap:10px;justify-content:center;}
        .btn{flex:1;max-width:220px;padding:12px 0;border-radius:999px;font-size:15px;font-weight:600;text-align:center;text-decoration:none;}
        .btn.call{background:#1f3a5f;color:#fff;}
        .btn.copy{background:#f0f0f2;color:#1c1c1e;border:none;}
        .foot{text-align:center;color:#8e8e93;font-size:12px;padding:18px 0 26px;}
        #toast{position:fixed;left:50%;bottom:80px;transform:translateX(-50%);background:rgba(0,0,0,.8);color:#fff;padding:10px 18px;border-radius:8px;font-size:14px;z-index:999;display:none;}
        #lb{position:fixed;inset:0;background:rgba(0,0,0,.95);z-index:999;display:none;}
        #lbImg{position:absolute;inset:0;background-size:contain;background-position:center;background-repeat:no-repeat;}
        #lbPrev{position:absolute;left:6px;top:50%;transform:translateY(-50%);color:#fff;font-size:44px;padding:10px 16px;cursor:pointer;user-select:none;}
        #lbNext{position:absolute;right:6px;top:50%;transform:translateY(-50%);color:#fff;font-size:44px;padding:10px 16px;cursor:pointer;user-select:none;}
        #lbClose{position:absolute;top:12px;right:12px;color:#fff;font-size:26px;padding:10px;cursor:pointer;user-select:none;}
        #lbCnt{position:absolute;bottom:22px;left:0;right:0;text-align:center;color:rgba(255,255,255,.85);font-size:14px;user-select:none;}
        </style>
        </head>
        <body oncontextmenu="return false">
        <div class="wrap">
        <section class="hero">
          <div class="l1"><span class="room">\(escapeHTML(info.displayRoomNo))</span><span class="price">\(escapeHTML(info.priceText))</span></div>
          <div class="l2">\(pw)<span class="layout2">\(layoutText)</span>\(host)</div>
          \(remarkLine)
        </section>
        <h2 class="sec">实拍 · 点击放大</h2>
        \(mediaBlock)
        <section class="card">
          <div class="\(qrWrapClass)">
            \(qrCol)
            <div class="card-info">
              <div class="tag">米兰租赁管家 · 专业省心租好房</div>
              <div class="row"><span class="name">\(escapeHTML(name))</span><span class="num">\(escapeHTML(phone))</span></div>
              <div class="note">微信同号 · 24小时可约看房</div>
              <div class="btns">
                <a class="btn call" href="tel:\(escapeHTML(phone))">拨打电话</a>
                <button class="btn copy" type="button" onclick="copyPhone()">复制电话</button>
              </div>
            </div>
          </div>
        </section>
        <div class="foot">更多优质房源请与我联系-\(escapeHTML(phone))</div>
        </div>
        <div id="toast"></div>
        <div id="lb"><div id="lbImg"></div><div id="lbPrev" onclick="lbPrev()">‹</div><div id="lbNext" onclick="lbNext()">›</div><div id="lbClose" onclick="lbClose()">✕</div><div id="lbCnt"></div></div>
        <script>
        var GALLERY=[\(galleryJS)];var gi=0;
        function playVideo(w,src){var v=w.querySelector('video');if(!v.src){v.src=src;}var p=v.play();if(p&&p.catch){p.catch(function(){});}w.className=w.className+' playing';}
        function openImg(i){gi=i;show();}
        function show(){var d=document.getElementById('lb');document.getElementById('lbImg').style.backgroundImage="url('"+GALLERY[gi]+"')";document.getElementById('lbCnt').textContent=(gi+1)+' / '+GALLERY.length;d.style.display='block';}
        function lbPrev(){gi=(gi-1+GALLERY.length)%GALLERY.length;show();}
        function lbNext(){gi=(gi+1)%GALLERY.length;show();}
        function lbClose(){document.getElementById('lb').style.display='none';}
        var _sx=0;(function(){var d=document.getElementById('lb');d.addEventListener('touchstart',function(e){_sx=e.touches[0].clientX},{passive:true});d.addEventListener('touchend',function(e){var dx=e.changedTouches[0].clientX-_sx;if(Math.abs(dx)>50){dx<0?lbNext():lbPrev();}},{passive:true});})();
        function toast(msg){var t=document.getElementById('toast');t.textContent=msg;t.style.display='block';clearTimeout(t._h);t._h=setTimeout(function(){t.style.display='none'},1600);}
        function copyPhone(){var p='\(phone)';function done(){toast('已复制 '+p)}function fb(){var i=document.createElement('input');i.value=p;document.body.appendChild(i);i.select();i.setSelectionRange(0,999);document.execCommand('copy');i.remove();done()}if(navigator.clipboard&&window.isSecureContext){navigator.clipboard.writeText(p).then(done,fb)}else{fb()}}
        </script>
        \(trackScript)
        </body>
        </html>
        """
    }

    // MARK: - v1.22 合集 H5（多选分享：一次链接，N 套房源列表 + 各自详情）

    /// 合集页：列表（封面+房号+租金+户型）→ 点某套进入详情（视频置顶、图片单列、名片在详情底部）；
    /// 脱敏/完整按模式渲染详情信息区。所有图片进入统一 GALLERY 支持左右滑动查看。
    private struct PreparedRoom {
        let item: ShareCollectionItem
        let videoTags: [String]
        let imageURLs: [String]
        let coverSrc: String
    }

    private static func buildCollectionHTML(rooms: [PreparedRoom], mode: ShareMode, name: String, phone: String, coverSrc: String, qrSrc: String, wm: String = "", trackScript: String = "") -> String {
        let count = rooms.count
        let qrCol = qrColumnHTML(qrSrc: qrSrc)
        let qrWrapClass = qrSrc.isEmpty ? " qr-wrap center" : " qr-wrap"
        // og
        let title: String
        let desc: String
        switch mode {
        case .masked:
            title = "已为你挑选\(count)套优质房源"
            desc = "利保米兰公馆\n\(name)-\(phone)"
        case .full:
            let minPrice = rooms.map { $0.item.priceText }.min() ?? ""
            title = "已为你挑选\(count)套优质房源"
            desc = (minPrice.isEmpty ? "精选\(count)套房源" : "精选\(count)套房源 · 起租\(minPrice)") + "\n\(name)-\(phone)"
        }
        let coverMeta = coverSrc.isEmpty ? "" : "<meta property=\"og:image\" content=\"\(coverSrc)\">"

        // 列表项：v1.23 脱敏版只显示户型（隐藏房号/价格），完整版显示房号 + 价格·户型
        var listItems: [String] = []
        var detailsJS: [String] = []
        var gallery: [String] = []
        var cursor = 0
        for (index, room) in rooms.enumerated() {
            // v1.25：缩略图改用 <img> 标签渲染（微信 WebView 对背景图/动态注入元素的 background-image 加载不可靠，
            // <img> 是原生图片加载最稳的方式）；draggable=false + touch-callout:none 防长按保存
            let cover = room.coverSrc.isEmpty ? "" : " src=\"\(room.coverSrc)\""
            let metaHTML: String
            if mode == .masked {
                metaHTML = """
                <div class="meta">
                  <div class="rno">\(escapeHTML(room.item.layout.isEmpty ? "房源" : room.item.layout))</div>
                  <div class="sub2">利保米兰公馆</div>
                </div>
                """
            } else {
                metaHTML = """
                <div class="meta">
                  <div class="rno">\(escapeHTML(room.item.displayRoomNo))</div>
                  <div class="sub2">\(escapeHTML(room.item.priceText)) · \(escapeHTML(room.item.layout.isEmpty ? "房源" : room.item.layout))</div>
                </div>
                """
            }
            listItems.append("""
            <div class="item" onclick="showDetail(\(index))">
              <img class="thumb"\(cover) draggable="false" alt="">
              \(metaHTML)
            </div>
            """)

            let detail = collectionDetailHTML(item: room.item, mode: mode, videoTags: room.videoTags, imageURLs: room.imageURLs, startIndex: cursor, name: name, phone: phone, qrSrc: qrSrc, wm: wm)
            cursor += room.imageURLs.count
            gallery.append(contentsOf: room.imageURLs)
            // JS 单引号字符串转义：反斜杠 → \\ 、单引号 → \' 、换行 → \n（JS 字符串字面量不允许未转义换行）
            let escaped = detail
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: "\\n")
            detailsJS.append("'" + escaped + "'")
        }
        let galleryJS = gallery.map { "'\($0)'" }.joined(separator: ",")
        let itemsHTML = listItems.joined(separator: "\n")
        let roomsJS = detailsJS.joined(separator: ",")

        return """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta property="og:title" content="\(escapeHTML(title))">
        <meta property="og:description" content="\(escapeHTML(desc))">
        \(coverMeta)
        <title>\(escapeHTML(title))</title>
        <style>
        body{font-family:-apple-system,BlinkMacSystemFont,"PingFang SC","Helvetica Neue",sans-serif;margin:0;background:#f4f5f7;color:#1c1c1e;-webkit-touch-callout:none;-webkit-user-select:none;user-select:none;-webkit-tap-highlight-color:transparent;}
        .wrap{max-width:640px;margin:0 auto;padding:0 16px 16px;}
        .hero2{background:linear-gradient(135deg,#1f3a5f,#2d5f8a);color:#fff;border-radius:16px;padding:20px;margin-top:14px;}
        .coll-title{font-size:26px;font-weight:700;margin:0 0 8px;}
        .coll-sub{font-size:14px;color:rgba(255,255,255,.85);}
        .items{margin-top:12px;}
        .item{display:flex;gap:12px;background:#fff;border-radius:14px;padding:12px;margin-bottom:10px;align-items:center;}
        .thumb{width:96px;height:72px;border-radius:10px;object-fit:cover;display:block;background-color:#e8e8ec;flex-shrink:0;pointer-events:none;-webkit-user-drag:none;-webkit-touch-callout:none;}
        .meta{flex:1;min-width:0;}
        .rno{font-size:17px;font-weight:700;color:#1c1c1e;}
        .sub2{font-size:13px;color:#8e8e93;margin-top:4px;}
        .back{display:block;width:100%;padding:12px 0;border-radius:999px;font-size:15px;font-weight:600;text-align:center;background:#fff;color:#1f3a5f;border:1px solid #dfe1e6;margin:14px 0 4px;text-decoration:none;}
        .dhero{background:linear-gradient(135deg,#1f3a5f,#2d5f8a);color:#fff;border-radius:16px;padding:20px 20px 16px;margin-top:14px;}
        .type{font-size:30px;font-weight:700;margin:0 0 14px;}
        .loc{display:flex;align-items:center;gap:8px;color:rgba(255,255,255,.92);text-decoration:none;}
        .loc-name{font-size:15px;}
        .nav-pill{display:inline-flex;align-items:center;gap:4px;background:rgba(255,255,255,.18);border-radius:999px;padding:6px 12px;font-size:13px;margin-left:auto;}
        .l1{display:flex;justify-content:space-between;align-items:baseline;}
        .room{font-size:30px;font-weight:700;}
        .price{font-size:30px;font-weight:700;color:#f5c46b;}
        .l2{display:flex;align-items:baseline;gap:14px;margin-top:12px;}
        .pw{font-size:18px;color:rgba(255,255,255,.9);}
        .layout2{font-size:18px;color:rgba(255,255,255,.9);}
        .host{margin-left:auto;font-size:18px;color:rgba(255,255,255,.9);}
        .remark{margin-top:10px;font-size:13px;color:rgba(255,255,255,.7);}
        .sec{font-size:15px;color:#3a3a3c;margin:18px 4px 10px;font-weight:600;}
        .media{background:#fff;border-radius:16px;padding:12px;}
        .vwrap{position:relative;width:100%;aspect-ratio:4/3;border-radius:10px;overflow:hidden;margin-bottom:10px;background:#000;cursor:pointer;}
        .vthumb{position:absolute;inset:0;background-size:cover;background-position:center;}
        .vplay{position:absolute;left:50%;top:50%;transform:translate(-50%,-50%);width:64px;height:64px;border-radius:50%;background:rgba(0,0,0,.55);display:flex;align-items:center;justify-content:center;color:#fff;font-size:28px;border:2px solid rgba(255,255,255,.85);}
        .vwrap video{width:100%;height:100%;display:none;background:#000;}
        .vwrap.playing .vthumb,.vwrap.playing .vplay{display:none;}
        .vwrap.playing video{display:block;}
        .cellwrap{width:100%;aspect-ratio:4/3;border-radius:10px;overflow:hidden;background-color:#e8e8ec;margin-bottom:10px;cursor:pointer;position:relative;}
        .cell{width:100%;height:100%;object-fit:cover;display:block;pointer-events:none;-webkit-user-drag:none;-webkit-touch-callout:none;}
        .card{background:linear-gradient(180deg,#f7fafd,#e9f1f9);border:1px solid #dfe9f3;border-radius:16px;padding:14px;margin-top:12px;}
        .qr-wrap{display:flex;align-items:center;gap:14px;}
        .qr-wrap.center{justify-content:center;}
        .qr-col{display:flex;flex-direction:column;align-items:center;gap:3px;flex-shrink:0;}
        .qr-tip{font-size:10px;color:#8e8e93;text-align:center;max-width:108px;white-space:nowrap;line-height:1.3;}
        .qr{width:108px;height:108px;border-radius:10px;object-fit:cover;flex-shrink:0;background:#fff;border:1px solid #e3e3e8;-webkit-touch-callout:default;-webkit-user-select:text;user-select:text;-webkit-user-drag:auto;}
        .card-info{flex:1;min-width:0;text-align:center;}
        .tag{color:#8e8e93;font-size:12px;margin-bottom:10px;}
        .row{display:flex;align-items:center;justify-content:center;gap:8px;}
        .name{font-size:17px;font-weight:600;}
        .num{font-size:16px;font-weight:600;color:#b8860b;}
        .note{color:#8e8e93;font-size:12px;margin:10px 0 14px;}
        .btns{display:flex;gap:10px;justify-content:center;}
        .btn{flex:1;max-width:220px;padding:12px 0;border-radius:999px;font-size:15px;font-weight:600;text-align:center;text-decoration:none;}
        .btn.call{background:#1f3a5f;color:#fff;}
        .btn.copy{background:#f0f0f2;color:#1c1c1e;border:none;}
        .foot{text-align:center;color:#8e8e93;font-size:12px;padding:18px 0 26px;}
        #toast{position:fixed;left:50%;bottom:80px;transform:translateX(-50%);background:rgba(0,0,0,.8);color:#fff;padding:10px 18px;border-radius:8px;font-size:14px;z-index:999;display:none;}
        #lb{position:fixed;inset:0;background:rgba(0,0,0,.95);z-index:999;display:none;}
        #lbImg{position:absolute;inset:0;background-size:contain;background-position:center;background-repeat:no-repeat;}
        #lbPrev{position:absolute;left:6px;top:50%;transform:translateY(-50%);color:#fff;font-size:44px;padding:10px 16px;cursor:pointer;user-select:none;}
        #lbNext{position:absolute;right:6px;top:50%;transform:translateY(-50%);color:#fff;font-size:44px;padding:10px 16px;cursor:pointer;user-select:none;}
        #lbClose{position:absolute;top:12px;right:12px;color:#fff;font-size:26px;padding:10px;cursor:pointer;user-select:none;}
        #lbCnt{position:absolute;bottom:22px;left:0;right:0;text-align:center;color:rgba(255,255,255,.85);font-size:14px;user-select:none;}
        </style>
        </head>
        <body oncontextmenu="return false">
        <div class="wrap">
        <div id="listView">
          <div class="hero2">
            <h1 class="coll-title">\(escapeHTML(title))</h1>
            <div class="coll-sub">点击房源卡片查看详情</div>
          </div>
          <div class="items">
        \(itemsHTML)
          </div>
          <!-- v1.26：合集列表页底部也加名片（拨打电话/复制电话），与单套分享页一致 -->
          <!-- v1.27：名片板块换浅蓝底色 + 微信二维码（真实 img，可长按被微信识别）放左侧，信息右移 -->
          <section class="card">
            <div class="\(qrWrapClass)">
              \(qrCol)
              <div class="card-info">
                <div class="tag">米兰租赁管家 · 专业省心租好房</div>
                <div class="row"><span class="name">\(escapeHTML(name))</span><span class="num">\(escapeHTML(phone))</span></div>
                <div class="note">微信同号 · 24小时可约看房</div>
                <div class="btns">
                  <a class="btn call" href="tel:\(escapeHTML(phone))">拨打电话</a>
                  <button class="btn copy" type="button" onclick="copyPhone()">复制电话</button>
                </div>
              </div>
            </div>
          </section>
          <div class="foot">更多优质房源请与我联系-\(escapeHTML(phone))</div>
        </div>
        <div id="detailView" style="display:none">
          <button class="back" type="button" onclick="showList()">‹ 返回房源列表</button>
          <div id="detailBody"></div>
          <button class="back" type="button" onclick="showList()">返回房源列表</button>
        </div>
        </div>
        <div id="toast"></div>
        <div id="lb"><div id="lbImg"></div><div id="lbPrev" onclick="lbPrev()">‹</div><div id="lbNext" onclick="lbNext()">›</div><div id="lbClose" onclick="lbClose()">✕</div><div id="lbCnt"></div></div>
        <script>
        var GALLERY=[\(galleryJS)];var gi=0;
        function playVideo(w,src){var v=w.querySelector('video');if(!v.src){v.src=src;}var p=v.play();if(p&&p.catch){p.catch(function(){});}w.className=w.className+' playing';}
        var ROOMS=[\(roomsJS)];
        function showDetail(i){document.getElementById('listView').style.display='none';document.getElementById('detailView').style.display='block';document.getElementById('detailBody').innerHTML=ROOMS[i];window.scrollTo(0,0);}
        function showList(){document.getElementById('detailView').style.display='none';document.getElementById('listView').style.display='block';window.scrollTo(0,0);}
        function openImg(i){gi=i;show();}
        function show(){var d=document.getElementById('lb');document.getElementById('lbImg').style.backgroundImage="url('"+GALLERY[gi]+"')";document.getElementById('lbCnt').textContent=(gi+1)+' / '+GALLERY.length;d.style.display='block';}
        function lbPrev(){gi=(gi-1+GALLERY.length)%GALLERY.length;show();}
        function lbNext(){gi=(gi+1)%GALLERY.length;show();}
        function lbClose(){document.getElementById('lb').style.display='none';}
        var _sx=0;(function(){var d=document.getElementById('lb');d.addEventListener('touchstart',function(e){_sx=e.touches[0].clientX},{passive:true});d.addEventListener('touchend',function(e){var dx=e.changedTouches[0].clientX-_sx;if(Math.abs(dx)>50){dx<0?lbNext():lbPrev();}},{passive:true});})();
        function toast(msg){var t=document.getElementById('toast');t.textContent=msg;t.style.display='block';clearTimeout(t._h);t._h=setTimeout(function(){t.style.display='none'},1600);}
        function copyPhone(){var p='\(phone)';function done(){toast('已复制 '+p)}function fb(){var i=document.createElement('input');i.value=p;document.body.appendChild(i);i.select();i.setSelectionRange(0,999);document.execCommand('copy');i.remove();done()}if(navigator.clipboard&&window.isSecureContext){navigator.clipboard.writeText(p).then(done,fb)}else{fb()}}
        </script>
        \(trackScript)
        </body>
        </html>
        """
    }

    /// 合集单套详情 HTML：脱敏=户型+导航；完整=房号+户型 / 价格+密码+房东 / 备注。媒体：视频置顶、图片单列。
    /// v1.26：详情底部也加名片（拨打电话/复制电话），与单套分享页一致
    /// v1.27：详情名片同样带微信二维码（真实 <img>，可长按识别）+ 浅蓝底色
    private static func collectionDetailHTML(item: ShareCollectionItem, mode: ShareMode, videoTags: [String], imageURLs: [String], startIndex: Int, name: String, phone: String, qrSrc: String, wm: String = "") -> String {
        var parts: [String] = []
        let qrCol = qrColumnHTML(qrSrc: qrSrc)
        let qrWrapClass = qrSrc.isEmpty ? " qr-wrap center" : " qr-wrap"
        parts.append("<div class=\"dhero\">")
        if mode == .masked {
            parts.append("<div class=\"type\">\(escapeHTML(item.layout.isEmpty ? "房源" : item.layout))</div>")
            parts.append("""
            <a class="loc" href="https://uri.amap.com/search?keyword=%E5%88%A9%E4%BF%9D%E7%B1%B3%E5%85%B0%E5%85%AC%E5%AF%93" target="_blank" rel="noopener">
              <span class="loc-name">利保米兰公馆</span>
              <span class="nav-pill">导航</span>
            </a>
            """)
        } else {
            parts.append("<div class=\"l1\"><span class=\"room\">\(escapeHTML(item.displayRoomNo))</span><span class=\"price\">\(escapeHTML(item.priceText))</span></div>")
            var l2 = "<div class=\"l2\">"
            if !item.password.isEmpty { l2 += "<span class=\"pw\">密码：\(escapeHTML(item.password))</span>" }
            l2 += "<span class=\"layout2\">\(escapeHTML(item.layout.isEmpty ? "房源" : item.layout))</span>"
            if !item.landlord.isEmpty { l2 += "<span class=\"host\">\(escapeHTML(item.landlord))</span>" }
            l2 += "</div>"
            parts.append(l2)
            if !item.remark.isEmpty { parts.append("<div class=\"remark\">\(escapeHTML(item.remark))</div>") }
        }
        parts.append("</div>")
        var media = "<h2 class=\"sec\">实拍 · 点击放大</h2><div class=\"media\">"
        for tag in videoTags { media += tag }
        // v1.25：图片用 <img> 渲染（修复空白），img 自身 pointer-events:none + 外层 div 点击放大——防长按保存
        for (offset, url) in imageURLs.enumerated() {
            media += "<div class=\"cellwrap\" onclick=\"openImg(\(startIndex + offset))\"><img class=\"cell\" src=\"\(url)\" draggable=\"false\" alt=\"\">\(wm)</div>"
        }
        media += "</div>"
        parts.append(media)
        // v1.26：详情页底部名片（与单套分享页一致），名字电话来自设置页
        parts.append("""
        <section class="card">
          <div class="\(qrWrapClass)">
            \(qrCol)
            <div class="card-info">
              <div class="tag">米兰租赁管家 · 专业省心租好房</div>
              <div class="row"><span class="name">\(escapeHTML(name))</span><span class="num">\(escapeHTML(phone))</span></div>
              <div class="note">微信同号 · 24小时可约看房</div>
              <div class="btns">
                <a class="btn call" href="tel:\(escapeHTML(phone))">拨打电话</a>
                <button class="btn copy" type="button" onclick="copyPhone()">复制电话</button>
              </div>
            </div>
          </div>
        </section>
        """)
        return parts.joined(separator: "")
    }

    /// 媒体块：视频封面播放器原样输出（置顶），图片用 <img> 渲染（单列、防长按保存、点击放大进 GALLERY）
    /// v1.25：图片从 background-image div 改为 <img>（修复微信 WebView 缩略图空白）；
    ///   img 包在 .cellwrap 里且自身 pointer-events:none——长按落在外层 div 上，微信不会弹「保存图片」
    private static func mediaBlockHTML(videoTags: [String], imageURLs: [String], wm: String = "") -> String {
        var parts: [String] = []
        for tag in videoTags { parts.append(tag) }
        for (index, url) in imageURLs.enumerated() {
            parts.append("<div class=\"cellwrap\" onclick=\"openImg(\(index))\"><img class=\"cell\" src=\"\(url)\" draggable=\"false\" alt=\"\">\(wm)</div>")
        }
        guard !parts.isEmpty else { return "" }
        return "<div class=\"media\">" + parts.joined(separator: "") + "</div>"
    }

    /// 户型标题：户型 + 房号中的上下层后缀（如「单间 · 上层」）；无后缀只显示户型
    /// v1.26：户型本身已含「上/下」楼层词（如「单间下层」「独立厨房下层」）时不再拼接后缀，
    /// 彻底避免「独立厨房下层 · 下」这类重复；仅当户型完全不含上下层信息时才补后缀
    private static func layoutTitle(_ layout: String, roomNo: String) -> String {
        let suffix = roomNo.filter { !$0.isNumber && $0 != "-" && $0 != " " && $0 != "." && $0 != "/" }
        var title = layout.isEmpty ? "房源" : layout
        if !suffix.isEmpty {
            // 户型里已带上下层字样（上/下）→ 后缀信息已包含在户型内，不再拼接
            let hasFloorWord = title.contains("上") || title.contains("下")
            if !hasFloorWord, !title.hasSuffix(suffix) {
                title += " · " + suffix
            }
        }
        return title
    }

    private static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    // MARK: - v1.25 视频首帧封面图

    /// 从视频提取首帧生成 JPEG 封面（最长边 640px、质量 0.72，通常几十 KB）。
    /// v1.25：分享页视频封面改用独立首帧图——页面加载只下载小封面图，绝不预取视频流，
    /// 微信没有任何机会自动播放/预载视频；只有用户点击封面 playVideo 才注入视频 src。
    /// 提取失败返回 nil，调用方回退用视频 URL 本身当封面（微信可显示首帧）。
    private static func makeVideoThumbJPEG(from url: URL) -> Data? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        let time = CMTime(seconds: 0.1, preferredTimescale: 600)
        guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else { return nil }
        let image = UIImage(cgImage: cgImage)
        let maxSide: CGFloat = 640
        let w = image.size.width
        let h = image.size.height
        guard w > 0, h > 0 else { return nil }
        let scale = min(maxSide / max(w, h), 1)
        let target = CGSize(width: max(Int(w * scale), 1), height: max(Int(h * scale), 1))
        return scaledJPEG(image, target: target, quality: 0.72)
    }

    /// v1.29：用 UIGraphicsImageRenderer 缩放并输出 JPEG（替代已废弃的 UIGraphicsBeginImageContextWithOptions，
    /// 内存管理更优，避免隐式全局图形上下文在后台线程的告警）
    private static func scaledJPEG(_ image: UIImage, target: CGSize, quality: CGFloat) -> Data? {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        return renderer.jpegData(withCompressionQuality: quality) { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    // MARK: - 上传 / 预签名

    /// v1.29：按「媒体类型 + 云端文件扩展名」返回正确 Content-Type。
    /// 修复旧版视频恒返回 video/quicktime 的问题——安卓微信对 video/quicktime（.mov 容器）支持差，
    /// 而 mp4 云端路径应标 video/mp4，否则安卓端可能拒绝播放。
    private static func mimeType(for kind: String, name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        if kind == "video" {
            switch ext {
            case "mov": return "video/quicktime"   // 云端已统一转 mp4，此分支仅作兜底
            case "m4v": return "video/x-m4v"
            default: return "video/mp4"
            }
        }
        switch ext {
        case "png": return "image/png"
        case "heic", "heif": return "image/heic"
        default: return "image/jpeg"
        }
    }

    /// v1.29：视频云端文件名统一为 .mp4（安卓/微信可播），本地文件名保持原样（保存 mov/mp4 原文件）
    private static func cloudVideoName(for localName: String) -> String {
        ((localName as NSString).deletingPathExtension) + ".mp4"
    }

    internal static func upload(data: Data, to remotePath: String, contentType: String, config: CosConfig) async throws {
        let url = try presignedPutURL(for: remotePath, contentType: contentType, config: config)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let (respData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            // 读取 COS 返回的 XML 错误码（SignatureDoesNotMatch / InvalidAccessKeyId / AccessDenied 等），精确定位 403 原因
            let detail = extractCosError(from: respData)
            let statusText: String
            if let http = response as? HTTPURLResponse {
                statusText = "HTTP \(http.statusCode)"
            } else {
                statusText = "网络响应无效"
            }
            throw CosError.uploadFailed(statusText + (detail.isEmpty ? "" : "（" + detail + "）"))
        }
    }

    /// v1.40 第2点：HEAD 探测桶内对象是否存在（省流量，不下载对象体）
    static func remoteObjectExists(path: String, config: CosConfig) async -> Bool {
        guard let url = try? presignedURL(for: path, method: "HEAD", expires: 300, headers: [], config: config) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                return true
            }
            return false
        } catch {
            return false
        }
    }

    /// v1.40 第5点：上传单个房源媒体到共享区 h/<房号>/（图片直传；视频转 mp4 + 用户区首帧图）。
    /// 供 HouseMediaUploadQueue 自动补传；与 shareCard 内媒体上传逻辑保持一致。
    static func uploadHouseMedia(fileName: String, kind: String, roomKey: String, config: CosConfig, compress: Bool) async throws {
        let url = MediaStore.url(for: fileName, roomKey: roomKey)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CosError.uploadFailed("本地文件不存在")
        }
        let isVideo = kind == "video"
        let remoteName = isVideo ? cloudVideoName(for: fileName) : fileName
        let remotePath = "h/\(roomKey)/\(remoteName)"
        // 桶内已存在 → 幂等跳过（不重复覆盖）
        if await remoteObjectExists(path: remotePath, config: config) { return }
        var data = try Data(contentsOf: url)
        var contentType = mimeType(for: kind, name: remoteName)
        if isVideo {
            if let mp4 = await uploadVideoData(from: url, compress: compress) {
                data = mp4
                contentType = "video/mp4"
            }
        } else if compress, let compressed = compressedImageData(from: url) {
            data = compressed
            contentType = "image/jpeg"
        }
        try await upload(data: data, to: remotePath, contentType: contentType, config: config)
        // 视频同步补用户区首帧图（每次重新生成，与分享逻辑一致）
        if isVideo, let thumbData = makeVideoThumbJPEG(from: url) {
            try? await upload(data: thumbData, to: "\(CloudUser.sharePagePrefix)\(roomKey)/\(fileName).vthumb.jpg", contentType: "image/jpeg", config: config)
        }
    }

    /// v1.13 需求13：带字节级进度的上传（房源分享上传到桶时显示百分比）。
    /// progress 0~1 回调（后台线程回调，调用方自行切主线程）。
    internal static func uploadWithProgress(data: Data, to remotePath: String, contentType: String, config: CosConfig, progress: @escaping (Double) -> Void) async throws {        let url = try presignedPutURL(for: remotePath, contentType: contentType, config: config)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")

        let delegate = CosUploadProgressDelegate(onProgress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        let task = session.uploadTask(with: request, from: data)
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

    /// 从 COS 错误响应 XML 中提取 Error Code 与 Message
    internal static func extractCosError(from data: Data) -> String {        guard let text = String(data: data, encoding: .utf8) else { return "" }
        func value(of tag: String) -> String? {
            guard let start = text.range(of: "<\(tag)>")?.upperBound,
                  let end = text[start...].range(of: "</\(tag)>")?.lowerBound else { return nil }
            return String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let code = value(of: "Code") ?? ""
        let message = value(of: "Message") ?? ""
        if code.isEmpty { return "" }
        return message.isEmpty ? "错误码 \(code)" : "错误码 \(code)：\(message)"
    }

    /// v1.19：配置了自定义域名就用它（Host 与签名都指向自定义域名，微信按网页抓取）；
    /// 未配置时回退 COS 默认域名（2024 年后新建桶默认域名强制下载，微信会识别成文件——仅作兜底）
    /// v1.20：自动剥离用户误填的 https:// / http:// 前缀和尾部斜杠
    internal static func host(for config: CosConfig) -> String {
        var domain = config.customDomain.trimmingCharacters(in: .whitespacesAndNewlines)
        if !domain.isEmpty {
            for prefix in ["https://", "http://"] {
                if domain.lowercased().hasPrefix(prefix) {
                    domain = String(domain.dropFirst(prefix.count))
                }
            }
            while domain.hasSuffix("/") {
                domain.removeLast()
            }
            return domain
        }
        return "\(config.bucket).cos.\(config.region).myqcloud.com"
    }

    /// PUT 预签名：Content-Type 参与签名（COS 要求请求携带的 header 必须在签名中，否则返回 403）
    internal static func presignedPutURL(for path: String, contentType: String, config: CosConfig) throws -> URL {
        try presignedURL(for: path, method: "PUT", expires: 3600, headers: [("content-type", contentType)], config: config)
    }

    /// GET 预签名：只签 host（下载/访问链接不带自定义 header）
    internal static func presignedGetURL(for path: String, expires: Int, config: CosConfig) throws -> URL {
        try presignedURL(for: path, method: "GET", expires: expires, headers: [], config: config)
    }

    /// v1.13：ListObjectsV2 列出桶内对象（前缀匹配，分页自动翻页）。
    /// 返回 [(对象路径, 大小, 修改时间)]，路径为含前缀的完整对象 key（如 backups/快速_xxx.zip）。
    /// 用途：①备份查看页「刷新」实时同步桶内备份；②回收站彻底删除房源时列出 h/<房号>/ 前缀对象
    /// delimiter 传 "/" 时只返回该前缀下的「直接对象」（不含子目录内对象），用于跳过 backups/media/ 海量媒体镜像
    internal static func listObjects(prefix: String, delimiter: String? = nil, config: CosConfig) async throws -> [(name: String, size: Int64, date: Date)] {
        var result: [(name: String, size: Int64, date: Date)] = []
        var continuationToken: String?
        repeat {
            var params: [(String, String)] = [("list-type", "2"), ("prefix", prefix), ("encoding-type", "url")]
            if let delimiter = delimiter {
                params.append(("delimiter", delimiter))
            }
            if let token = continuationToken {
                params.append(("continuation-token", token))
            }
            let url = try presignedURL(for: "", method: "GET", expires: 300, headers: [], params: params, config: config)
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw CosError.uploadFailed("云端列表获取失败（HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)）" + extractCosError(from: data))
            }
            guard let xml = String(data: data, encoding: .utf8) else { break }
            // 解析 <Contents> 块：<Key>…</Key><LastModified>…</LastModified><Size>…</Size>
            let blocks = extractContentsBlocks(from: xml)
            for block in blocks {
                guard let key = tagValue("Key", in: block) else { continue }
                let size = Int64(tagValue("Size", in: block) ?? "0") ?? 0
                let date = parseCOSDate(tagValue("LastModified", in: block))
                result.append((name: percentDecode(key), size: size, date: date))
            }
            // 分页：IsTruncated=true 且带 NextContinuationToken
            if let truncated = tagValue("IsTruncated", in: xml), truncated == "true",
               let next = tagValue("NextContinuationToken", in: xml), !next.isEmpty {
                continuationToken = percentDecode(next)
            } else {
                continuationToken = nil
            }
        } while continuationToken != nil
        return result
    }

    /// 从 ListObjectsV2 响应 XML 中切出所有 <Contents>…</Contents> 块
    private static func extractContentsBlocks(from xml: String) -> [String] {
        var blocks: [String] = []
        var rest = xml[...]
        while let start = rest.range(of: "<Contents>"), let end = rest[start.upperBound...].range(of: "</Contents>") {
            blocks.append(String(rest[start.upperBound..<end.lowerBound]))
            rest = rest[end.upperBound...]
        }
        return blocks
    }

    /// 取 XML 单标签文本
    private static func tagValue(_ tag: String, in xml: String) -> String? {
        guard let start = xml.range(of: "<\(tag)>")?.upperBound,
              let end = xml[start...].range(of: "</\(tag)>")?.lowerBound else { return nil }
        return String(xml[start..<end])
    }

    /// COS LastModified 格式：2026-10-23T01:26:00.000Z（ISO8601）
    private static func parseCOSDate(_ text: String?) -> Date {
        guard let text = text, !text.isEmpty else { return .distantPast }
        let iso = ISO8601DateFormatter()
        return iso.date(from: text) ?? .distantPast
    }

    /// encoding-type=url 时 Key/Token 为百分号编码，解码回原样
    private static func percentDecode(_ s: String) -> String {
        s.removingPercentEncoding ?? s
    }

    /// COS V5 签名：q-sign-algorithm=sha1;q-ak=...;q-sign-time=...;q-key-time=...;q-header-list=...;q-url-param-list=...;q-signature=...
    /// 关键（严格按 COS 官方规范文档 436/7778 及官方 Python SDK cos_auth.py）：
    /// 1. HttpString = HttpMethod\nUriPathname\nHttpParameters\nHttpHeaders\n —— 恰好 3 个换行分隔 4 段，末尾再一个换行（参数为空时是两个连续换行）
    /// 2. 【根因修复】UriPathname 必须用【未编码】的原样路径参与签名（服务端会用解码后的请求路径重算校验）；
    ///    实际请求 URL 的 path 才做百分号编码
    /// 3. HttpHeaders 的 key 小写、value 按 RFC3986 编码、按字典序拼接
    /// 4. q-header-list 用分号分隔参与签名的 header key
    internal static func presignedURL(for path: String, method: String, expires: Int, headers: [(String, String)], config: CosConfig) throws -> URL {
        try presignedURL(for: path, method: method, expires: expires, headers: headers, params: [], config: config)
    }

    /// v1.13：带 URL query 参数的预签名（ListObjects 等需要）。query 参数 key 按字典序参与 HttpParameters 段与 q-url-param-list。
    internal static func presignedURL(for path: String, method: String, expires: Int, headers: [(String, String)], params: [(String, String)], config: CosConfig) throws -> URL {
        let now = Int(Date().timeIntervalSince1970)
        let signTime = "\(now);\(now + expires)"
        let keyTime = signTime

        let hostValue = host(for: config)
        let rawPath = "/" + path
        // 请求 URL 的路径做百分号编码（保留 /），中文房号目录会被编码
        let encodedPath = rawPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? rawPath

        // 组装签名 headers：key 小写、value RFC3986 编码，排序后拼接
        var pairs = headers.map { (key: $0.0.lowercased(), value: urlEncode($0.1)) }
        pairs.append(("host", hostValue.lowercased()))
        pairs.sort { $0.key < $1.key }
        let headerList = pairs.map(\.key).joined(separator: ";")
        let headerValue = pairs.map { "\($0.key)=\($0.value)" }.joined(separator: "&")

        // v1.13：URL query 参数（ListObjects 等）——key 原样（已小写）、value RFC3986 编码，按字典序
        let sortedParams = params.map { (key: $0.0.lowercased(), value: urlEncode($0.1)) }.sorted { $0.key < $1.key }
        let paramList = sortedParams.map(\.key).joined(separator: ";")
        let paramValue = sortedParams.map { "\($0.key)=\($0.value)" }.joined(separator: "&")

        let signKey = HMAC_SHA1(key: config.secretKey, message: keyTime)
        // HttpString 段结构：method\n路径\n参数\n请求头\n（参数为空时是两个连续换行）
        // 路径必须用未编码的 rawPath 参与签名（官方规范），请求 URL 才用 encodedPath
        let httpString = "\(method.lowercased())\n\(rawPath)\n\(paramValue)\n\(headerValue)\n"
        let sha1Http = SHA1(hexString: httpString)
        let stringToSign = "sha1\n\(signTime)\n\(sha1Http)\n"
        let signature = HMAC_SHA1(key: signKey, message: stringToSign)

        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = hostValue
        comps.percentEncodedPath = encodedPath
        // query 拼接：业务参数 + 签名参数
        var queryParts = sortedParams.map { "\($0.key)=\($0.value)" }
        queryParts.append("q-sign-algorithm=sha1&q-ak=\(config.secretId)&q-sign-time=\(signTime)&q-key-time=\(keyTime)&q-header-list=\(headerList)&q-url-param-list=\(paramList)&q-signature=\(signature)")
        comps.percentEncodedQuery = queryParts.joined(separator: "&")
        guard let url = comps.url else { throw CosError.invalidConfig }
        return url
    }

    /// RFC 3986 严格百分号编码（保留 A-Z a-z 0-9 - _ . ~）
    private static func urlEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")) ?? s
    }

    // MARK: - v1.19 新增：压缩封面 / 版本参数

    /// 生成微信 og:image 压缩封面：最长边 400px、JPEG 质量 0.72（通常几十 KB），微信服务端秒抓
    private static func makeCoverJPEG(from url: URL) -> Data? {
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        let maxSide: CGFloat = 400
        let w = image.size.width
        let h = image.size.height
        guard w > 0, h > 0 else { return nil }
        let scale = min(maxSide / max(w, h), 1)
        let target = CGSize(width: max(Int(w * scale), 1), height: max(Int(h * scale), 1))
        return scaledJPEG(image, target: target, quality: 0.72)
    }

    // MARK: - v1.27 名片微信二维码压缩

    /// 生成名片二维码上传图：先居中裁剪成正方形（保证 H5 上 object-fit:cover 不裁掉二维码主体），
    /// 再缩到长边 400px、JPEG q0.85（清晰且省流量）。读取失败返回 nil，调用方跳过二维码显示。
    private static func makeQRCodeJPEG() -> Data? {
        guard let data = QrcodeStore.loadData(),
              let image = UIImage(data: data) else { return nil }
        let side = min(image.size.width, image.size.height)
        guard side > 0 else { return nil }
        // 1. 居中裁剪成正方形
        let x = (image.size.width - side) / 2
        let y = (image.size.height - side) / 2
        let cropFormat = UIGraphicsImageRendererFormat.default()
        cropFormat.scale = 1
        let cropRenderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: cropFormat)
        let cropped = cropRenderer.image { _ in
            image.draw(in: CGRect(x: -x, y: -y, width: image.size.width, height: image.size.height))
        }
        // 2. 缩到最长边 400
        let maxSide: CGFloat = 400
        let scale = min(maxSide / side, 1)
        let target = CGSize(width: max(Int(side * scale), 1), height: max(Int(side * scale), 1))
        return scaledJPEG(cropped, target: target, quality: 0.85)
    }

    // MARK: - v1.23 分享时压缩（视频 720p / 图片轻压缩）

    /// 视频压缩到 720p（H.264 mp4，shouldOptimizeForNetworkUse 利于在线播放）。
    /// 源分辨率低于 720p 时导出保持源分辨率（preset 为上限不放大）；压缩失败返回 nil，调用方回退原文件。
    private static func compressedVideoData(from url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1280x720) else { return nil }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        export.outputURL = temp
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously {
                cont.resume()
            }
        }
        defer { try? FileManager.default.removeItem(at: temp) }
        guard export.status == .completed, let data = try? Data(contentsOf: temp) else { return nil }
        return data
    }

    /// v1.29：视频上传数据统一转 mp4（安卓/微信可播）：
    /// - 压缩开关开 → 720p H.264（重编码，体积小）
    /// - 压缩开关关 → 原质量转封装（先 passthrough 只换容器、秒级完成且画质零损失；失败回退原质量重编码）
    /// - 源已是 mp4 且不压缩 → 直接读原数据（零处理）
    private static func uploadVideoData(from url: URL, compress: Bool) async -> Data? {
        if !compress, url.pathExtension.lowercased() == "mp4" {
            return try? Data(contentsOf: url)
        }
        if compress {
            return await compressedVideoData(from: url)
        }
        return await mp4ContainerData(from: url)
    }

    /// 原质量转 mp4 封装：先 passthrough（不重编码，mov→mp4 秒级，画质零损失），
    /// 不适用时回退 AVAssetExportPresetHighestQuality 原质量重编码。全失败返回 nil，调用方保留原文件。
    private static func mp4ContainerData(from url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: temp) }

        if let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) {
            export.outputURL = temp
            export.outputFileType = .mp4
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                export.exportAsynchronously { cont.resume() }
            }
            if export.status == .completed, let data = try? Data(contentsOf: temp) {
                return data
            }
        }

        if let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) {
            export.outputURL = temp
            export.outputFileType = .mp4
            export.shouldOptimizeForNetworkUse = true
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                export.exportAsynchronously { cont.resume() }
            }
            if export.status == .completed, let data = try? Data(contentsOf: temp) {
                return data
            }
        }
        return nil
    }

    /// 图片轻压缩：长边压到 ≤1600px、JPEG 质量 0.8（参照微信「不加载原图」的画质，不过度压缩，观感基本无损）
    private static func compressedImageData(from url: URL) -> Data? {
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        let maxSide: CGFloat = 1600
        let w = image.size.width
        let h = image.size.height
        guard w > 0, h > 0 else { return nil }
        let scale = min(maxSide / max(w, h), 1)
        if scale >= 1 {
            return image.jpegData(compressionQuality: 0.8)
        }
        let target = CGSize(width: max(Int(w * scale), 1), height: max(Int(h * scale), 1))
        return scaledJPEG(image, target: target, quality: 0.8)
    }

    /// 在签名 URL 上追加版本参数 v。v 不参与签名（q-url-param-list 为空，COS 服务端忽略未声明参数，签名仍有效）；
    /// 内容更新后 v 变化 → 微信把链接当新链接重新抓取 og，避免命中旧卡片缓存
    private static func appendVersionParameter(_ url: URL, version: String) -> URL {
        let s = url.absoluteString + "&v=" + version
        return URL(string: s) ?? url
    }

    // MARK: - 加密原语（HMAC-SHA1 / SHA1 hex）

    private static func HMAC_SHA1(key: String, message: String) -> String {
        let keyData = Data(key.utf8)
        let msgData = Data(message.utf8)
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: msgData, using: SymmetricKey(data: keyData))
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    private static func SHA1(hexString: String) -> String {
        let data = Data(hexString.utf8)
        return Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - v1.13 上传进度 Delegate（分享上传百分比进度）

private final class CosUploadProgressDelegate: NSObject, URLSessionTaskDelegate {
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

// MARK: - v1.22 合集分享值类型

/// 多选分享合集里的单套房源数据（值类型，Task 内安全传递 + 集合缓存 JSON 编解码）
struct ShareCollectionItem: Hashable, Codable {
    let roomKey: String
    let displayRoomNo: String
    let towerLabel: String
    let layout: String
    let statusLabel: String
    let priceText: String
    let landlord: String
    let password: String
    let remark: String
    let mediaFiles: [ShareMediaFile]
}

// MARK: - v1.36 分享页水印（CSS 叠加，不动原图、不加桶存储）

enum WatermarkPosition: String, CaseIterable, Codable {
    case bottomRight, topLeft, topRight, bottomLeft
    var label: String {
        switch self {
        case .bottomRight: return "右下"
        case .topLeft: return "左上"
        case .topRight: return "右上"
        case .bottomLeft: return "左下"
        }
    }
}

struct WatermarkSettings: Codable, Equatable {
    var enabled: Bool
    var text: String
    var fontSize: Double
    var opacity: Double
    var position: WatermarkPosition
    var offsetX: Double
    var offsetY: Double

    static let defaultText = "梁涛-13288251132"
    static let `default` = WatermarkSettings(enabled: true, text: defaultText, fontSize: 14, opacity: 0.5, position: .bottomRight, offsetX: 12, offsetY: 12)
}

enum WatermarkSettingsStore {
    private static let key = "watermark.settings.v1"
    static var current: WatermarkSettings {
        get {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let s = try? JSONDecoder().decode(WatermarkSettings.self, from: data) else { return .default }
            return s
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
    }
    /// 清除自定义水印并恢复默认（默认文本 + 默认样式 + 开关恢复开启）
    static func resetToDefault() {
        current = .default
    }
}

// MARK: - v1.36 云函数配置（H5 埋点统计 + 管理后台鉴权）

// MARK: - v1.38 网页后台刷新（清缓存 + 版本戳）
// App 内「管理后台」是原生界面（直接读云函数接口，天然最新）；safari 打开的网页后台靠版本参数绕缓存。
// 网页后台每次改动（重新部署云函数 admin.html）后，点一次「刷新网页后台缓存」即可让浏览器下次强制取最新页，无需重新构建 App。

enum WebCache {
    private static let stampKey = "cloud.webCacheStamp"
    /// 网页版本戳：每次「刷新网页后台」都更新，safari 打开后台 URL 带上它 → 浏览器缓存立即失效
    static var stamp: String {
        UserDefaults.standard.string(forKey: stampKey) ?? "20261023"
    }
    /// 清 App 内 WebView 缓存 + 更新版本戳
    static func clear(completion: (() -> Void)? = nil) {
        UserDefaults.standard.set("\(Int(Date().timeIntervalSince1970))", forKey: stampKey)
        WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                                                 modifiedSince: .distantPast) {
            DispatchQueue.main.async { completion?() }
        }
    }
}

enum CloudConfig {
    // v1.40：云函数地址不再内置默认值——新装 App 的地址栏为空，由用户自行填写保存。
    // 旧版默认地址仅供升级用户参考（若 UserDefaults 无值且钥匙串有旧值则读取兼容）。
    static var functionURL: String {
        get {
            // 兼容：v1.39 及更早版本把地址存在 UserDefaults；v1.40 起统一存 UserDefaults（非敏感）。
            if let s = UserDefaults.standard.string(forKey: "cloud.functionURL"), !s.isEmpty { return s }
            if let s = KeychainStore.load("cloud.functionURL"), !s.isEmpty { return s }
            return ""
        }
        set { UserDefaults.standard.set(newValue, forKey: "cloud.functionURL") }
    }
    static func clearFunctionURL() {
        UserDefaults.standard.removeObject(forKey: "cloud.functionURL")
        _ = KeychainStore.save("", for: "cloud.functionURL")
    }
    /// 管理后台口令（网页版登录；App 内免登录直接带哈希）。默认 12345678，可在设置页修改。
    /// v1.40：改存钥匙串——重装 App 后 UserDefaults 清空但钥匙串保留，口令不丢，云端后台不会因口令回默认而 401。
    static var adminPassword: String {
        get {
            if let s = KeychainStore.load(KeychainKey.adminPassword), !s.isEmpty { return s }
            if let s = UserDefaults.standard.string(forKey: "cloud.adminPassword"), !s.isEmpty {
                _ = KeychainStore.save(s, for: KeychainKey.adminPassword)
                return s
            }
            return "12345678"
        }
        set { _ = KeychainStore.save(newValue, for: KeychainKey.adminPassword) }
    }
    static var passwordHash: String {
        let data = Data(adminPassword.utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - v1.36 水印 / 埋点 / 分享记录辅助（扩展）

extension CosUploader {
    /// 水印设置哈希（缓存校验用；djb2 稳定字符串哈希，不依赖进程内 hashValue）
    static func watermarkHash(_ wm: WatermarkSettings) -> String {
        let s = "\(wm.enabled)|\(wm.text)|\(wm.fontSize)|\(wm.opacity)|\(wm.position.rawValue)|\(wm.offsetX)|\(wm.offsetY)"
        var h: UInt64 = 5381
        for b in s.utf8 { h = (h &* 33) ^ UInt64(b) }
        return String(h)
    }

    /// 生成单张图片上的水印覆盖层（空文本或关闭 → 返回空串不渲染）
    static func watermarkOverlayHTML(_ wm: WatermarkSettings) -> String {
        guard wm.enabled, !wm.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        let x = max(0, wm.offsetX)
        let y = max(0, wm.offsetY)
        let placement: String
        switch wm.position {
        case .bottomRight: placement = "right:\(x)px;bottom:\(y)px;"
        case .bottomLeft: placement = "left:\(x)px;bottom:\(y)px;"
        case .topRight: placement = "right:\(x)px;top:\(y)px;"
        case .topLeft: placement = "left:\(x)px;top:\(y)px;"
        }
        return "<div class=\"wm\" style=\"position:absolute;\(placement)color:rgba(255,255,255,\(wm.opacity));font-size:\(wm.fontSize)px;font-weight:500;line-height:1;text-shadow:0 1px 2px rgba(0,0,0,.35);pointer-events:none;user-select:none;z-index:2;max-width:70%;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;\">\(escapeHTML(wm.text))</div>"
    }

    /// H5 埋点脚本（静默收集，不需用户同意）：GET 云函数 ?act=track&room=&mode=&ref=&t=&uname=
    /// v1.46 统计隔离：埋点带当前用户名，云端按用户分文件统计，互不干扰
    static func cloudTrackScript(room: String, mode: String) -> String {
        let url = CloudConfig.functionURL
        let roomEsc = escapeHTML(room)
        let modeEsc = escapeHTML(mode)
        let unameEsc = escapeHTML(CloudUser.username)
        return "<script>(function(){try{var u='\(url)';if(!u||u.indexOf('http')!==0)return;var k='gy_tk_'+encodeURIComponent('\(roomEsc)')+'_'+encodeURIComponent('\(modeEsc)');var now=Date.now(),last=0;try{last=parseInt(localStorage.getItem(k)||'0',10)||0;}catch(e){}if(now-last<30000)return;try{localStorage.setItem(k,String(now));}catch(e){}var r=(document.referrer||'').slice(0,120);var img=new Image();img.src=u+'?act=track&room='+encodeURIComponent('\(roomEsc)')+'&mode='+encodeURIComponent('\(modeEsc)')+'&ref='+encodeURIComponent(r)+'&t='+now+'&uname='+encodeURIComponent('\(unameEsc)');}catch(e){}})();</script>"
    }

    /// 文件名安全化：保留中文/字母/数字/-/_，其余替换为 -（房号 → 分享页文件名）
    static func safeFileName(_ s: String) -> String {
        var out = ""
        for ch in s {
            if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" { out.append(ch) }
            else if ch == " " || ch == "." || ch == "/" || ch == ":" || ch == "," || ch == "，" { out.append("-") }
        }
        return out.isEmpty ? "house" : out
    }

    /// 分享页文件名日期时间戳（yyyyMMddHHmmss）
    static func shareTimeTag() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMddHHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }

    /// 读取桶内对象（GET 签名，短时效）
    static func fetchObjectData(path: String, config: CosConfig) async throws -> Data {
        let url = try presignedGetURL(for: path, expires: 300, config: config)
        let (data, resp) = try await URLSession.shared.data(from: url)
        guard let http = resp as? HTTPURLResponse else {
            throw NSError(domain: "CosUploader", code: -1, userInfo: [NSLocalizedDescriptionKey: "读取云端对象失败: \(path)"])
        }
        // v1.42：区分「对象不存在(404)」与「其他读取失败」——404 供 fetchAll 判空，
        //         网络/HTTP 错误必须上抛，绝不能再被当作「云端没有数据」（此前 try? 吞错导致断网误删本地房源）
        if http.statusCode == 404 { throw CosObjectNotFoundError(path: path) }
        guard http.statusCode == 200 else {
            throw NSError(domain: "CosUploader", code: -1, userInfo: [NSLocalizedDescriptionKey: "读取云端对象失败: \(path)（HTTP \(http.statusCode)）"])
        }
        return data
    }

    /// v1.36：分享记录云端化——读改写桶内分享记录
    /// v1.24 改为按用户名隔离：h/_share_records_<用户名>.json，各用户只看自己发的分享
    /// v1.40 第6点：迁移到用户私有目录 users/<用户名>/share_records.json（读取兼容旧路径）
    static func appendShareRecord(roomKey: String, displayRoomNo: String, mode: ShareMode, url: String, config: CosConfig) async throws {
        let path = CloudUser.shareRecordPath
        var records: [[String: String]] = []
        if let data = try? await fetchObjectData(path: path, config: config),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] {
            records = arr
        } else if let data = try? await fetchObjectData(path: CloudUser.legacyShareRecordPath, config: config),
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] {
            // v1.40：旧路径有记录（升级前分享过）→ 先读取并随本次一并写入新路径，完成平滑迁移
            records = arr
        }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        df.locale = Locale(identifier: "zh_CN")
        records.append([
            "roomKey": roomKey,
            "room": displayRoomNo,
            "mode": mode.modeLabel,
            "time": df.string(from: Date()),
            "url": url
        ])
        if records.count > 500 { records = Array(records.suffix(500)) }
        guard let json = try? JSONSerialization.data(withJSONObject: records) else { return }
        try await upload(data: json, to: path, contentType: "application/json", config: config)
        // v1.40 B5：新路径写入成功后删除旧路径记录，避免桶里新旧两份重复（旧版 App 的兼容读取已废弃）
        if let legacyURL = try? presignedURL(for: CloudUser.legacyShareRecordPath, method: "DELETE", expires: 600, headers: [], config: config) {
            var req = URLRequest(url: legacyURL)
            req.httpMethod = "DELETE"
            if let (_, resp) = try? await URLSession.shared.data(for: req) {
                if let http = resp as? HTTPURLResponse, http.statusCode == 200 || http.statusCode == 204 || http.statusCode == 404 {
                    // 删除成功或已不存在，均视为已清理
                }
            }
        }
    }
}

// MARK: - v1.36 水印设置页（设置 → 房源分享 → 分享水印）

struct WatermarkSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var enabled: Bool
    @State private var text: String
    @State private var fontSize: Double
    @State private var opacity: Double
    @State private var position: WatermarkPosition
    @State private var offsetX: Double
    @State private var offsetY: Double
    @State private var showPreview = false
    @State private var savedFlash = false

    init() {
        let wm = WatermarkSettingsStore.current
        _enabled = State(initialValue: wm.enabled)
        _text = State(initialValue: wm.text)
        _fontSize = State(initialValue: wm.fontSize)
        _opacity = State(initialValue: wm.opacity)
        _position = State(initialValue: wm.position)
        _offsetX = State(initialValue: wm.offsetX)
        _offsetY = State(initialValue: wm.offsetY)
    }

    private var draft: WatermarkSettings {
        WatermarkSettings(enabled: enabled, text: text, fontSize: fontSize, opacity: opacity, position: position, offsetX: offsetX, offsetY: offsetY)
    }

    var body: some View {
        Form {
            Section {
                // v1.41：Toggle 改用显式 Binding——set 时立即用新值写 store，
                // 不再依赖 onChange 的闭包捕获时序，开关「即拨即生效、返回即显示最新状态」
                Toggle(isOn: Binding(
                    get: { enabled },
                    set: { newValue in
                        enabled = newValue
                        var wm = WatermarkSettingsStore.current
                        wm.enabled = newValue
                        WatermarkSettingsStore.current = wm
                    }
                )) {
                    Text("分享页加水印")
                }
            } footer: {
                Text("开启后，新生成的分享 H5 会在每张图片右下角叠加水印；已分享出去的旧链接不受影响。关闭即保存，下次分享不带水印。")
            }

            Section("水印内容") {
                TextField("水印文本", text: $text)
                    .textInputAutocapitalization(.never)
                Text("默认：\(WatermarkSettings.defaultText)").font(.footnote).foregroundStyle(.secondary)
            }

            Section("样式") {
                VStack(alignment: .leading) {
                    Text("字号：\(Int(fontSize)) px")
                    Slider(value: $fontSize, in: 10...28, step: 1)
                }
                VStack(alignment: .leading) {
                    Text("透明度：\(Int(opacity * 100))%")
                    Slider(value: $opacity, in: 0.1...0.9, step: 0.05)
                }
                Picker("位置", selection: $position) {
                    ForEach(WatermarkPosition.allCases, id: \.self) { p in
                        Text(p.label).tag(p)
                    }
                }
                VStack(alignment: .leading) {
                    Text("水平偏移：\(Int(offsetX)) pt")
                    Slider(value: $offsetX, in: 0...40, step: 1)
                }
                VStack(alignment: .leading) {
                    Text("垂直偏移：\(Int(offsetY)) pt")
                    Slider(value: $offsetY, in: 0...40, step: 1)
                }
            }

            Section {
                Button("预览效果") { showPreview = true }
                Button("保存") {
                    WatermarkSettingsStore.current = draft
                    savedFlash = true
                    dismiss()
                }
                Button("恢复默认样式", role: .destructive) {
                    // v1.40 第1点：只重置文本与样式，不强制打开开关（此前「清除」把开关强制开成 true，用户以为关不掉）
                    text = WatermarkSettings.defaultText
                    fontSize = 14
                    opacity = 0.5
                    position = .bottomRight
                    offsetX = 12
                    offsetY = 12
                    WatermarkSettingsStore.current = draft
                    savedFlash = true
                    dismiss()
                }
            } footer: {
                Text("恢复默认 = 重置水印文本与样式；开关状态保持不变。")
            }
        }
        .navigationTitle("分享水印")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPreview) {
            WatermarkPreviewView(settings: draft)
        }
    }
}

/// 水印预览：模拟分享页里的多张实拍图（利保米兰公馆 · 2-2334），
/// v1.17 需求4：水印叠加在【每张图片】的右下角（与真实 H5 的 mediaBlockHTML 一致），而非页面右下角
struct WatermarkPreviewView: View {
    let settings: WatermarkSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 0) {
                        // 模拟分享页头
                        HStack {
                            Text("利保米兰公馆").font(.headline)
                            Spacer()
                            Text("2-2334").font(.subheadline).foregroundStyle(.secondary)
                        }
                        .padding()
                        .background(Color.white)
                        // 模拟图片区：三张实拍图，每张各自叠加水印
                        VStack(spacing: 12) {
                            sampleImageCard
                            sampleImageCard
                            sampleImageCard
                        }
                        .padding()
                        Text("水印叠加在每张图片的\(settings.position.label)（与真实分享页一致）")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.bottom)
                    }
                    .background(Color.white)
                }
            }
            .navigationTitle("水印预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    /// 单张模拟实拍图（右下/四角按设置叠加水印）
    private var sampleImageCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(LinearGradient(colors: [Color(red: 0.45, green: 0.6, blue: 0.8), Color(red: 0.25, green: 0.4, blue: 0.6)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(height: 220)
            Text("实拍图示意").font(.caption).foregroundStyle(.white.opacity(0.7)).padding(12)
            watermarkLayer
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var watermarkLayer: some View {
        if settings.enabled && !settings.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let x = max(0, settings.offsetX)
            let y = max(0, settings.offsetY)
            let align: Alignment = switch settings.position {
            case .bottomRight: .bottomTrailing
            case .bottomLeft: .bottomLeading
            case .topRight: .topTrailing
            case .topLeft: .topLeading
            }
            Text(settings.text)
                .font(.system(size: CGFloat(settings.fontSize), weight: .medium))
                .foregroundStyle(.white.opacity(settings.opacity))
                .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
                .padding(.trailing, settings.position == .bottomRight || settings.position == .topRight ? CGFloat(x) : 0)
                .padding(.leading, settings.position == .bottomLeft || settings.position == .topLeft ? CGFloat(x) : 0)
                .padding(.bottom, settings.position == .bottomRight || settings.position == .bottomLeft ? CGFloat(y) : 0)
                .padding(.top, settings.position == .topRight || settings.position == .topLeft ? CGFloat(y) : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: align)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - v1.36 App 内管理后台（首页快捷操作 → 管理后台）

/// 云函数返回的获客统计
struct AdminStats: Codable {
    struct ByItem: Codable { let date: String?; let room: String?; let mode: String?; let count: Int }
    struct RecentItem: Codable { let t: String; let room: String; let mode: String; let ref: String }
    let ok: Bool
    let total: Int
    let today: Int
    let byDate: [ByItem]
    let byRoom: [ByItem]
    let byMode: [ByItem]
    let recent: [RecentItem]
}

/// 云函数返回的分享记录
struct AdminShares: Codable {
    let ok: Bool
    let records: [AdminShareRecord]
}
struct AdminShareRecord: Codable, Identifiable {
    var id: String { url }
    let room: String
    let mode: String
    let time: String
    let url: String
}

/// 桶浏览条目（当前层聚合：目录 / 文件）
struct BucketEntry: Identifiable {
    var id: String { name }
    let name: String
    let isDir: Bool
    let size: Int64
    let date: Date?
    let objectCount: Int
}

// MARK: - v1.22 云函数桶浏览 / 储存用量 / 清空统计接口（App 原生后台与网页后台一致）
struct AdminListResponse: Codable {
    let ok: Bool
    let prefix: String
    let dirs: [AdminDir]
    let files: [AdminFile]
}
struct AdminDir: Codable {
    let name: String
    let isDir: Bool
}
struct AdminFile: Codable {
    let key: String
    let name: String
    let size: Int
    let date: String
    let isDir: Bool
}
struct UsageResponse: Codable {
    let ok: Bool
    let total: Int
    let total_files: Int
    let parts: [UsagePart]
}
struct UsagePart: Codable {
    let name: String
    let size: Int
}
struct ClearStatsResponse: Codable {
    let ok: Bool
    let deleted: Int
}

struct AdminDashboardView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0
    @State private var stats: AdminStats?
    @State private var shares: [AdminShareRecord] = []
    @State private var statsError: String?
    @State private var loading = false

    // 桶管理
    @State private var bucketPrefix = ""
    @State private var bucketEntries: [BucketEntry] = []
    @State private var bucketLoading = false
    @State private var bucketError: String?
    @State private var copiedKey: String?
    // v1.22 储存用量 / 清空访问统计
    @State private var usage: UsageResponse?
    @State private var usageError: String?
    @State private var confirmClearStats = false
    @State private var clearStatsTip: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("板块", selection: $tab) {
                    Text("获客分析").tag(0)
                    Text("分享记录").tag(1)
                    Text("桶管理").tag(2)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                if tab == 0 {
                    statsView
                } else if tab == 1 {
                    sharesView
                } else {
                    bucketView
                }
            }
            .navigationTitle("管理后台")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 14) {
                        // v1.37：原生后台免登录；想用网页版（可手机电脑自适应）可一键跳浏览器，URL 带版本参数强制取最新后台页
                        Button {
                            openWebBackend()
                        } label: {
                            Image(systemName: "safari")
                        }
                        Button {
                            loadAll()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
            .onAppear(perform: loadAll)
            .alert("确认清空访问统计？", isPresented: $confirmClearStats) {
                Button("取消", role: .cancel) {}
                Button("清空", role: .destructive) { clearStats() }
            } message: {
                Text("将删除桶 statistics/ 下全部统计文件（含 test101 等测试记录），重新累计。")
            }
            .alert("清空访问统计", isPresented: Binding(
                get: { clearStatsTip != nil },
                set: { if !$0 { clearStatsTip = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(clearStatsTip ?? "")
            }
        }
    }

    private func loadAll() {
        loadStats()
        loadShares()
        loadUsage()
        if tab == 2 { loadBucket() }
    }

    /// v1.38：在系统浏览器打开云端后台网页（带免登录口令 + 动态版本戳，网页改动后浏览器强制取最新）
    private func openWebBackend() {
        let u = (CloudUser.username).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "\(CloudConfig.functionURL)?act=admin&k=\(CloudConfig.passwordHash)&u=\(u)&v=\(WebCache.stamp)") {
            UIApplication.shared.open(url)
        }
    }

    // MARK: 获客分析

    private var statsView: some View {
        Group {
            if let stats = stats {
                List {
                    // v1.23 清空访问统计按钮（储存用量已移到「桶管理」页）
                    Section {
                        Button("清空访问统计", role: .destructive) {
                            confirmClearStats = true
                        }
                        .font(.subheadline)
                    }
                    Section {
                        HStack {
                            StatCard(title: "累计访问", value: "\(stats.total)")
                            StatCard(title: "今日访问", value: "\(stats.today)")
                        }
                        .listRowInsets(EdgeInsets())
                        .padding(.horizontal)
                    }
                    Section("按日期") {
                        ForEach(stats.byDate, id: \.date) { item in
                            HStack {
                                Text(item.date ?? "—").font(.subheadline)
                                Spacer()
                                Text("\(item.count)").bold().foregroundStyle(.tint)
                            }
                        }
                    }
                    Section("按房号") {
                        ForEach(stats.byRoom, id: \.room) { item in
                            HStack {
                                Text(item.room ?? "—").font(.subheadline)
                                Spacer()
                                Text("\(item.count)").bold().foregroundStyle(.tint)
                            }
                        }
                    }
                    Section("按模式") {
                        ForEach(stats.byMode, id: \.mode) { item in
                            HStack {
                                Text(item.mode ?? "—").font(.subheadline)
                                Spacer()
                                Text("\(item.count)").bold().foregroundStyle(.tint)
                            }
                        }
                    }
                    Section("最近访问") {
                        ForEach(Array(stats.recent.enumerated()), id: \.offset) { _, item in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(item.room).font(.subheadline).bold()
                                    Text(item.mode).font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Text(item.t).font(.caption).foregroundStyle(.secondary)
                                }
                                if !item.ref.isEmpty {
                                    Text("来源：\(item.ref)").font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    } footer: {
                        // v1.46 统计隔离：明确提示当前统计归属
                        Text("统计仅包含当前用户名「\(CloudUser.displayName)」名下埋点，各用户互不干扰。")
                    }
                }
                .listStyle(.insetGrouped)
            } else if let statsError = statsError {
                ContentUnavailableView {
                    Label("统计加载失败", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(statsError)
                } actions: {
                    Button("重试") { loadStats() }
                }
            } else {
                ProgressView("加载统计…")
            }
        }
    }

    /// v1.40 第4点（B4）：云函数请求失败的统一文案——401 明确提示后台口令不匹配，跳转设置页修改
    private func cloudFunctionError(_ resp: URLResponse?, fallback: String) -> String {
        if let http = resp as? HTTPURLResponse, http.statusCode == 401 {
            return "后台口令不匹配（请到 设置→云端配置→后台口令 修改后重试）"
        }
        if let http = resp as? HTTPURLResponse {
            return "云函数请求失败（HTTP \(http.statusCode)），请确认函数已部署且地址正确"
        }
        return fallback
    }

    private func loadStats() {
        stats = nil
        statsError = nil
        // v1.46 统计隔离：带当前用户名，云端只返回该用户的统计
        let u = (CloudUser.username).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "\(CloudConfig.functionURL)?act=stats&k=\(CloudConfig.passwordHash)&u=\(u)") else {
            statsError = "云函数地址无效"
            return
        }
        URLSession.shared.dataTask(with: url) { data, resp, _ in
            guard let data = data,
                  let obj = try? JSONDecoder().decode(AdminStats.self, from: data), obj.ok else {
                DispatchQueue.main.async { statsError = self.cloudFunctionError(resp, fallback: "云函数未返回有效数据（请确认函数已部署）") }
                return
            }
            DispatchQueue.main.async { stats = obj }
        }.resume()
    }

    // MARK: 分享记录

    /// v1.41：分享记录加载完成标志——云函数返回「空记录」时不再无限转圈（此前的三分支缺空态，永远 ProgressView）
    @State private var sharesLoaded = false

    private var sharesView: some View {
        Group {
            if !shares.isEmpty {
                List {
                    Section {
                        ForEach(shares) { r in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(r.room).font(.subheadline).bold()
                                    Text(r.mode).font(.caption).padding(.horizontal, 6).padding(.vertical, 1)
                                        .background(.tint.opacity(0.12)).clipShape(Capsule())
                                    Spacer()
                                    Text(r.time).font(.caption).foregroundStyle(.secondary)
                                }
                                Button {
                                    UIPasteboard.general.string = r.url
                                    copiedKey = r.url
                                } label: {
                                    Label(copiedKey == r.url ? "已复制" : "复制链接", systemImage: copiedKey == r.url ? "checkmark" : "doc.on.doc")
                                        .font(.caption)
                                }
                                .foregroundStyle(.tint)
                            }
                        }
                    } footer: {
                        Text("分享记录按用户名隔离存于云端桶（users/<用户名>/share_records.json），各用户只看自己发的分享。")
                    }
                }
                .listStyle(.insetGrouped)
            } else if sharesLoaded {
                // v1.41：空记录终态——「还没有分享过」而非一直转圈
                ContentUnavailableView {
                    Label("暂无分享记录", systemImage: "square.and.arrow.up")
                } description: {
                    Text("分享过房源后，记录会显示在这里。")
                } actions: {
                    Button("刷新") { loadShares() }
                }
            } else if let statsError = statsError {
                ContentUnavailableView {
                    Label("记录加载失败", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(statsError)
                } actions: {
                    Button("重试") { loadShares() }
                }
            } else {
                ProgressView("加载分享记录…")
            }
        }
    }

    private func loadShares() {
        shares = []
        statsError = nil
        sharesLoaded = false
        // v1.24：按用户名读自己的分享记录（云函数 do_shares 按 u 过滤）
        let u = (CloudUser.username).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "\(CloudConfig.functionURL)?act=shares&k=\(CloudConfig.passwordHash)&u=\(u)") else {
            statsError = "云函数地址无效"
            return
        }
        URLSession.shared.dataTask(with: url) { data, resp, _ in
            guard let data = data,
                  let obj = try? JSONDecoder().decode(AdminShares.self, from: data), obj.ok else {
                DispatchQueue.main.async { statsError = self.cloudFunctionError(resp, fallback: "云函数未返回分享记录（请确认函数已部署）") }
                return
            }
            DispatchQueue.main.async {
                shares = obj.records
                sharesLoaded = true
            }
        }.resume()
    }

    // MARK: 桶管理

    private var bucketView: some View {
        Group {
            if let config = CosConfig.load(), config.isValid {
                VStack(alignment: .leading, spacing: 0) {
                    if !bucketPrefix.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 4) {
                                Button {
                                    bucketPrefix = ""
                                    loadBucket()
                                } label: {
                                    Text("桶根").font(.caption)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                ForEach(breadcrumbs, id: \.self) { crumb in
                                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                                    Button {
                                        bucketPrefix = crumb
                                        loadBucket()
                                    } label: {
                                        Text(crumb.split(separator: "/").last.map(String.init) ?? crumb).font(.caption)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 6)
                        }
                    }
                    List {
                        // v1.23 桶储存用量（从获客分析移到桶管理）+ 访问腾讯云储存桶
                        Section {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("桶储存用量").font(.subheadline).foregroundStyle(.secondary)
                                    Spacer()
                                    Button { loadUsage() } label: { Image(systemName: "arrow.clockwise") }
                                        .foregroundStyle(.tint)
                                        .buttonStyle(.borderless)
                                }
                                if let usage = usage {
                                    HStack {
                                        Text(ByteCountFormatter.string(fromByteCount: Int64(usage.total), countStyle: .file))
                                            .font(.system(size: 24, weight: .bold, design: .rounded))
                                        Text("\(usage.total_files) 个文件").font(.caption).foregroundStyle(.secondary)
                                    }
                                    ForEach(usage.parts, id: \.name) { p in
                                        HStack {
                                            Text(p.name).font(.subheadline)
                                            Spacer()
                                            Text(ByteCountFormatter.string(fromByteCount: Int64(p.size), countStyle: .file))
                                                .font(.subheadline).foregroundStyle(.secondary)
                                        }
                                    }
                                } else if let usageError = usageError {
                                    HStack {
                                        Text("用量加载失败").font(.subheadline).foregroundStyle(.secondary)
                                        Spacer()
                                        Button("重试") { loadUsage() }.font(.subheadline).buttonStyle(.borderless)
                                    }
                                } else {
                                    ProgressView("加载用量…")
                                }
                            }
                            Button {
                                openCOSConsole()
                            } label: {
                                Label("访问腾讯云储存桶（浏览器登录）", systemImage: "arrow.up.right.square")
                            }
                            .buttonStyle(.borderless)
                        }
                        Section {
                            ForEach(bucketEntries) { entry in
                                if entry.isDir {
                                    Button {
                                        bucketPrefix = entry.name
                                        loadBucket()
                                    } label: {
                                        HStack {
                                            Image(systemName: "folder").foregroundStyle(.tint)
                                            Text(entry.name.split(separator: "/").last.map(String.init) ?? entry.name)
                                            Spacer()
                                            Text("\(entry.objectCount) 个对象").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                } else {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Image(systemName: "doc").foregroundStyle(.secondary)
                                            Text(entry.name.split(separator: "/").last.map(String.init) ?? entry.name)
                                                .font(.subheadline).lineLimit(1)
                                            Spacer()
                                            Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        if let date = entry.date {
                                            Text(date.formatted(date: .numeric, time: .shortened))
                                                .font(.caption2).foregroundStyle(.tertiary)
                                        }
                                        HStack(spacing: 12) {
                                            Button {
                                                UIPasteboard.general.string = "\(sharePrefix)\(entry.name)"
                                                copiedKey = entry.name
                                            } label: {
                                                Label(copiedKey == entry.name ? "已复制" : "复制下载链接", systemImage: copiedKey == entry.name ? "checkmark" : "doc.on.doc")
                                                    .font(.caption)
                                            }
                                            .foregroundStyle(.tint)
                                            .buttonStyle(.borderless)
                                            Button(role: .destructive) {
                                                confirmDelete(entry: entry)
                                            } label: {
                                                Label("删除", systemImage: "trash").font(.caption)
                                            }
                                            .buttonStyle(.borderless)
                                        }
                                    }
                                }
                            }
                        } footer: {
                            Text(bucketPrefix.isEmpty ? "桶内对象（含子目录逐级展开）" : "当前目录：\(bucketPrefix.isEmpty ? "桶根" : bucketPrefix)")
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            } else {
                ContentUnavailableView {
                    Label("未配置云存储", systemImage: "server.rack")
                } description: {
                    Text("请先在 设置 → 房源分享 → 远程配置 填写 COS 密钥并验证")
                }
            }
        }
    }

    private var sharePrefix: String {
        if let config = CosConfig.load(), !config.customDomain.isEmpty {
            return "https://\(config.customDomain)/"
        }
        return ""
    }

    /// v1.23 跳转腾讯云 COS 控制台（浏览器登录后可直接管理储存桶）
    private func openCOSConsole() {
        if let url = URL(string: "https://console.cloud.tencent.com/cos/bucket") {
            UIApplication.shared.open(url)
        }
    }

    private var breadcrumbs: [String] {
        let segs = bucketPrefix.split(separator: "/").map(String.init)
        var crumbs: [String] = []
        var path = ""
        for s in segs {
            path = path.isEmpty ? s : path + "/" + s
            crumbs.append(path + "/")
        }
        return crumbs
    }

    private func loadBucket() {
        bucketLoading = true
        bucketError = nil
        let prefix = bucketPrefix
        // v1.22 改走云函数 adminList（与网页后台一致）：点进房源文件夹自动展开 media/，图片视频直接显示
        let esc = prefix.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "\(CloudConfig.functionURL)?act=adminList&k=\(CloudConfig.passwordHash)&prefix=\(esc)") else {
            bucketError = "云函数地址无效"
            bucketLoading = false
            return
        }
        URLSession.shared.dataTask(with: url) { data, resp, _ in
            guard let data = data,
                  let obj = try? JSONDecoder().decode(AdminListResponse.self, from: data), obj.ok else {
                DispatchQueue.main.async { bucketError = self.cloudFunctionError(resp, fallback: "云函数未返回桶数据（请确认函数已部署）"); bucketLoading = false }
                return
            }
            let iso = ISO8601DateFormatter()
            var entries: [BucketEntry] = []
            for d in obj.dirs {
                entries.append(BucketEntry(name: d.name, isDir: true, size: 0, date: nil, objectCount: 0))
            }
            for f in obj.files {
                entries.append(BucketEntry(name: f.name, isDir: false, size: Int64(f.size),
                                           date: iso.date(from: f.date), objectCount: 1))
            }
            DispatchQueue.main.async {
                bucketEntries = entries
                bucketLoading = false
            }
        }.resume()
    }

    /// v1.22 拉取桶储存用量（云函数 usage）
    private func loadUsage() {
        usage = nil
        usageError = nil
        guard let url = URL(string: "\(CloudConfig.functionURL)?act=usage&k=\(CloudConfig.passwordHash)") else {
            usageError = "云函数地址无效"
            return
        }
        URLSession.shared.dataTask(with: url) { data, resp, _ in
            guard let data = data, let obj = try? JSONDecoder().decode(UsageResponse.self, from: data), obj.ok else {
                DispatchQueue.main.async { usageError = self.cloudFunctionError(resp, fallback: "用量加载失败（请确认函数已部署）") }
                return
            }
            DispatchQueue.main.async { usage = obj }
        }.resume()
    }

    /// v1.22 清空访问统计（云函数 clearStats）
    /// v1.46 统计隔离：带当前用户名，只清空当前用户的统计
    private func clearStats() {
        let u = (CloudUser.username).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "\(CloudConfig.functionURL)?act=clearStats&k=\(CloudConfig.passwordHash)&u=\(u)") else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            let msg: String
            if let data = data, let obj = try? JSONDecoder().decode(ClearStatsResponse.self, from: data), obj.ok {
                msg = "已清空 \(obj.deleted) 个统计文件，访问统计已清零"
            } else {
                msg = "清空失败，请稍后再试"
            }
            DispatchQueue.main.async {
                confirmClearStats = false
                clearStatsTip = msg
                loadStats()
                loadUsage()
            }
        }.resume()
    }

    private func confirmDelete(entry: BucketEntry) {
        guard let config = CosConfig.load(), config.isValid else { return }
        let title: String
        let message: String
        // v1.40 第12点：桶管理删除只删云端对象，本地文件一律保留（此前文案「本地与云端同步生效」误导）
        if entry.isDir {
            title = "删除云端目录 \(entry.name.split(separator: "/").last.map(String.init) ?? entry.name)"
            message = "仅删除云端该目录下 \(entry.objectCount) 个对象，本机文件不受影响。删除后不可恢复，确认？"
        } else {
            title = "删除云端文件 \(entry.name.split(separator: "/").last.map(String.init) ?? entry.name)"
            message = "仅删除云端该对象，本机文件不受影响。删除后不可恢复，确认？"
        }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "仅删云端", style: .destructive) { _ in
            Task {
                do {
                    if entry.isDir {
                        let objects = try await CosUploader.listObjects(prefix: entry.name, config: config)
                        for o in objects {
                            try? await CloudBackupService.deleteRemoteObject(name: o.name, config: config)
                        }
                        try? await CloudBackupService.deleteRemoteObject(name: entry.name, config: config)
                    } else {
                        try await CloudBackupService.deleteRemoteObject(name: entry.name, config: config)
                    }
                    await MainActor.run { loadBucket() }
                } catch {
                    await MainActor.run { bucketError = "删除失败：\(error.localizedDescription)" }
                }
            }
        })
        topViewController()?.present(alert, animated: true)
    }

    private func topViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.windows.first?.rootViewController else { return nil }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        return top
    }
}

/// 获客分析顶部指标卡
struct StatCard: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 26, weight: .bold, design: .rounded))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - v1.19 多用户（用户名）

/// 每台设备一个用户名：操作日志 / 分享 / 统计都带着它；桶内私有数据按用户名分目录隔离。
/// 房源共享走公共区 h/，不受用户名影响。
enum CloudUser {
    private static let key = "cloud.username"
    static var username: String {
        get { UserDefaults.standard.string(forKey: key) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
    static var displayName: String { username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未设置" : username }
    /// v1.24：多用户数据隔离——用户名不设默认（默认空，不预填「涛」），强制用户自行设置。
    /// 隔离路径里空用户名用「未设置」占位，绝不落到公共前缀（避免不同设备误共用同一目录互相覆盖）。
    /// 返回去首尾空白的用户名；为空返回「未设置」。
    static var safeName: String {
        let t = username.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "未设置" : t
    }
    // MARK: v1.40 云端按用户名分目录（第6点：一个用户名一个文件夹，该用户名下所有私有数据都在里面）
    /// 用户私有根目录：users/<用户名>/
    static var userRootPrefix: String { "users/\(safeName)/" }
    /// 用户私有分享产物（H5 页面 / 封面 / 视频首帧图）：users/<用户名>/shares/
    static var sharePagePrefix: String { "users/\(safeName)/shares/" }
    /// 用户私有名片二维码：users/<用户名>/qrcode.jpg（原公共 h/_qrcode/qr.jpg，避免他用户读到）
    static var qrPath: String { "users/\(safeName)/qrcode.jpg" }
    /// 云端备份隔离前缀：users/<用户名>/backups/（v1.40 从 backups/<用户名>/ 迁移，旧路径读取时兼容）
    static var backupPrefix: String { "users/\(safeName)/backups/" }
    /// 分享记录隔离路径：users/<用户名>/share_records.json（v1.40 从 h/_share_records_<用户名>.json 迁移，读取兼容旧路径）
    static var shareRecordPath: String { "users/\(safeName)/share_records.json" }
    /// v1.40：旧版分享记录路径（读取兼容，迁移期只读）
    static var legacyShareRecordPath: String { "h/_share_records_\(safeName).json" }
    /// v1.40：全量备份的媒体镜像（按 sha1 去重，v1.40 起收进用户目录）：users/<用户名>/media/
    static var mediaMirrorPrefix: String { "users/\(safeName)/media/" }
    /// v1.24：旧版媒体镜像前缀（读取兼容，迁移期只读；不再写入）
    static var legacyMediaMirrorPrefix: String { "backups/media/" }
}

// MARK: - v1.37 云端操作记录（操作日志云端区）
// 同桶多用户对桶的操作（增删改房源、删桶文件、清空统计等）统一记到桶 h/_ops.json，带用户名。
// App 操作日志分「本机操作」（本地）+「云端操作」（桶记录，显示操作者用户名）。

struct CloudOpEntry: Codable, Identifiable, Hashable {
    var id: String { "\(t)|\(op)|\(room)|\(user)|\(detail)" }
    let t: String
    let op: String
    let room: String
    let user: String
    let detail: String
}
struct CloudOpsResponse: Codable {
    let ok: Bool
    let records: [CloudOpEntry]
}

enum CloudOps {
    static var isConfigured: Bool {
        !CloudConfig.functionURL.isEmpty && !CloudConfig.passwordHash.isEmpty
    }
    private static var baseURL: URL? { URL(string: CloudConfig.functionURL) }

    /// 本机发起云端操作 → 写一条云端操作记录（带当前用户名）
    static func log(category: String, action: String, result: String, detail: String, room: String = "") {
        guard isConfigured, let base = baseURL else { return }
        let op = "\(category)·\(action)·\(result)"
        var q = URLComponents()
        q.queryItems = [
            .init(name: "act", value: "logOp"),
            .init(name: "k", value: CloudConfig.passwordHash),
            .init(name: "op", value: op),
            .init(name: "room", value: room),
            .init(name: "uname", value: CloudUser.username),
            .init(name: "detail", value: detail),
        ]
        guard let query = q.percentEncodedQuery, let url = URL(string: base.absoluteString + "?" + query) else { return }
        URLSession.shared.dataTask(with: url).resume()
    }

    /// 拉取云端操作记录（日志查看器云端区）
    static func fetch(completion: @escaping ([CloudOpEntry]) -> Void) {
        guard isConfigured, let base = baseURL else { completion([]); return }
        let u = CloudUser.username.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "\(base.absoluteString)?act=ops&k=\(CloudConfig.passwordHash)&u=\(u)") else { completion([]); return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data, let obj = try? JSONDecoder().decode(CloudOpsResponse.self, from: data), obj.ok else { completion([]); return }
            completion(obj.records)
        }.resume()
    }

    /// 删除一条云端操作记录（云端区左滑/多选删除）
    static func delete(_ e: CloudOpEntry, completion: (() -> Void)? = nil) {
        guard isConfigured, let base = baseURL else { completion?(); return }
        let u = CloudUser.username.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        var q = URLComponents()
        q.queryItems = [
            .init(name: "act", value: "delOp"), .init(name: "k", value: CloudConfig.passwordHash), .init(name: "u", value: u),
            .init(name: "t", value: e.t), .init(name: "op", value: e.op), .init(name: "room", value: e.room),
            .init(name: "user", value: e.user), .init(name: "detail", value: e.detail),
        ]
        guard let query = q.percentEncodedQuery, let url = URL(string: base.absoluteString + "?" + query) else { completion?(); return }
        URLSession.shared.dataTask(with: url) { _, _, _ in DispatchQueue.main.async { completion?() } }.resume()
    }
}

// MARK: - v1.19 云端房源账本（共享房源的结构化数据）

/// 房源「账本」单条：只含结构化字段 + 媒体文件名清单；媒体文件仍存 h/<roomKey>/<name>。
/// 多台设备共享这一份账本（最后写入优先，不搞冲突合并）。
struct CloudHouseRecord: Codable, Identifiable {
    var id: String { roomKey }
    var roomKey: String
    var roomNo: String
    var tower: Int
    var landlord: String
    var layout: String
    var price: Int
    var password: String
    var remark: String
    var status: String
    var updatedAt: Date
    var updatedBy: String
    var mediaNames: [String]
}

/// 云端房源账本读写：桶内 h/_houses.json（覆盖写，读改写）。任何失败由调用方 try? 静默处理。
/// v1.42：云端对象不存在（HTTP 404）——供账本等读取方区分「真没有」与「读失败（网络/服务异常）」。
/// 断网误删本地房源事故的根因修复：此前 fetchAll 用 try? 吞掉所有错误、把读失败当空账本，
/// 导致无网络时把本地全部房源误判为「云端已删」并被硬删。
struct CosObjectNotFoundError: Error, LocalizedError {
    let path: String
    var errorDescription: String? { "云端对象不存在: \(path)" }
}

enum CloudHouseSync {
    static let accountPath = "h/_houses.json"

    static func record(from house: House, username: String) -> CloudHouseRecord {
        CloudHouseRecord(
            roomKey: house.mediaRoomKey,
            roomNo: house.roomNo,
            tower: house.tower,
            landlord: house.landlord,
            layout: house.layout,
            price: house.price,
            password: house.password,
            remark: house.remark,
            status: house.statusRaw,
            updatedAt: house.lastUpdatedAt ?? house.updatedAt,
            updatedBy: username,
            mediaNames: house.mediaItems.map { $0.fileName }
        )
    }

    /// 拉取云端账本。
    /// v1.42：仅「对象确实不存在(404)」返回空数组（首次使用/从未上传）；网络、HTTP 非 404、
    /// 解析失败一律 throw——读失败必须报「同步失败」，绝不能再被当成「云端没有房源」而误删本地。
    static func fetchAll(config: CosConfig) async throws -> [CloudHouseRecord] {
        let data: Data
        do {
            data = try await CosUploader.fetchObjectData(path: accountPath, config: config)
        } catch let e as CosObjectNotFoundError {
            return []
        }
        guard let arr = try? JSONDecoder().decode([CloudHouseRecord].self, from: data) else {
            throw NSError(domain: "CloudHouseSync", code: -1, userInfo: [NSLocalizedDescriptionKey: "云端房源账本解析失败（格式异常）"])
        }
        return arr
    }

    /// 覆盖写整个账本
    static func uploadRecords(_ records: [CloudHouseRecord], config: CosConfig) async throws {
        let data = try JSONEncoder().encode(records)
        try await CosUploader.upload(data: data, to: accountPath, contentType: "application/json", config: config)
    }

    /// 上传单个房源（读改写：同房号覆盖）
    static func uploadOne(house: House, username: String, config: CosConfig) async throws {
        try await upload(record: record(from: house, username: username), config: config)
    }

    /// 上传单条记录（读改写：同房号覆盖）
    static func upload(record: CloudHouseRecord, config: CosConfig) async throws {
        var recs = try await fetchAll(config: config)
        recs.removeAll { $0.roomKey == record.roomKey }
        recs.append(record)
        try await uploadRecords(recs, config: config)
    }

    /// 删除云端某房
    static func delete(roomKey: String, config: CosConfig) async throws {
        var recs = try await fetchAll(config: config)
        recs.removeAll { $0.roomKey == roomKey }
        try await uploadRecords(recs, config: config)
    }
}

// MARK: - v1.19 纯云端房源下载到本地

extension CosUploader {
    /// 把云端 h/<roomKey>/ 的媒体下载到本地 MediaStore 目录，返回 (本地文件名, kind)。
    /// v1.37：改为幂等回补——本地已存在同名文件直接跳过，缺失的用云端原名写回（不产生重复文件）。
    /// v1.41：视频名归一化——云端视频统一 .mp4，本地写回 .mov（与账本 mediaNames 的本地原始名一致），
    ///        彻底消除「账本 .mov ↔ 本地磁盘 .mp4」的同步误判（此前每次同步都误报媒体缺失）。
    /// v1.43 重写（修复「每次同步都下载N删N」循环与「本地删文件后刷不回」）：
    ///   - **只下载 expectedNames（云端账本名单）里的文件**——桶目录里多出来的
    ///     非账本对象（视频首帧图 .vthumb.jpg、旧分享页 .html、cover 等）一律不下载、不进记录，
    ///     从源头消除「下载↔删除互抵」的死循环；
    ///   - **落盘名与账本名单完全一致**（视频桶对象 .mp4 ↔ 账本名 .mov/.mp4 按账本名写回），
    ///     同步完成后本地记录 = 账本名单，下次同步零差异；
    ///   - 本地磁盘已有账本名（或桶同名对象）→ 跳过（幂等，不重复下载）。
    static func downloadHouseMedia(roomKey: String, expectedNames: [String], config: CosConfig, progress: ((Double) -> Void)? = nil) async throws -> [(fileName: String, kind: String)] {
        let objs = try await listObjects(prefix: "h/\(roomKey)/", config: config)
        // 桶对象名（归一化 key：去扩展名小写）→ 对象完整路径；只收媒体对象（图片/视频），跳过首帧图/分享页/cover
        var remotePathByNormKey: [String: String] = [:]
        for obj in objs {
            let name = (obj.name as NSString).lastPathComponent
            let lower = name.lowercased()
            let isVideo = lower.hasSuffix(".mp4") || lower.hasSuffix(".mov")
            let isImage = [".jpg", ".jpeg", ".png", ".heic", ".webp", ".gif"].contains { lower.hasSuffix($0) }
            guard isVideo || isImage else { continue }
            let normKey = (name as NSString).deletingPathExtension.lowercased()
            if remotePathByNormKey[normKey] == nil {
                remotePathByNormKey[normKey] = obj.name
            }
        }
        var result: [(fileName: String, kind: String)] = []
        let existing = MediaStore.existingFileNames(roomKey: roomKey)
        let total = max(1, expectedNames.count)
        for (idx, expected) in expectedNames.enumerated() {
            // v1.42：按账本名单推进同步进度（卡片底部进度条，云端 → 本机）
            progress?(Double(idx) / Double(total))
            let lower = expected.lowercased()
            let isVideo = lower.hasSuffix(".mp4") || lower.hasSuffix(".mov")
            let isImage = [".jpg", ".jpeg", ".png", ".heic", ".webp", ".gif"].contains { lower.hasSuffix($0) }
            guard isVideo || isImage else { continue }
            let expNormKey = (expected as NSString).deletingPathExtension.lowercased()
            // 桶里按归一化 key 找等价对象（视频 .mp4 ↔ .mov 等价；图片同名）——找不到说明账本与桶不一致，跳过不硬下
            guard let remotePath = remotePathByNormKey[expNormKey] else { continue }
            // 磁盘已有（账本名或桶同名对象）→ 跳过（幂等回补）
            if existing.contains(expected) || existing.contains((remotePath as NSString).lastPathComponent) { continue }
            let data = try await fetchObjectData(path: remotePath, config: config)
            // 落盘用账本名 expected（与账本零差异），视频不再强制 .mov——账本是 .mp4 就落 .mp4
            _ = MediaStore.write(data: data, fileName: expected, roomKey: roomKey)
            result.append((expected, isVideo ? "video" : "image"))
        }
        progress?(1.0)
        return result
    }

    /// v1.41：删除单条媒体的云端对象——图片删 h/<房号>/<原名>；视频删 h/<房号>/<同名>.mp4，
    /// 并顺带清用户私有区的视频首帧缩略图。编辑保存删除媒体时调用，保证「删了别人也看不到」。
    /// 无云端配置或对象不存在时静默跳过（不打断本地删除）。
    static func deleteRemoteMedia(fileName: String, kind: String, roomKey: String, config: CosConfig?) async throws {
        guard let config = config ?? CosConfig.load(), config.isValid, !fileName.isEmpty else { return }
        let remoteName = kind == "video" ? ((fileName as NSString).deletingPathExtension) + ".mp4" : fileName
        try? await CloudBackupService.deleteRemoteObject(name: "h/\(roomKey)/\(remoteName)", config: config)
        if kind == "video" {
            try? await CloudBackupService.deleteRemoteObject(name: "\(CloudUser.sharePagePrefix)\(roomKey)/\(fileName).vthumb.jpg", config: config)
        }
    }
}
