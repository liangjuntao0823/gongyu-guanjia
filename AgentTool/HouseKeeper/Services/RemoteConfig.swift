import Foundation

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
    static func refresh() async {
        guard let config = CosConfig.load() else { return }
        do {
            let url = try CosUploader.presignedGetURL(for: "config.json", expires: 300, config: config)
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return }
            if http.statusCode == 404 { return }   // 云端未配置：保持默认/缓存
            guard (200...299).contains(http.statusCode) else { return }
            let p = try JSONDecoder().decode(Payload.self, from: data)
            _current = p
            try? data.write(to: cacheURL, options: .atomic)
        } catch {
            // 拉取失败：保留本地缓存或内置默认
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

    /// 配置概览（设置页显示：版本 + 更新时间）
    static var summary: String {
        let ver = _current.version
        let updated = _current.updatedAt ?? "未同步"
        return "版本 \(ver) · 更新于 \(updated)"
    }
}
