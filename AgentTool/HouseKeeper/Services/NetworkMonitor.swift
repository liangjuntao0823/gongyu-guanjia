import Foundation
import Network

/// v1.39：网络可达性监测（NWPathMonitor 单例，App 启动时首次调用自动启动）。
/// 用途：新增/编辑房源保存前判断是否断网，断网时提示「将仅存本机，联网后可同步云端」。
/// 首次访问 isReachable 时惰性启动监测；路径变化实时刷新，供所有界面读取。
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "net.monitor.queue")
    private var reachable = true
    private var started = false
    private let lock = NSLock()

    private init() {}

    /// 当前网络是否可达（未启动时自动启动；返回最近一次路径状态）
    var isReachable: Bool {
        startIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return reachable
    }

    func startIfNeeded() {
        lock.lock()
        let need = !started
        if need { started = true }
        lock.unlock()
        guard need else { return }
        monitor.pathUpdateHandler = { [weak self] path in
            let ok = (path.status == .satisfied)
            self?.lock.lock()
            self?.reachable = ok
            self?.lock.unlock()
        }
        monitor.start(queue: queue)
    }
}
