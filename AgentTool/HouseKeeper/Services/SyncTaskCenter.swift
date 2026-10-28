import Foundation
import Combine

/// v1.68：全局同步任务中心——同步/媒体补传任务的进度发布中心。
/// 房源页发起同步 → 用户确认后任务在此登记 → 上传进度实时更新：
///   房源页顶部显示进度条（可「最小化」收起，任务继续在后台跑）；
///   「设置 → 待补传媒体」页顶部显示「进行中的同步任务」卡片，随时回来看进度。
@MainActor
final class SyncTaskCenter: ObservableObject {
    static let shared = SyncTaskCenter()

    final class TaskInfo: Identifiable {
        let id = UUID()
        let title: String          // 任务名，如「补齐云端媒体」「补传房源媒体」
        let roomKeys: [String]     // 参与任务的所有套房号（显示用）
        var total: Int             // 总媒体数
        var done: Int = 0          // 已完成媒体数
        var current: String = ""   // 当前正在处理的房号
        // v1.83：当前房号内的文件级进度（本套共几个文件、已处理几个）——解决「进度条卡在一套房分不清是图多还是卡」
        var currentFilesTotal: Int = 0
        var currentFilesDone: Int = 0
        var isRunning: Bool = true
        var success: Bool = false

        init(title: String, roomKeys: [String], total: Int) {
            self.title = title
            self.roomKeys = roomKeys
            self.total = total
        }

        var fraction: Double {
            guard total > 0 else { return 0 }
            return min(Double(done) / Double(total), 1.0)
        }
    }

    @Published var task: TaskInfo?

    /// 开始一个新任务（覆盖旧的已完成任务；进行中的任务不会被覆盖）
    func begin(title: String, roomKeys: [String], total: Int) {
        if let t = task, t.isRunning { return }
        task = TaskInfo(title: title, roomKeys: roomKeys, total: total)
    }

    /// 推进进度（已完成媒体数 + 当前房号）
    func advance(done: Int, current: String) {
        guard let t = task else { return }
        t.done = done
        t.current = current
        objectWillChange.send()
    }

    /// v1.83：推进进度并携带「当前房号内的文件级进度」（filesTotal=本套文件总数，filesDone=本套已处理数）
    func advanceHouse(done: Int, current: String, filesTotal: Int, filesDone: Int) {
        guard let t = task else { return }
        t.done = done
        t.current = current
        t.currentFilesTotal = filesTotal
        t.currentFilesDone = filesDone
        objectWillChange.send()
    }

    /// 标记完成（成功/部分失败），进度置满
    func finish(success: Bool) {
        guard let t = task else { return }
        t.isRunning = false
        t.success = success
        t.done = t.total
        objectWillChange.send()
    }

    /// 清除任务（弹窗关闭后或用户手动关闭）
    func dismiss() {
        task = nil
    }
}
