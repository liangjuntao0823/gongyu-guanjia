import Foundation

// MARK: - v1.12 操作日志（幂等与校验：每次备份/恢复/上传/同步记录 时间/类型/结果/校验和）
// 本地 UserDefaults 存储（上限 200 条，先进先出），设置页可查看。

struct BackupLogEntry: Codable {
    var date: Date
    var category: String     // 备份 / 恢复 / 上传 / 删除 / 同步
    var action: String       // 快速备份 / 全量备份 / 恢复完成 / 上传成功 等
    var result: String       // 成功 / 失败
    var detail: String       // 统计摘要 / 错误信息
    var checksum: String     // sha1（zip 或 JSON 数据），失败时为空
}

enum BackupLogStore {
    private static let key = "backupLogs.v1"
    private static let maxCount = 200

    static func all() -> [BackupLogEntry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([BackupLogEntry].self, from: data) else { return [] }
        return list.sorted { $0.date > $1.date }
    }

    static func log(category: String, action: String, result: String, detail: String = "", checksum: String = "") {
        var list = all()
        list.insert(BackupLogEntry(date: Date(), category: category, action: action, result: result, detail: detail, checksum: checksum), at: 0)
        if list.count > maxCount { list = Array(list.prefix(maxCount)) }
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

// MARK: - SyncCore 联动（跨端同步后记录日志）
// SyncCore 完成 push/pull 后通过 Notification 通知本模块记录，避免侵入同步协议核心。

extension Notification.Name {
    static let backupSyncCompleted = Notification.Name("backupSyncCompleted")
    static let backupSyncFailed = Notification.Name("backupSyncFailed")
}

enum BackupSyncLogBridge {
    static func install() {
        NotificationCenter.default.addObserver(forName: .backupSyncCompleted, object: nil, queue: .main) { note in
            let info = note.userInfo ?? [:]
            let uploaded = info["uploaded"] as? Int ?? 0
            let downloaded = info["downloaded"] as? Int ?? 0
            let conflicts = info["conflicts"] as? Int ?? 0
            BackupLogStore.log(category: "同步", action: "跨端同步", result: "成功", detail: "上送 \(uploaded) 条 / 拉取 \(downloaded) 条 / 冲突 \(conflicts) 条")
        }
        NotificationCenter.default.addObserver(forName: .backupSyncFailed, object: nil, queue: .main) { note in
            let detail = (note.userInfo?["detail"] as? String) ?? ""
            BackupLogStore.log(category: "同步", action: "跨端同步", result: "失败", detail: detail)
        }
    }
}
