import Foundation
import UIKit

// MARK: - v1.12 崩溃日志收集（自建 log 文件 + 设置页导出，暂不上 Crashlytics）
// 捕获未捕获异常（NSSetUncaughtExceptionHandler）与主要信号（SIGABRT/SIGSEGV/SIGBUS/SIGILL/SIGFPE），
// 写入 Documents/备份/Logs/Crash_yyyyMMdd_HHmmss.txt；保留最近 5 份，设置页可导出分享。

enum CrashLogCollector {
    static let logsDirectory: URL = {
        let dir = DataRoot.url().appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static var isInstalled = false
    private static let maxFiles = 5

    static func install() {
        guard !isInstalled else { return }
        isInstalled = true
        NSSetUncaughtExceptionHandler { exception in
            let name = exception.name.rawValue
            let reason = exception.reason ?? ""
            let stack = exception.callStackSymbols.joined(separator: "\n")
            CrashLogCollector.writeLog(
                title: "Uncaught Exception: \(name)",
                body: "原因：\(reason)\n\n调用栈：\n\(stack)"
            )
        }
        // 主要崩溃信号（handler 内只允许信号安全操作：open/write/darwin 接口）
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE] {
            signal(sig) { signalValue in
                CrashLogCollector.writeLogSignal(signalValue)
                signal(signalValue, SIG_DFL)
                raise(signalValue)
            }
        }
    }

    /// v1.83：可预期的致命错误（数据库双重初始化失败、视图上下文缺失等）在 fatalError/温和降级前主动留痕，
    /// 供下次启动提示「上次异常退出」并可在设置页导出定位。与系统 crash handler 独立，保证必写成功。
    static func logFatal(title: String, body: String) {
        writeLog(title: title, body: body)
    }

    /// 写入崩溃日志（异常 handler 调用；只做文件写入，不做高开销操作）
    private static func writeLog(title: String, body: String) {
        let fm = FileManager.default
        // 轮转：保留最近 maxFiles 份
        if let names = try? fm.contentsOfDirectory(atPath: logsDirectory.path) {
            let crashFiles = names.filter { $0.hasPrefix("Crash_") && $0.hasSuffix(".txt") }.sorted()
            if crashFiles.count >= maxFiles {
                for old in crashFiles.prefix(crashFiles.count - maxFiles + 1) {
                    try? fm.removeItem(at: logsDirectory.appendingPathComponent(old))
                }
            }
        }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd_HHmmss"
        let fileURL = logsDirectory.appendingPathComponent("Crash_\(fmt.string(from: Date())).txt")
        let deviceInfo = "设备：\(UIDevice.current.name) | 系统：\(UIDevice.current.systemName) \(UIDevice.current.systemVersion) | App：\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))"
        let content = "时间：\(Date())\n\(deviceInfo)\n\n\(title)\n\(body)\n"
        try? content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// 信号 handler 专用（信号安全：避免 Foundation 高开销，直接写字符串）
    private static func writeLogSignal(_ sig: Int32) {
        let fm = FileManager.default
        if let names = try? fm.contentsOfDirectory(atPath: logsDirectory.path) {
            let crashFiles = names.filter { $0.hasPrefix("Crash_") && $0.hasSuffix(".txt") }.sorted()
            if crashFiles.count >= maxFiles {
                for old in crashFiles.prefix(crashFiles.count - maxFiles + 1) {
                    try? fm.removeItem(at: logsDirectory.appendingPathComponent(old))
                }
            }
        }
        let timestamp = "\(Int(Date().timeIntervalSince1970))"
        let fileURL = logsDirectory.appendingPathComponent("Crash_Signal_\(timestamp).txt")
        let content = "时间：\(Date())\n信号：\(sig)（SIGABRT=6, SIGSEGV=11, SIGBUS=10, SIGILL=4, SIGFPE=8）\n"
        try? content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// 全部崩溃日志文件
    static func logFiles() -> [URL] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: logsDirectory.path) else { return [] }
        return names.filter { $0.hasPrefix("Crash_") && $0.hasSuffix(".txt") }
            .map { logsDirectory.appendingPathComponent($0) }
            .sorted { a, b in (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast > (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast }
    }

    /// 崩溃日志是否存在
    static func hasLogs() -> Bool { !logFiles().isEmpty }
}
