import Foundation
import Network

/// v1.39：网络可达性监测（NWPathMonitor 单例，App 启动时首次调用自动启动）。
/// 用途：新增/编辑房源保存前判断是否断网，断网时提示「将仅存本机，联网后可同步云端」。
/// v1.42：修复「完全断网仍判在线」——此前 reachable 初始值 true 且依赖异步回调，
///        保存瞬间回调未完成时读到初始 true，导致断网保存没有任何提示。
///        现改为直接读 NWPathMonitor.currentPath（同步拿到当前真实状态），
///        监测未就绪时一律按「离线」处理（宁可多提示，不可漏提示）。
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "net.monitor.queue")
    private var started = false
    private let lock = NSLock()

    private init() {}

    /// 当前网络是否可达：直接读 currentPath 当前状态（无需等异步回调）。
    /// 监测未启动或路径未生效时返回 false（按离线处理）。
    var isReachable: Bool {
        startIfNeeded()
        let path = monitor.currentPath
        return path.status == .satisfied
    }

    /// v1.66：保存/同步等主动动作的网络确认——NWPathMonitor 刚启动或路径切换瞬间，
    /// currentPath 可能短暂非 .satisfied（误报离线，用户「取消再保存就好了」就是这种瞬态）。
    /// 先立即读一次，非可达则短时轮询等待路径就绪（最多 timeout 秒），仍不可达才判定离线。
    func awaitReachable(timeout: TimeInterval = 1.2) async -> Bool {
        if isReachable { return true }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 150_000_000)
            if monitor.currentPath.status == .satisfied { return true }
        }
        return false
    }

    func startIfNeeded() {
        lock.lock()
        let need = !started
        if need { started = true }
        lock.unlock()
        guard need else { return }
        monitor.pathUpdateHandler = { _ in
            // 状态由 currentPath 实时读取，回调仅用于保持监测活跃；无需缓存旧值
        }
        monitor.start(queue: queue)
    }
}
