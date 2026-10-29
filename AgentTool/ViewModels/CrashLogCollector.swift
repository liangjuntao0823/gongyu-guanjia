import Foundation
import UIKit

// MARK: - v1.12 崩溃日志收集（自建 log 文件 + 设置页导出，暂不上 Crashlytics）
// 捕获未捕获异常（NSSetUncaughtExceptionHandler）与主要信号（SIGABRT/SIGSEGV/SIGBUS/SIGILL/SIGFPE），
// 写入 Documents/备份/Logs/Crash_yyyyMMdd_HHmmss_序号.txt；v1.90 起改为【无限记录】（不再删除旧日志），
// 信号崩溃时用 backtrace_symbols_fd 写入完整调用栈（信号安全），方便定位根因。
// v1.92：信号 handler 全静态预初始化、执行期零动态分配——上一版在 handler 内 allocate/[CChar] 数组
// 属于 malloc 堆分配（非信号安全），崩溃现场堆损坏时会二次崩溃（Crash_Signal_1_1.txt 栈顶 writeLogSignal）。

enum CrashLogCollector {
    static let logsDirectory: URL = {
        let dir = DataRoot.url().appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static var isInstalled = false
    /// 信号 handler 专用目录路径 C 指针（install 时 strdup 缓存；handler 内只读，纯内存访问信号安全）
    private static var dirPathPtr: UnsafeMutablePointer<CChar>? = nil

    // MARK: - 信号 handler 专用存储（install() 预初始化；handler 内零动态分配）

    /// 日志文件路径缓冲（目录 + /Crash_Signal_ + epoch + _ + seq + .txt，1024 足够）
    private static var sigPathBuf = [CChar](repeating: 0, count: 1024)
    /// 数字字符串缓冲（epoch / seq 手写十进制转换）
    private static var sigNumBuf = [CChar](repeating: 0, count: 24)
    /// 日期缓冲（strftime 输出）
    private static var sigDateBuf = [CChar](repeating: 0, count: 64)
    /// 调用栈帧指针数组（128 帧）
    private static var sigFrames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 128)

    static func install() {
        guard !isInstalled else { return }
        // 信号 handler 只允许信号安全操作：预先把日志目录路径转成 C 字符串缓存（此处是安全上下文）
        dirPathPtr = strdup(logsDirectory.path)
        // 预初始化信号 handler 全部静态缓冲（此后 handler 内不再触发任何 Swift 运行时分配）
        _ = sigPathBuf.count
        _ = sigNumBuf.count
        _ = sigDateBuf.count
        _ = sigFrames
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

    /// 信号 handler 专用（信号安全：纯 C 接口 open/write/backtrace_symbols_fd + 静态缓冲，
    /// 零堆分配/零 Swift 运行时分配；文件名用手写十进制追加构造）
    private static func writeLogSignal(_ sig: Int32) {
        guard let dp = dirPathPtr else { return }
        // 纯 C 构造 /Logs/Crash_Signal_<epoch>_<seq>.txt（O_EXCL 递增序号，不覆盖旧文件）
        _ = strcpy(&sigPathBuf, dp)                 // 目录（install() 已 strdup 缓存）
        _ = strcat(&sigPathBuf, "/Crash_Signal_")
        let epoch: Int64 = Int64(time(nil))
        appendDecimal(pathPtr: &sigPathBuf, numPtr: &sigNumBuf, value: epoch)
        _ = strcat(&sigPathBuf, "_")
        let underscoreLen = strlen(&sigPathBuf)     // "_" 结尾位置，seq 循环从这里追加
        var fd: Int32 = -1
        var seq: Int32 = 1
        while seq < 10000 {
            sigPathBuf[Int(underscoreLen)] = 0      // 截断上一轮 seq 残留
            appendDecimal(pathPtr: &sigPathBuf, numPtr: &sigNumBuf, value: Int64(seq))
            _ = strcat(&sigPathBuf, ".txt")
            fd = open(&sigPathBuf, O_WRONLY | O_CREAT | O_EXCL, 0o644)
            if fd >= 0 { break }
            seq += 1
        }
        guard fd >= 0 else { return }
        defer { close(fd) }
        // 日期：strftime 输出（信号 handler 内避免 Swift 对象/变参函数）
        var t = time(nil)
        var tmRaw = tm()
        localtime_r(&t, &tmRaw)
        strftime(&sigDateBuf, sigDateBuf.count, "%Y-%m-%d %H:%M:%S", &tmRaw)

        writeStaticStr(fd, "时间：")
        _ = write(fd, &sigDateBuf, strlen(&sigDateBuf))
        writeStaticStr(fd, "\n信号：")
        switch sig {
        case SIGABRT: writeStaticStr(fd, "SIGABRT=6")
        case SIGSEGV: writeStaticStr(fd, "SIGSEGV=11")
        case SIGBUS:  writeStaticStr(fd, "SIGBUS=10")
        case SIGILL:  writeStaticStr(fd, "SIGILL=4")
        case SIGFPE:  writeStaticStr(fd, "SIGFPE=8")
        default:      writeStaticStr(fd, "UNKNOWN")
        }
        writeStaticStr(fd, " (SIGABRT=6, SIGSEGV=11, SIGBUS=10, SIGILL=4, SIGFPE=8)\n调用栈：\n")

        // 本线程调用栈（backtrace_symbols_fd 信号安全，直接写描述符；sigFrames 已预初始化）
        let count = backtrace(sigFrames, 128)
        if count > 0 {
            backtrace_symbols_fd(sigFrames, count, fd)
        }
        _ = write(fd, "\n", 1)
    }

    /// 信号 handler 专用：写入静态字符串字面量（non-escaping 闭包，零堆分配）
    @inline(__always)
    private static func writeStaticStr(_ fd: Int32, _ s: StaticString) {
        s.withUTF8Buffer { buf in
            _ = write(fd, buf.baseAddress, buf.count)
        }
    }

    /// 信号 handler 专用：把十进制整数写入 numPtr（数字字符串），再 strcat 到 pathPtr 末尾
    /// （替代 Swift 不可用的 C 变参 snprintf；纯静态缓冲内存操作，零分配）
    @inline(__always)
    private static func appendDecimal(pathPtr: UnsafeMutablePointer<CChar>,
                                      numPtr: UnsafeMutablePointer<CChar>,
                                      value: Int64) {
        var v = value
        var idx = 23
        numPtr[idx] = 0
        if v == 0 {
            idx -= 1
            numPtr[idx] = 48 // '0'
        } else {
            while v > 0 && idx > 0 {
                idx -= 1
                numPtr[idx] = CChar(48 + v % 10)
                v /= 10
            }
        }
        _ = strcat(pathPtr, numPtr + idx)
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
