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

final class MeterQueryService {

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
            struct D: Decodable { let wechatId: String? }
            let code: Int?
            let data: D?
        }
        let body: [String: String] = ["openId": openId]
        let resp: IndexResp = try await post(path: "/kddz/electricmeterpost/index", body: body)
        guard resp.code == 0, let wid = resp.data?.wechatId, !wid.isEmpty else {
            throw MeterQueryError.msg("会话建立失败，请检查查询链接是否仍有效（换微信需更换链接）")
        }
        store.wechatId = wid
    }

    /// 获取当前微信身份下绑定的全部电表用户号（一键导入用）
    func fetchBindings(store: MeterStore) async throws -> [String] {
        try await ensureWechatId(store: store)
        struct ListResp: Decodable {
            struct D: Decodable { let list: [Item]? }
            struct Item: Decodable { let electricUserUid: String? }
            let code: Int?
            let data: D?
        }
        let body: [String: String] = ["wechatUserId": store.wechatId]
        let resp: ListResp = try await post(path: "/kddz/electricmeterpost/getBindList", body: body)
        guard resp.code == 0 else {
            throw MeterQueryError.msg("获取绑定列表失败")
        }
        let list = resp.data?.list?.compactMap { $0.electricUserUid } ?? []
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
            struct D: Decodable { let list: [MeterPayRecord]? }
            let code: Int?
            let data: D?
        }
        let body: [String: String] = ["wechatUserId": store.wechatId, "electricUserUid": uid]
        let resp: RResp = try await post(path: "/kddz/electricmeterpost/electricPayRecordList", body: body)
        guard resp.code == 0 else { throw MeterQueryError.msg("获取充值记录失败（\(uid)）") }
        return resp.data?.list ?? []
    }

    // MARK: - 通用 POST

    private func post<Body: Encodable, Resp: Decodable>(path: String, body: Body) async throws -> Resp {
        guard let url = URL(string: base + path) else { throw MeterQueryError.msg("地址无效") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.wechatUA, forHTTPHeaderField: "User-Agent")
        req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        req.timeoutInterval = timeout
        let data = try JSONEncoder().encode(body)
        req.httpBody = data

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

    // MARK: - 批量刷新（串行 + 限速 + 进度回调 + 失败重试已含在单表 query 内）

    /// 返回成功刷新的台数
    func refreshAll(store: MeterStore, progress: @escaping (Int, Int, String) -> Void) async throws -> Int {
        try await ensureWechatId(store: store)
        var ok = 0
        var lastError: Error?
        for (i, ledger) in store.meters.enumerated() {
            let display = ledger.room.isEmpty ? ledger.uid : ledger.room
            progress(i + 1, store.meters.count, display)
            do {
                let result = try await query(store: store, uid: ledger.uid)
                store.applyQueryResult(uid: ledger.uid, result: result)
                ok += 1
            } catch {
                lastError = error
                // 单台失败继续下一台
            }
            if i < store.meters.count - 1 {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
        store.sendLowAlertIfNeeded()
        if ok == 0, let lastError {
            throw lastError
        }
        return ok
    }
}
