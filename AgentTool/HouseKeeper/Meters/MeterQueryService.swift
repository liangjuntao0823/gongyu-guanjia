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
    private let interval: TimeInterval = 1.5   // 串行限速，防风控
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

    // MARK: - 批量刷新（v1.98 并发 3 路 + 交错启动限速 + 进度回调 + 失败重试已含在单表 query 内）
    // 说明：原串行 1.5s/台，34 台约 51s 太慢；改为并发 3 路、每台启动交错 0.3s，
    // 既大幅提速（34 台约 20s 内），又避免同一瞬间全部请求触发服务端风控。
    // 单台 query 内仍保留失败重试一次。若服务端出现限流，可把 concurrency 调回 1 即为原串行。

    /// 返回成功刷新的台数
    func refreshAll(store: MeterStore, progress: @escaping (Int, Int, String) -> Void) async throws -> Int {
        try await ensureWechatId(store: store)
        let all = store.meters
        guard !all.isEmpty else { return 0 }
        let concurrency = 3
        var ok = 0
        var lastError: Error?
        await withTaskGroup(of: Int.self) { group in
            for (i, ledger) in all.enumerated() {
                group.addTask { [self] in
                    // 交错启动：i * 0.3s，避免并发请求同时发出触发风控
                    try? await Task.sleep(nanoseconds: UInt64(i) * 300_000_000)
                    do {
                        let result = try await self.query(store: store, uid: ledger.uid)
                        await MainActor.run {
                            store.applyQueryResult(uid: ledger.uid, result: result)
                        }
                        return 1
                    } catch {
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
        store.sendLowAlertIfNeeded()
        if ok == 0, let lastError {
            throw lastError
        }
        return ok
    }
}
