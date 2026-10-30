//
//  MeterQueryService.swift
//  公寓管家 · 电表官方数据查询服务
//  已验证链路（微信 UA 直连，业务接口无签名）：
//    index(openId) → wechatId → getBindList(wechatId) → 用户号列表
//    electricMeterQuery(wechatId, uid) → {shengyu, leiji, zhuangtai, shijian}
//    electricPayRecordList(wechatId, uid) → 充值记录
//  约束：串行查询、单台间隔约 1.5s、失败单台重试一次、openId 不进日志
//

import Foundation

struct MeterQueryError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    static func msg(_ s: String) -> MeterQueryError { MeterQueryError(message: s) }
}

@MainActor
final class MeterQueryService: MeterQuerying {

    static let shared = MeterQueryService()

    /// 微信 UA：服务端校验必须携带，缺则拒绝（普通 UA 直连必失败属已知死路）
    static let wechatUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 MicroMessenger/8.0.38(0x1800262b) NetType/WIFI Language/zh_CN"

    private let base = "http://wy.mlh-china.com"
    private let interval: TimeInterval = 1.2   // 串行限速，防风控
    private let timeout: TimeInterval = 12

    // MARK: - 会话

    /// 换取会话 wechatId（openId 不写日志）
    func ensureWechatId(store: MeterStore) async throws {
        if !store.wechatId.isEmpty { return }
        let openId = store.settings.openId
        guard !openId.isEmpty else {
            throw MeterQueryError.msg("未配置电表查询链接，请在设置中粘贴微信查询链接")
        }
        struct IndexResp: Decodable {
            struct D: Decodable { let wechatId: Int? }
            let code: Int?
            let data: D?
        }
        let body: [String: String] = ["openId": openId]
        let resp: IndexResp = try await post(path: "/kddz/electricmeterpost/index", body: body)
        guard resp.code == 0, let wid = resp.data?.wechatId else {
            throw MeterQueryError.msg("会话建立失败，请检查查询链接是否仍有效（换微信需更换链接）")
        }
        store.wechatId = String(wid)
    }

    /// 获取当前微信身份下绑定的全部电表用户号（一键导入用）
    func fetchBindings(store: MeterStore) async throws -> [String] {
        try await ensureWechatId(store: store)
        struct ListResp: Decodable {
            struct Item: Decodable { let bindMeterId: String? }
            let code: Int?
            let data: [Item]?
        }
        let body: [String: String] = ["wechatUserId": store.wechatId]
        let resp: ListResp = try await post(path: "/kddz/electricmeterpost/getBindList", body: body)
        guard resp.code == 0 else {
            throw MeterQueryError.msg("获取绑定列表失败")
        }
        let list = resp.data?.compactMap { $0.bindMeterId } ?? []
        guard !list.isEmpty else { throw MeterQueryError.msg("当前微信身份下没有绑定电表") }
        return list
    }

    // MARK: - 单表查询（带一次重试）

    func query(store: MeterStore, uid: String) async throws -> MeterQueryResult {
        try await ensureWechatId(store: store)
        do {
            return try await queryOnce(store: store, uid: uid)
        } catch {
            // 失败单台重试一次（间隔限速后重试）
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            return try await queryOnce(store: store, uid: uid)
        }
    }

    private func queryOnce(store: MeterStore, uid: String) async throws -> MeterQueryResult {
        struct QResp: Decodable {
            struct D: Decodable {
                let shengyu: String?
                let leiji: String?
                let zhuangtai: String?
                let shijian: String?
                let querycode: String?
            }
            let code: Int?
            let data: D?
        }
        let body: [String: String] = ["wechatUserId": store.wechatId, "electricUserUid": uid]
        let resp: QResp = try await post(path: "/kddz/electricmeterpost/electricMeterQuery", body: body)
        guard resp.code == 0, let d = resp.data else {
            throw MeterQueryError.msg("查询失败（\(uid)）")
        }
        return MeterQueryResult(shengyu: d.shengyu ?? "0", leiji: d.leiji ?? "0",
                                zhuangtai: d.zhuangtai ?? "合闸", shijian: d.shijian ?? "")
    }

    // MARK: - 充值记录

    func payRecords(store: MeterStore, uid: String) async throws -> [MeterPayRecord] {
        try await ensureWechatId(store: store)
        struct RResp: Decodable {
            let code: Int?
            let data: [MeterPayRecord]?
        }
        let body: [String: String] = ["wechatUserId": store.wechatId, "electricUserUid": uid]
        let resp: RResp = try await post(path: "/kddz/electricmeterpost/electricPayRecordList", body: body)
        guard resp.code == 0 else { throw MeterQueryError.msg("获取充值记录失败（\(uid)）") }
        return resp.data ?? []
    }

