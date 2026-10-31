//
//  MeterStore.swift
//  公寓管家 · 电表板块本地存储与设置
//  清单文件：Documents/Meters/meters.json（换机/恢复时随备份包还原）
//

import Foundation
import SwiftUI

@MainActor
final class MeterStore: ObservableObject {

    static let shared = MeterStore()

    @Published var meters: [MeterLedger] = []
    @Published var settings: MeterSettings = .default
    @Published var wechatId: String = ""      // 官方接口会话标识（index 接口返回），仅内存使用不落日志

    private let fileURL: URL
    private let settingsURL: URL

    private init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Meters", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("meters.json")
        settingsURL = dir.appendingPathComponent("settings.json")
        load()
    }

    // MARK: - 加载 / 保存

    private func load() {
        do {
            if let data = try? Data(contentsOf: fileURL) {
                meters = try JSONDecoder().decode([MeterLedger].self, from: data)
            }
            if let data = try? Data(contentsOf: settingsURL) {
                settings = try JSONDecoder().decode(MeterSettings.self, from: data)
            }
            if settings.openId.isEmpty, let link = parseOpenId(from: settings.queryLink) {
                settings.openId = link
            }
        } catch {
            // 配置文件损坏则回退默认，不清除用户文件
        }
    }

    func saveMeters() {
        do {
            let data = try JSONEncoder().encode(meters)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // 本地写失败静默，功能继续用内存
        }
    }

    func saveSettings() {
        do {
            let data = try JSONEncoder().encode(settings)
            try data.write(to: settingsURL, options: .atomic)
        } catch {
        }
        // v1.95：设置变化后立即按新开关/间隔重建定时器
        startAutoRefreshIfNeeded()
    }

    // MARK: - v1.95 全局电表盯防定时器
    // 说明：autoRefreshEnabled 开启时，App 前台运行期间按 autoRefreshMinutes 间隔自动刷新电表并保存；
    // iOS 系统限制 App 被杀后无法后台执行——App 下次打开时会立即补刷一次，数据不会长期过期。
    // 配合低电量本地通知（lowAlertEnabled）即可实现「AI 盯电表」的完整闭环。

    private var refreshTimer: Timer?

    /// 按当前设置启动/重启定时器（设置页保存、App 启动时调用）
    func startAutoRefreshIfNeeded() {
        stopAutoRefresh()
        guard settings.autoRefreshEnabled else { return }
        let minutes = max(10, settings.autoRefreshMinutes)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.autoRefreshOnce()
            }
        }
        // 启动即先补刷一次（覆盖 App 被杀期间的缺口）
        Task { @MainActor in
            await self.autoRefreshOnce()
        }
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    /// 静默自动刷新一轮（成功保存，失败等下一轮，不打扰用户），返回成功刷新台数
    @discardableResult
    private func autoRefreshOnce() async -> Int {
        return await refreshNow()
    }

    /// v1.96：AI 工具调用入口——立即刷新全部电表，返回成功台数（0 表示无清单或接口失败）
    @MainActor
    func refreshNow() async -> Int {
        guard !meters.isEmpty else { return 0 }
        let provider: MeterQuerying
        switch settings.provider {
        case .webView: provider = MeterWebViewProvider.shared
        default: provider = MeterQueryService.shared
        }
        do {
            let ok = try await provider.refreshAll(store: self) { _, _, _ in }
            if ok > 0 { saveMeters() }
            return ok
        } catch {
            return 0
        }
    }

    // MARK: - 查询链接（设置页自定义更换入口）

    /// 从官方查询链接中解析 openId（链接形如 http://wy.mlh-china.com/electricmeter/?openId=xxx）
    func parseOpenId(from link: String) -> String? {
        guard let comps = URLComponents(string: link.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return comps.queryItems?.first(where: { $0.name == "openId" })?.value
    }

    func applyQueryLink(_ link: String) {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.queryLink = trimmed
        settings.openId = parseOpenId(from: trimmed) ?? settings.openId
        saveSettings()
    }

    /// 更换微信身份（换微信换链接）时一键清空会话与绑定，避免旧 openId 串数据
    func resetSession() {
        wechatId = ""
        // 保留电表清单（用户号本身不变），仅清会话，下次刷新自动重建会话
        saveSettings()
    }

    // MARK: - 清单操作（电表管理页使用）

    func upsert(_ ledger: MeterLedger) {
        if let idx = meters.firstIndex(where: { $0.uid == ledger.uid }) {
            meters[idx] = ledger
        } else {
            meters.append(ledger)
        }
        saveMeters()
    }

    func remove(uid: String) {
        meters.removeAll { $0.uid == uid }
        saveMeters()
    }

    func updateRoom(uid: String, room: String) {
        guard let idx = meters.firstIndex(where: { $0.uid == uid }) else { return }
        meters[idx].room = room.trimmingCharacters(in: .whitespacesAndNewlines)
        saveMeters()
    }

    func applyQueryResult(uid: String, result: MeterQueryResult) {
        guard let idx = meters.firstIndex(where: { $0.uid == uid }) else { return }
        meters[idx].shengyu = Double(result.shengyu) ?? meters[idx].shengyu
        meters[idx].leiji = Double(result.leiji) ?? meters[idx].leiji
        meters[idx].zhuangtai = result.zhuangtai.isEmpty ? meters[idx].zhuangtai : result.zhuangtai
        meters[idx].shijian = result.shijian.isEmpty ? meters[idx].shijian : result.shijian
        meters[idx].lastRefresh = Date()
        appendHistory(uid: uid, s: meters[idx].shengyu, l: meters[idx].leiji)
        saveMeters()
    }

    /// 用电趋势：每次成功刷新追加一个快照，每户最多保留 200 条（v2.2：原 80；旧数据无 history 字段则初始化）
    private func appendHistory(uid: String, s: Double, l: Double) {
        guard let idx = meters.firstIndex(where: { $0.uid == uid }) else { return }
        var hist = meters[idx].history ?? []
        let now = Date().timeIntervalSince1970
        // 与最后一条间隔过短（< 30 秒）视为同一次刷新，更新该条而非新增
        if let last = hist.last, now - last.t < 30 {
            hist[hist.count - 1] = MeterHistoryPoint(t: now, s: s, l: l)
        } else {
            hist.append(MeterHistoryPoint(t: now, s: s, l: l))
            if hist.count > 200 { hist.removeFirst(hist.count - 200) }
        }
        meters[idx].history = hist
    }

    /// 一键导入：把云端绑定列表（去重、保留备注）并入清单
    func importBindings(_ uids: [String]) {
        var changed = false
        for uid in uids where !uid.isEmpty {
            if !meters.contains(where: { $0.uid == uid }) {
                meters.append(MeterLedger(uid: uid))
                changed = true
            }
        }
        if changed { saveMeters() }
    }

    // MARK: - 低电量提醒（本地通知，每天每户最多一次，防骚扰）

    private let alertDateKey = "meter.lowAlertDate"   // yyyyMMdd，全局每日一次

    func sendLowAlertIfNeeded() {
        guard settings.lowAlertEnabled else { return }
        let center = UNUserNotificationCenter.current()
        let cal = Calendar.current
        let todayKey = { () -> String in
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd"; return f.string(from: Date())
        }()
        let last = UserDefaults.standard.string(forKey: alertDateKey)
        guard last != todayKey else { return }

        let low = meters.filter { $0.isLow(threshold: settings.lowThreshold) }
        let off = meters.filter { $0.isOff }
        guard !low.isEmpty || !off.isEmpty else { return }

        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "电表预警"
            var bodyParts: [String] = []
            if !low.isEmpty {
                let sample = low.prefix(3).map { "\($0.room.isEmpty ? $0.uid : $0.room) \(String(format: "%.1f", $0.shengyu))度" }
                bodyParts.append("低电量 \(low.count) 户：" + sample.joined(separator: "、"))
            }
            if !off.isEmpty {
                let sample = off.prefix(3).map { $0.room.isEmpty ? $0.uid : $0.room }
                bodyParts.append("拉闸 \(off.count) 户：" + sample.joined(separator: "、"))
            }
            content.body = bodyParts.joined(separator: "；") + "。请及时充值。"
            content.userInfo = ["tab": 0]
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            let req = UNNotificationRequest(identifier: "meter.lowAlert", content: content, trigger: trigger)
            center.add(req)
            UserDefaults.standard.set(todayKey, forKey: self.alertDateKey)
        }
    }
}
