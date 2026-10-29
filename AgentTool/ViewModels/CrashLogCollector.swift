import Foundation
import UIKit

// MARK: - v1.12 崩溃日志收集（自建 log 文件 + 设置页导出，暂不上 Crashlytics）
// 捕获未捕获异常（NSSetUncaughtExceptionHandler）与主要信号（SIGABRT/SIGSEGV/SIGBUS/SIGILL/SIGFPE），
// 写入 Documents/备份/Logs/Crash_yyyyMMdd_HHmmss_序号.txt；v1.90 起改为【无限记录】（不再删除旧日志），
// 信号崩溃时用 backtrace_symbols_fd 写入完整调用栈（信号安全），方便定位根因。

enum CrashLogCollector {
    static let logsDirectory: URL = {
        let dir = DataRoot.url().appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static var isInstalled = false

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
        // 主要崩溃信号（handler 内只允许信号安全操作：open/write/backtrace_symbols_fd）
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

    // MARK: - 通用工具（文件命名：不覆盖旧文件，无限保留）

    /// 生成不冲突的新日志文件 URL（epoch 秒 + 递增序号，同秒多次崩溃也各自成文件）
    private static func nextLogURL(prefix: String) -> URL {
        let fm = FileManager.default
        let epoch = Int(Date().timeIntervalSince1970)
        var seq = 1
        while true {
            let name = "\(prefix)_\(epoch)_\(seq).txt"
            let url = logsDirectory.appendingPathComponent(name)
            if !fm.fileExists(atPath: url.path) { return url }
            seq += 1
        }
    }

    /// 写入崩溃日志（异常 handler 调用；只做文件写入，不做高开销操作）
    private static func writeLog(title: String, body: String) {
        let fileURL = nextLogURL(prefix: "Crash")
        let deviceInfo = "设备：\(UIDevice.current.name) | 系统：\(UIDevice.current.systemName) \(UIDevice.current.systemVersion) | App：\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))"
        let content = "时间：\(Date())\n\(deviceInfo)\n\n\(title)\n\(body)\n"
        try? content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// 信号 handler 专用（信号安全：纯 C 接口 open/write/backtrace_symbols_fd，不碰 Foundation/Swift 对象）
    private static func writeLogSignal(_ sig: Int32) {
        let fileURL = nextLogURL(prefix: "Crash_Signal")
        // 头部用 C 接口拼（信号 handler 内避免 Swift 对象分配）
        var t = time(nil)
        var tmRaw = tm()
        localtime_r(&t, &tmRaw)
        var dateBuf = [CChar](repeating: 0, count: 64)
        strftime(&dateBuf, dateBuf.count, "%Y-%m-%d %H:%M:%S", &tmRaw)
        var header = [CChar](repeating: 0, count: 256)
        snprintf(&header, header.count,
                 "时间：%s\n信号：%d (SIGABRT=6, SIGSEGV=11, SIGBUS=10, SIGILL=4, SIGFPE=8)\n调用栈：\n",
                 dateBuf, sig)

        let fd = open(fileURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = write(fd, header, strlen(header))
        // 本线程调用栈（backtrace_symbols_fd 信号安全，直接写描述符）
        let maxFrames = 128
        let frames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: maxFrames)
        defer { frames.deallocate() }
        let count = backtrace(frames, maxFrames)
        if count > 0 {
            backtrace_symbols_fd(frames, count, fd)
        }
        _ = write(fd, "\n", 1)
    }

    /// 全部崩溃日志文件
    static func logFiles() -> [URL] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: logsDirectory.path) else { return [] }
        return names.filter { $0.hasPrefix("Crash") && $0.hasSuffix(".txt") }
            .map { logsDirectory.appendingPathComponent($0) }
            .sorted { a, b in (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast > (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast }
    }

    /// 崩溃日志是否存在
    static func hasLogs() -> Bool { !logFiles().isEmpty }
}
