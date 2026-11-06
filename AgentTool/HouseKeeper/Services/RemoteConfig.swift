import Foundation
import CryptoKit

// MARK: - v1.80 远程配置中心
/// 三级兜底：云端 config.json（COS 桶根，权威）→ 本地缓存（Documents/Config/config_cache.json）→ 代码内置默认值
/// 联网时 App 启动 / 每次云端同步成功调用 refresh() 拉取最新并更新缓存；
/// 断网时读本地缓存；首次安装无缓存时用内置默认值（= 与现状完全一致）。
/// 后台可视化编辑入口：云端后台「远程配置」页（云函数 config_save 写桶根 config.json）。
enum RemoteConfig {
    struct Announcement: Codable {
        var enabled: Bool
        var text: String
        var link: String?
    }
    /// v1.89：AI 模型清单（云端扩展，登录火山方舟抓取账号已开通模型后由后台写入；与本地内置合并展示）
    struct AIModelInfo: Codable, Identifiable, Hashable {
        var id: String { modelID }
        var modelID: String
        var name: String
        var desc: String
    }
    struct ChangelogEntry: Codable, Identifiable {
        var id: String { version + (date ?? "") }
        var version: String
        var date: String?
        var changes: [String]
    }
    struct Payload: Codable {
        var version: Int = 0
        var updatedAt: String?
        var updatedBy: String?
        var announcement: Announcement?
        var minimumVersion: String?
        var tips: [String: String] = [:]
        var features: [String: Bool] = [:]
        var params: [String: Double] = [:]
        var helpTexts: [String: String] = [:]
        var changelog: [ChangelogEntry]?
        var aiModels: [AIModelInfo]? = nil
        /// v2.21：App 在线更新（云端后台「App 更新」填写；桶里只存最新一个包）
        var update: UpdateInfo? = nil
    }

    /// v2.21：App 更新信息（云端 config.json 的 update 块）
    struct UpdateInfo: Codable, Equatable {
        var latestVersion: String?
        var latestBuild: Int?
        var releasedAt: String?
        var sizeBytes: Int?
        var notes: [String]?
        /// 桶内对象路径（优先），如 update/公寓管家2.21-b144.ipa
        var objectKey: String?
        /// 备用 https 直链（objectKey 为空时使用）
        var downloadURL: String?
        /// 第三方签名平台安装页（填了才出现「去安装页」按钮）
        var installPageURL: String?
        var sha256: String?
    }

    private static var _current = Payload()
    static var current: Payload { _current }

    /// 配置缓存目录：Documents/Config/（随「备份」体系一起被文件 App 备份）
    private static var cacheDir: URL {
        let dir = DataRoot.url().appendingPathComponent("Config", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private static var cacheURL: URL { cacheDir.appendingPathComponent("config_cache.json") }

    /// App 启动时读取本地缓存（断网可用）
    static func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let p = try? JSONDecoder().decode(Payload.self, from: data) else { return }
        _current = p
    }

    /// v1.81 原生后台保存成功后调用：写入内存 + 本地缓存（断网兜底）
    static func apply(_ p: Payload) {
        _current = p
        if let data = try? JSONEncoder().encode(p) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }

    /// 拉取云端最新配置并更新缓存（联网时调用：App 启动 + 每次云端同步成功后）
    /// v2.21：改为返回是否拉取成功（在线更新检查要用它区分「已是最新」与「连不上云端」）
    @discardableResult
    static func refresh() async -> Bool {
        guard let config = CosConfig.load() else { return false }
        do {
            let url = try CosUploader.presignedGetURL(for: "config.json", expires: 300, config: config)
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            if http.statusCode == 404 { return false }   // 云端未配置：保持默认/缓存
            guard (200...299).contains(http.statusCode) else { return false }
            let p = try JSONDecoder().decode(Payload.self, from: data)
            _current = p
            try? Data(data).write(to: cacheURL, options: .atomic)
            return true
        } catch {
            // 拉取失败：保留本地缓存或内置默认
            return false
        }
    }

    // MARK: - 便捷读取（内置默认兜底，未配置时与 v1.79 行为完全一致）

    static func tip(_ key: String, _ fallback: String) -> String {
        _current.tips[key] ?? fallback
    }
    static func feature(_ key: String, _ fallback: Bool) -> Bool {
        _current.features[key] ?? fallback
    }
    static func param(_ key: String, _ fallback: Double) -> Double {
        _current.params[key] ?? fallback
    }
    static func help(_ key: String, _ fallback: String) -> String {
        _current.helpTexts[key] ?? fallback
    }
    static var announcement: Announcement? { _current.announcement }
    static var minimumVersion: String? {
        let v = _current.minimumVersion ?? ""
        return v.isEmpty ? nil : v
    }
    static var changelog: [ChangelogEntry]? { _current.changelog }
    /// 云端扩展的 AI 模型清单（可能为空；与 App 内置合并展示）
    static var aiModels: [AIModelInfo] { _current.aiModels ?? [] }

    /// 配置概览（设置页显示：版本 + 更新时间）
    static var summary: String {
        let ver = _current.version
        let updated = _current.updatedAt ?? "未同步"
        return "版本 \(ver) · 更新于 \(updated)"
    }
}

// MARK: - v2.21 App 在线更新（检查 → 提示 → 下载 → 签名工具安装）

/// 更新检查中心：数据全部来自云端 config.json 的 update 块（复用启动已有的配置拉取，不额外发请求）
@MainActor
final class UpdateCenter: ObservableObject {
    static let shared = UpdateCenter()

