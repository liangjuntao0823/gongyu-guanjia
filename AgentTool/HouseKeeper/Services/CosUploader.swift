import Foundation
import CryptoKit
import Security
import UIKit
import AVFoundation

// MARK: - 钥匙串存取（COS 密钥等敏感配置）

enum KeychainKey {
    static let bucket = "cos.bucket"
    static let region = "cos.region"
    static let secretId = "cos.secretId"
    static let secretKey = "cos.secretKey"
    static let customDomain = "cos.customDomain"   // v1.19：自定义域名（可空），空 = 用 COS 默认域名
    static let shareName = "share.name"            // v1.21：分享名片-姓名（可空，空 = 梁涛）
    static let sharePhone = "share.phone"          // v1.21：分享名片-电话（可空，空 = 13288251132）
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
    static func shareCard(mediaFiles: [ShareMediaFile], roomKey: String, info: ShareHouseInfo, mode: ShareMode, config: CosConfig) async throws -> URL {
        guard !mediaFiles.isEmpty else { throw CosError.missingMedia }
        // v1.20：微信渲染卡片必须走自定义域名；没填就不生成链接，直接告诉用户去哪填
        guard !config.customDomain.isEmpty else { throw CosError.customDomainMissing }

        // 0. 缓存命中（按模式）：媒体清单、房源信息、COS 配置（含自定义域名）都没变化 → 直接复用上次链接，零上传
        // v1.23：压缩开关也纳入缓存校验——开关变化 → 旧缓存失效 → 重新压缩上传
        // v1.25：HTML 模板版本纳入校验——模板改动 → 旧缓存失效 → 重新生成新页面（避免改设计后还用旧链接）
        // v1.27：二维码是否存在（qrcodeSet）纳入校验——设置/清除二维码后旧缓存失效重新生成
        let compressOnShare = UserDefaults.standard.bool(forKey: "compressOnShare")
        let hasQR = QrcodeStore.exists()
        if let cached = ShareCacheStore.load(roomKey: roomKey, mode: mode.rawValue),
           cached.bucket == config.bucket,
           cached.region == config.region,
           (cached.customDomain ?? "") == config.customDomain,
           (cached.compressOnShare ?? false) == compressOnShare,
           (cached.templateVersion ?? 0) == htmlTemplateVersion,
           (cached.qrcodeSet ?? false) == hasQR,
           Set(cached.mediaFiles) == Set(mediaFiles),
           cached.info == info,
           let cachedURL = URL(string: cached.shareURL) {
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
        var videoTags: [String] = []
        var imageAbsURLs: [String] = []
        for item in ordered {
            // v1.29：视频云端路径统一用 .mp4（安卓/微信可播）。本地保留原文件，上传/引用的是 mp4
            let isVideo = item.kind == "video"
            let remoteName = isVideo ? cloudVideoName(for: item.name) : item.name
            let remotePath = "h/\(roomKey)/\(remoteName)"
            if toUpload.contains(item) {
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
                try await upload(data: data, to: remotePath, contentType: contentType, config: config)
                // v1.25：视频同时上传首帧封面图（几十 KB），页面封面用图片而非视频流
                if isVideo, let thumbData = makeVideoThumbJPEG(from: url) {
                    try? await upload(data: thumbData, to: "h/\(roomKey)/\(item.name).vthumb.jpg", contentType: "image/jpeg", config: config)
                }
            }
            let absURL = try presignedGetURL(for: remotePath, expires: shareLinkExpires, config: config).absoluteString
            if isVideo {
                // v1.25：video 无 src、无 poster、无 autoplay；封面用独立首帧图；点击封面 playVideo 才注入 src 并播放
                let thumbURL = (try? presignedGetURL(for: "h/\(roomKey)/\(item.name).vthumb.jpg", expires: shareLinkExpires, config: config).absoluteString) ?? absURL
                videoTags.append("<div class=\"vwrap\" onclick=\"playVideo(this,'\(absURL)')\"><div class=\"vthumb\" style=\"background-image:url('\(thumbURL)')\"></div><div class=\"vplay\">▶</div><video class=\"v\" controls controlsList=\"nodownload\" disablepictureinpicture playsinline webkit-playsinline preload=\"none\"></video></div>")
            } else {
                imageAbsURLs.append(absURL)
            }
        }
        guard !videoTags.isEmpty || !imageAbsURLs.isEmpty else { throw CosError.missingMedia }

        // 4. 压缩封面（v1.19）：第一张照片压缩成最长边 400px JPEG 上传为 h/<roomKey>/cover（两模式共用）
        var coverSrc = imageAbsURLs.first ?? ""
        if let firstImage = mediaFiles.first(where: { $0.kind == "image" }),
           let coverData = makeCoverJPEG(from: MediaStore.url(for: firstImage.name, roomKey: roomKey)) {
            let coverPath = "h/\(roomKey)/cover"
            do {
                try await upload(data: coverData, to: coverPath, contentType: "image/jpeg", config: config)
                coverSrc = try presignedGetURL(for: coverPath, expires: shareLinkExpires, config: config).absoluteString
            } catch {
                // 封面失败不阻塞：沿用第一张原图
            }
        }

        // 4.1 名片微信二维码（v1.27）：设置页已上传时，压成小图覆盖写到 COS 固定路径 h/_qrcode/qr.jpg；
        //     页面用固定路径签名 URL 引用 → 之后更换二维码，已发出的旧链接也自动显示新图
        var qrSrc = ""
        if hasQR, let qrData = makeQRCodeJPEG() {
            try? await upload(data: qrData, to: "h/_qrcode/qr.jpg", contentType: "image/jpeg", config: config)
            qrSrc = (try? presignedGetURL(for: "h/_qrcode/qr.jpg", expires: shareLinkExpires, config: config).absoluteString) ?? ""
        }

        // 5. 生成并上传分享页（路径无扩展名；两模式独立页面）。链接追加版本参数 v（内容更新 → v 变 → 微信重新抓卡片）
        let pagePath = "h/\(roomKey)/\(mode.pageSuffix)"
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
                coverSrc: coverSrc, qrSrc: qrSrc, shareLink: versionedURL.absoluteString
            )
        case .full:
            let title = "\(info.displayRoomNo) · \(info.layout.isEmpty ? "房源" : info.layout)"
            let desc = "\(info.priceText) · \(info.landlord.isEmpty ? "房东信息见页内" : info.landlord)\n\(name)-\(phone)"
            html = buildFullHTML(
                title: title, desc: desc,
                info: info, name: name, phone: phone,
                videoTags: videoTags, imageURLs: imageAbsURLs,
                coverSrc: coverSrc, qrSrc: qrSrc, shareLink: versionedURL.absoluteString
            )
        }
        try await upload(data: Data(html.utf8), to: pagePath, contentType: "text/html; charset=utf-8", config: config)

