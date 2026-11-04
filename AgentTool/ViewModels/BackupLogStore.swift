import Foundation

// MARK: - v1.12 操作日志（幂等与校验：每次备份/恢复/上传/同步记录 时间/类型/结果/校验和）
// 本地 UserDefaults 存储（v1.13 需求8：只保留最近一个月；上限 200 条），设置页可查看。

struct BackupLogEntry: Codable, Hashable {
    var date: Date
    var category: String     // 备份 / 恢复 / 上传 / 删除 / 同步 / 房源 / 成交 / 收租 / 水电 ...
    var action: String       // 快速备份 / 全量备份 / 恢复完成 / 上传成功 等
    var result: String       // 成功 / 失败
    var detail: String       // 统计摘要 / 错误信息
    var checksum: String     // sha1（zip 或 JSON 数据），失败时为空
    var username: String?    // v1.19：操作者用户名（云端/多用户操作显示是谁）
}

enum BackupLogStore {
    private static let key = "backupLogs.v1"
    private static let maxCount = 500
    /// v1.13 需求8：日志只保留最近 30 天；v1.19 需求：改为 45 天
    private static let retentionDays = 45

    static func all() -> [BackupLogEntry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([BackupLogEntry].self, from: data) else { return [] }
        return list.sorted { $0.date > $1.date }
    }

    static func log(category: String, action: String, result: String, detail: String = "", checksum: String = "", username: String? = nil, cloud: Bool = false) {
        // v2.7（P1⑦ 跨账号日志公共区）：云端操作同时写本地日志——
        // 此前 cloud:true 直接 return 不写本地，导致本机日志区只有 cloud:false 的操作，
        // 跨账号同步回来的别人操作本机完全看不到。现在本机日志始终完整，云端日志区拉公共区。
        if cloud {
            CloudOps.log(category: category, action: action, result: result, detail: detail)
        }
        var list = all()
        let name = username ?? CloudUser.username
        list.insert(BackupLogEntry(date: Date(), category: category, action: action, result: result, detail: detail, checksum: checksum,
                                   username: name.isEmpty ? nil : name), at: 0)
        // v1.13 需求8：超过保留天数的日志自动清理
        let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) ?? Date()
        list = list.filter { $0.date >= cutoff }
        if list.count > maxCount { list = Array(list.prefix(maxCount)) }
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// v1.19：日志占用空间（字节），设置页展示用
    static func sizeBytes() -> Int {
        UserDefaults.standard.data(forKey: key)?.count ?? 0
    }

    /// v1.37：删除指定日志（操作日志左滑 / 多选删除）
    static func remove(_ entry: BackupLogEntry) {
        var list = all()
        list.removeAll { $0 == entry }
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