    struct Available: Equatable, Identifiable {
        var id: String { "\(version)-\(build)" }
        var version: String
        var build: Int
        var releasedAt: String
        var sizeBytes: Int
        var notes: [String]
        var objectKey: String
        var downloadURL: String
        var installPageURL: String
        var sha256: String
    }

    enum CheckState: Equatable { case idle, checking, upToDate, failed }

    @Published private(set) var available: Available?
    @Published private(set) var checkState: CheckState = .idle
    @Published private(set) var lastCheckedAt: Date?

    private static let lastCheckKey = "update.lastCheckAt"
    private static let autoCheckKey = "update.autoCheckEnabled"

    /// 每次启动自动检查（默认开）
    static var autoCheckEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: autoCheckKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: autoCheckKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: autoCheckKey) }
    }

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
    static var appBuild: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0") ?? 0
    }

    private static func parts(_ v: String) -> [Int] {
        v.split(separator: ".").map { Int($0) ?? 0 }
    }

    /// 版本号按段比较（2.9 < 2.10），同一版本再比 build
    static func isNewer(version: String, build: Int) -> Bool {
        let a = parts(version)
        let b = parts(appVersion)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return build > appBuild
    }

    /// 从当前配置重算「有没有新版本」
    func evaluate() {
        guard let info = RemoteConfig.current.update else { available = nil; return }
        let v = (info.latestVersion ?? "").trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty, Self.isNewer(version: v, build: info.latestBuild ?? 0) else {
            available = nil
            return
        }
        var notes = (info.notes ?? []).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if notes.isEmpty {
            let cloud = RemoteConfig.changelog ?? []
            if let hit = cloud.first(where: { $0.version == v || $0.version == "v\(v)" }) {
                notes = hit.changes
            }
        }
        available = Available(
            version: v,
            build: info.latestBuild ?? 0,
            releasedAt: info.releasedAt ?? "",
            sizeBytes: info.sizeBytes ?? 0,
            notes: notes,
            objectKey: info.objectKey ?? "",
            downloadURL: info.downloadURL ?? "",
            installPageURL: info.installPageURL ?? "",
            sha256: info.sha256 ?? ""
        )
    }

    /// 每次进 App 都跑一次（冷启动）
    func checkOnLaunch() async {
        await runCheck()
    }

    /// 设置页「检查更新」手动触发
    func checkManually() async {
        await runCheck()
    }

    private func runCheck() async {
        checkState = .checking
        let ok = await RemoteConfig.refresh()
        evaluate()
        if available != nil {
            checkState = .idle
        } else {
            checkState = ok ? .upToDate : .failed
        }
        lastCheckedAt = Date()
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
    }

    /// 回前台节流检查（6 小时内不重复联网）
    @MainActor
    static func checkIfDue() {
        guard autoCheckEnabled else { return }
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        guard Date().timeIntervalSince1970 - last > 6 * 3600 else { return }
        Task { await UpdateCenter.shared.runCheck() }
    }
}

/// 安装包下载器：桶内取（优先）或直链下载 → 存到 Documents/Updates/ → 可选 sha256 校验
@MainActor
final class UpdateDownloader: ObservableObject {
    enum Phase: Equatable {
        case idle, downloading, verifying, ready, failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress: Double = 0
    @Published private(set) var localURL: URL?

    private var task: URLSessionDownloadTask?
    private var timer: Timer?

    var isBusy: Bool {
        if case .downloading = phase { return true }
        if case .verifying = phase { return true }
        return false
    }

    func start(_ update: UpdateCenter.Available) {
        guard !isBusy else { return }
        var url: URL?
        if !update.objectKey.isEmpty, let config = CosConfig.load(), config.isValid {
            url = try? CosUploader.presignedGetURL(for: update.objectKey, expires: 3600, config: config)
        }
        if url == nil, !update.downloadURL.isEmpty {
            url = URL(string: update.downloadURL)
        }
        guard let finalURL = url else {
            phase = .failed("云端还没有安装包，请在后台填 objectKey 或 downloadURL")
            return
        }

        phase = .downloading
        progress = 0
        let t = URLSession.shared.downloadTask(with: finalURL) { [weak self] tmp, resp, err in
            Task { @MainActor in
                self?.finish(tmp: tmp, response: resp, error: err, update: update)
            }
        }
        task = t
        t.resume()

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            let p = t.progress.fractionCompleted
            Task { @MainActor in
                guard let self else { return }
                if case .downloading = self.phase { self.progress = p }
            }
        }
    }

    private func finish(tmp: URL?, response: URLResponse?, error: Error?, update: UpdateCenter.Available) {
        timer?.invalidate()
        timer = nil
        if let error {
            phase = .failed("下载失败：\(error.localizedDescription)")
            return
        }
        guard let tmp else {
            phase = .failed("下载失败：没有拿到文件")
            return
        }
        phase = .verifying

        let name = update.objectKey.isEmpty
            ? "公寓管家\(update.version).ipa"
            : (update.objectKey as NSString).lastPathComponent
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Updates", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: tmp, to: dest)
        } catch {
            phase = .failed("保存失败：\(error.localizedDescription)")
            return
        }

        if !update.sha256.isEmpty, let data = try? Data(contentsOf: dest) {
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if hash.lowercased() != update.sha256.lowercased() {
                try? FileManager.default.removeItem(at: dest)
                phase = .failed("安装包校验失败（文件可能不完整），请重新下载")
                return
            }
        }

        localURL = dest
        progress = 1
        phase = .ready
    }
}