        // 6. 更新缓存（按模式分文件；含自定义域名、压缩开关与模板版本，任一变化后旧缓存自动失效）
        ShareCacheStore.save(roomKey: roomKey, mode: mode.rawValue, record: ShareCacheRecord(
            mediaFiles: mediaFiles,
            info: info,
            shareURL: versionedURL.absoluteString,
            bucket: config.bucket,
            region: config.region,
            customDomain: config.customDomain,
            compressOnShare: compressOnShare,
            templateVersion: htmlTemplateVersion,
            qrcodeSet: hasQR
        ))

        return versionedURL
    }

    /// v1.22：多选分享 → 生成【合集 H5 卡片】。一次分享一个链接，好友点开看到 N 套房源列表，
    /// 点某套进入该套详情（视频置顶、图片单列、名片底部）。脱敏/完整两模式各自独立合集页面与缓存。
    /// 缓存：媒体+信息+配置全同 → 零上传复用上次链接；否则全量上传覆盖写（与单套共享媒体对象路径）。
    static func shareCollection(rooms: [ShareCollectionItem], mode: ShareMode, config: CosConfig) async throws -> URL {
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
        let compressOnShare = UserDefaults.standard.bool(forKey: "compressOnShare")
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
           cached.info.name == name,
           cached.info.phone == phone,
           Set(cached.collectionRooms ?? []) == Set(validRooms),
           let url = URL(string: cached.shareURL) {
            return url
        }

        // 1. 上传每套媒体（覆盖写，与单套分享共享 h/<roomKey>/<name> 路径）+ 每套封面
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
                try await upload(data: data, to: remotePath, contentType: contentType, config: config)
                // v1.25：视频同时上传首帧封面图（几十 KB），页面封面用图片而非视频流
                if isVideo, let thumbData = makeVideoThumbJPEG(from: url) {
                    try? await upload(data: thumbData, to: "h/\(item.roomKey)/\(m.name).vthumb.jpg", contentType: "image/jpeg", config: config)
                }
                let absURL = try presignedGetURL(for: remotePath, expires: shareLinkExpires, config: config).absoluteString
                if isVideo {
                    // v1.25：video 无 src、无 poster、无 autoplay；封面用独立首帧图；点击封面 playVideo 才注入 src 并播放
                    let thumbURL = (try? presignedGetURL(for: "h/\(item.roomKey)/\(m.name).vthumb.jpg", expires: shareLinkExpires, config: config).absoluteString) ?? absURL
                    videoTags.append("<div class=\"vwrap\" onclick=\"playVideo(this,'\(absURL)')\"><div class=\"vthumb\" style=\"background-image:url('\(thumbURL)')\"></div><div class=\"vplay\">▶</div><video class=\"v\" controls controlsList=\"nodownload\" disablepictureinpicture playsinline webkit-playsinline preload=\"none\"></video></div>")
                } else {
                    imageAbsURLs.append(absURL)
                }
            }
            var coverSrc = imageAbsURLs.first ?? ""
            if let firstImage = item.mediaFiles.first(where: { $0.kind == "image" }),
               let coverData = makeCoverJPEG(from: MediaStore.url(for: firstImage.name, roomKey: item.roomKey)) {
                let coverPath = "h/\(item.roomKey)/cover"
                do {
                    try await upload(data: coverData, to: coverPath, contentType: "image/jpeg", config: config)
                    coverSrc = try presignedGetURL(for: coverPath, expires: shareLinkExpires, config: config).absoluteString
                } catch {
                }
            }
            prepared.append(PreparedRoom(item: item, videoTags: videoTags, imageURLs: imageAbsURLs, coverSrc: coverSrc))
        }
        guard !prepared.isEmpty else { throw CosError.missingMedia }

        // 2. 生成并上传合集页
        let collectionCover = prepared.first?.coverSrc ?? ""
        // v1.27：名片微信二维码——固定路径覆盖写，旧合集链接自动显示新二维码
        var qrSrc = ""
        if hasQR, let qrData = makeQRCodeJPEG() {
            try? await upload(data: qrData, to: "h/_qrcode/qr.jpg", contentType: "image/jpeg", config: config)
            qrSrc = (try? presignedGetURL(for: "h/_qrcode/qr.jpg", expires: shareLinkExpires, config: config).absoluteString) ?? ""
        }
        let pagePath = "h/_collection/\(sortedKeys).\(mode.pageSuffix)"
        let html = buildCollectionHTML(rooms: prepared, mode: mode, name: name, phone: phone, coverSrc: collectionCover, qrSrc: qrSrc)
        try await upload(data: Data(html.utf8), to: pagePath, contentType: "text/html; charset=utf-8", config: config)

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
            qrcodeSet: hasQR
        ))

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
    private static func buildMaskedHTML(title: String, desc: String, name: String, phone: String, videoTags: [String], imageURLs: [String], coverSrc: String, qrSrc: String, shareLink: String) -> String {
        let mediaBlock = mediaBlockHTML(videoTags: videoTags, imageURLs: imageURLs)
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
        .cellwrap{width:100%;aspect-ratio:4/3;border-radius:10px;overflow:hidden;background-color:#e8e8ec;margin-bottom:10px;cursor:pointer;}
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
        </body>
        </html>
        """
    }

    // MARK: - HTML 模板（v1.21 设计稿定稿：完整版）

    /// 完整版（不隐藏版）：v1.22 信息板块重排为三行——第一行：房号(左) + 户型(右)；第二行：租金 + 密码（密码：xxx）+ 房东（最右）；
    /// 第三行：备注（有才显示，空则整行隐藏）。实拍 → 名片 → 底栏
    private static func buildFullHTML(title: String, desc: String, info: ShareHouseInfo, name: String, phone: String, videoTags: [String], imageURLs: [String], coverSrc: String, qrSrc: String, shareLink: String) -> String {
        let mediaBlock = mediaBlockHTML(videoTags: videoTags, imageURLs: imageURLs)
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
        .cellwrap{width:100%;aspect-ratio:4/3;border-radius:10px;overflow:hidden;background-color:#e8e8ec;margin-bottom:10px;cursor:pointer;}
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

    private static func buildCollectionHTML(rooms: [PreparedRoom], mode: ShareMode, name: String, phone: String, coverSrc: String, qrSrc: String) -> String {
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

            let detail = collectionDetailHTML(item: room.item, mode: mode, videoTags: room.videoTags, imageURLs: room.imageURLs, startIndex: cursor, name: name, phone: phone, qrSrc: qrSrc)
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
        .cellwrap{width:100%;aspect-ratio:4/3;border-radius:10px;overflow:hidden;background-color:#e8e8ec;margin-bottom:10px;cursor:pointer;}
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
        </body>
        </html>
        """
    }

    /// 合集单套详情 HTML：脱敏=户型+导航；完整=房号+户型 / 价格+密码+房东 / 备注。媒体：视频置顶、图片单列。
    /// v1.26：详情底部也加名片（拨打电话/复制电话），与单套分享页一致
    /// v1.27：详情名片同样带微信二维码（真实 <img>，可长按识别）+ 浅蓝底色
    private static func collectionDetailHTML(item: ShareCollectionItem, mode: ShareMode, videoTags: [String], imageURLs: [String], startIndex: Int, name: String, phone: String, qrSrc: String) -> String {
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
            media += "<div class=\"cellwrap\" onclick=\"openImg(\(startIndex + offset))\"><img class=\"cell\" src=\"\(url)\" draggable=\"false\" alt=\"\"></div>"
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
    private static func mediaBlockHTML(videoTags: [String], imageURLs: [String]) -> String {
        var parts: [String] = []
        for tag in videoTags { parts.append(tag) }
        for (index, url) in imageURLs.enumerated() {
            parts.append("<div class=\"cellwrap\" onclick=\"openImg(\(index))\"><img class=\"cell\" src=\"\(url)\" draggable=\"false\" alt=\"\"></div>")
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

    private static func upload(data: Data, to remotePath: String, contentType: String, config: CosConfig) async throws {
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

    /// 从 COS 错误响应 XML 中提取 Error Code 与 Message
    private static func extractCosError(from data: Data) -> String {
        guard let text = String(data: data, encoding: .utf8) else { return "" }
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
    private static func host(for config: CosConfig) -> String {
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
    private static func presignedPutURL(for path: String, contentType: String, config: CosConfig) throws -> URL {
        try presignedURL(for: path, method: "PUT", expires: 3600, headers: [("content-type", contentType)], config: config)
    }

    /// GET 预签名：只签 host（下载/访问链接不带自定义 header）
    private static func presignedGetURL(for path: String, expires: Int, config: CosConfig) throws -> URL {
        try presignedURL(for: path, method: "GET", expires: expires, headers: [], config: config)
    }

    /// COS V5 签名：q-sign-algorithm=sha1;q-ak=...;q-sign-time=...;q-key-time=...;q-header-list=...;q-url-param-list=...;q-signature=...
    /// 关键（严格按 COS 官方规范文档 436/7778 及官方 Python SDK cos_auth.py）：
    /// 1. HttpString = HttpMethod\nUriPathname\nHttpParameters\nHttpHeaders\n —— 恰好 3 个换行分隔 4 段，末尾再一个换行（参数为空时是两个连续换行）
    /// 2. 【根因修复】UriPathname 必须用【未编码】的原样路径参与签名（服务端会用解码后的请求路径重算校验）；
    ///    实际请求 URL 的 path 才做百分号编码
    /// 3. HttpHeaders 的 key 小写、value 按 RFC3986 编码、按字典序拼接
    /// 4. q-header-list 用分号分隔参与签名的 header key
    private static func presignedURL(for path: String, method: String, expires: Int, headers: [(String, String)], config: CosConfig) throws -> URL {
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

        let signKey = HMAC_SHA1(key: config.secretKey, message: keyTime)
        // HttpString 段结构：method\n路径\n参数\n请求头\n（参数为空时是两个连续换行）
        // 路径必须用未编码的 rawPath 参与签名（官方规范），请求 URL 才用 encodedPath
        let httpString = "\(method.lowercased())\n\(rawPath)\n\n\(headerValue)\n"
        let sha1Http = SHA1(hexString: httpString)
        let stringToSign = "sha1\n\(signTime)\n\(sha1Http)\n"
        let signature = HMAC_SHA1(key: signKey, message: stringToSign)

        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = hostValue
        comps.percentEncodedPath = encodedPath
        comps.percentEncodedQuery = "q-sign-algorithm=sha1&q-ak=\(config.secretId)&q-sign-time=\(signTime)&q-key-time=\(keyTime)&q-header-list=\(headerList)&q-url-param-list=&q-signature=\(signature)"
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