    // MARK: - 通用 POST（官方接口只认 application/x-www-form-urlencoded 表单格式）

    private func post<Resp: Decodable>(path: String, body: [String: String]) async throws -> Resp {
        guard let url = URL(string: base + path) else { throw MeterQueryError.msg("地址无效") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.wechatUA, forHTTPHeaderField: "User-Agent")
        req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        req.setValue("http://wy.mlh-china.com", forHTTPHeaderField: "Origin")
        req.timeoutInterval = timeout
        // 官方接口只认表单格式：键值用 URLComponents 编码为 query 串作 body
        var comps = URLComponents()
        comps.queryItems = body.map { URLQueryItem(name: $0.key, value: $0.value) }
        req.httpBody = comps.query?.data(using: .utf8)

        let (respData, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw MeterQueryError.msg("服务响应异常")
        }
        // 服务端偶发非 JSON 内容，先探测再解析
        guard let json = String(data: respData, encoding: .utf8), json.hasPrefix("{") else {
            throw MeterQueryError.msg("响应格式异常")
        }
        return try JSONDecoder().decode(Resp.self, from: respData)
    }

    // MARK: - 批量刷新（实测校准 + 倍速选择，失败表自动重建会话后串行慢速补刷兜底）
    // 2026-10-30 服务端实测（32 台表）：串行1.5s≈85s / 串行1.0s≈72s / 并发3路0.3s≈70s /
    // 并发4路0.25s≈44s / 并发8路0.1s≈14s，均 32/32 全成功；连续两轮不失败 → 服务端不硬限流并发。
    // 「总刷新全失败」根因是会话 wechatId 过期后未自动重建（App 缓存会话，过期后所有查询返回失败）。
    // 兜底：第一轮失败的表 → 清空并重建会话 → 串行 1.2s/台 慢速补刷（单台仍含一次重试）。
    // 倍速档位即时生效：设置页选择后立即写入 MeterSettings.refreshSpeed，本次及以后刷新都按新档位执行。

    /// 返回成功刷新的台数
    func refreshAll(store: MeterStore, progress: @escaping (Int, Int, String) -> Void) async throws -> Int {
        try await ensureWechatId(store: store)
        let all = store.meters
        guard !all.isEmpty else { return 0 }

        // 倍速档位：0=一台一台刷(原版串行1.5s/台) 1=标准(并发3路0.3s) 2=快速(并发4路0.25s,默认) 3=极速(并发8路0.1s)
        let speed = store.settings.refreshSpeed
        let concurrency: Int
        let stagger: UInt64
        switch speed {
        case 0: concurrency = 1; stagger = 1_500_000_000 // 一台一台刷=原版串行 1.5s/台
        case 1: concurrency = 3; stagger = 300_000_000
        case 3: concurrency = 8; stagger = 100_000_000
        default: concurrency = 4; stagger = 250_000_000
        }

        var ok = 0
        var failedUIDs: [String] = []
        let failedLock = NSLock()
        var lastError: Error?
        await withTaskGroup(of: Int.self) { group in
            for (i, ledger) in all.enumerated() {
                group.addTask { [self] in
                    // 交错启动，避免并发请求同一瞬间发出
                    try? await Task.sleep(nanoseconds: UInt64(i) * stagger)
                    do {
                        let result = try await self.query(store: store, uid: ledger.uid)
                        await MainActor.run {
                            store.applyQueryResult(uid: ledger.uid, result: result)
                        }
                        return 1
                    } catch {
                        failedLock.lock()
                        failedUIDs.append(ledger.uid)
                        failedLock.unlock()
                        lastError = error
                        return 0
                    }
                }
            }
            var completed = 0
            for await r in group {
                ok += r
                completed += 1
                progress(completed, all.count, "已完成 \(completed)/\(all.count)")
            }
        }

        // 第二轮兜底：有失败 → 重建会话（wechatId 过期是「全失败」最常见根因）→ 串行 1.2s 慢速补刷
        if !failedUIDs.isEmpty {
            let failCount = failedUIDs.count
            progress(all.count - failCount, all.count, "\(failCount) 台失败，正在重建会话补刷…")
            store.wechatId = ""
            try await ensureWechatId(store: store)
            var retried = 0
            for (i, uid) in failedUIDs.enumerated() {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                do {
                    let result = try await query(store: store, uid: uid)
                    await MainActor.run {
                        store.applyQueryResult(uid: uid, result: result)
                    }
                    retried += 1
                } catch {
                    lastError = error
                }
                progress(all.count - failCount + i + 1, all.count, "补刷 \(i + 1)/\(failCount)")
            }
            ok += retried
        }

        store.sendLowAlertIfNeeded()
        if ok == 0, let lastError {
            throw lastError
        }
        return ok
    }
}
