//
//  MeterModels.swift
//  公寓管家 · 电表监控数据模型
//  纯自用：仅读取展示官方电表数据（余额/累计/状态/抄表时间），不涉及任何充值资金逻辑
//

import Foundation

/// 一台电表的本地产量数据（清单 + 最近一次查询结果）
struct MeterLedger: Codable, Identifiable, Equatable {
    var id: String { uid }
    var uid: String          // 电表用户号（官方 electricUserUid）
    var room: String         // 备注房号（空 = 未绑定，列表第一行不显示）
    var shengyu: Double      // 剩余电量（度）
    var leiji: Double        // 累计用量（度）
    var zhuangtai: String    // 合闸 / 拉闸
    var shijian: String      // 最新抄表时间（原始字符串，如 2026-10-28 14:39:22）
    var lastRefresh: Date?   // 本机最后成功刷新时间
    var history: [MeterHistoryPoint]?   // 用电趋势快照（每次成功刷新追加，旧数据无此字段兼容解码）

    init(uid: String, room: String = "", shengyu: Double = 0, leiji: Double = 0,
         zhuangtai: String = "合闸", shijian: String = "", lastRefresh: Date? = nil,
         history: [MeterHistoryPoint]? = nil) {
        self.uid = uid
        self.room = room
        self.shengyu = shengyu
        self.leiji = leiji
        self.zhuangtai = zhuangtai
        self.shijian = shijian
        self.lastRefresh = lastRefresh
        self.history = history
    }

    var isOff: Bool { zhuangtai == "拉闸" }
    func isLow(threshold: Double) -> Bool { !isOff && shengyu < threshold }
}

/// 用电趋势单点：时间戳 + 剩余电量 + 累计用量
struct MeterHistoryPoint: Codable, Equatable {
    let t: TimeInterval   // 记录时间（Unix 秒）
    let s: Double         // 剩余电量
    let l: Double         // 累计用量
}

/// 官方返回的单表查询结果（electricMeterQuery）
struct MeterQueryResult: Codable {
    let shengyu: String
    let leiji: String
    let zhuangtai: String
    let shijian: String
}

/// 官方返回的充值记录（electricPayRecordList 单条）
struct MeterPayRecord: Codable, Identifiable, Equatable {
    var id: Int { paymentId }
    let paymentId: Int
    let paymentOrder: String
    let paymentCreateDate: String
    let paymentPayMoney: String
    let paymentPayDate: String
    let paymentPayStuts: String
    let paymentMeterId: String

    /// 状态 1 = 支付成功
    var paid: Bool { paymentPayStuts == "1" }
    var amountText: String { "¥" + paymentPayMoney }
}

/// 电表数据源方案（设置页可切换）
enum MeterProviderKind: String, Codable, CaseIterable {
    case direct = "direct"      // 直连官方接口（默认，已验证无签名，仅需微信 UA）
    case webView = "webview"    // WebView 页面环境执行接口（官方只放行页面请求时的兜底）
    var label: String {
        switch self {
        case .direct: return "直连接口（推荐）"
        case .webView: return "网页抓取（兜底）"
        }
    }
}

/// 电表数据源统一协议：直连与 WebView 兜底共用同一出口
@MainActor
protocol MeterQuerying {
    func fetchBindings(store: MeterStore) async throws -> [String]
    func refreshAll(store: MeterStore, progress: @escaping (Int, Int, String) -> Void) async throws -> Int
    func query(store: MeterStore, uid: String) async throws -> MeterQueryResult
    func payRecords(store: MeterStore, uid: String) async throws -> [MeterPayRecord]
}

/// 电表板块设置（本地持久化 + 随备份迁移）
struct MeterSettings: Codable {
    var queryLink: String = ""      // 电表查询链接（用户可自定义更换，解析出 openId）
    var openId: String = ""         // 从链接解析出的微信身份
    var provider: MeterProviderKind = .direct
    var lowThreshold: Double = 30   // 低电量阈值（度），默认 30，可自行输入
    var autoRefreshMinutes: Int = 30 // 定时自动刷新间隔（分钟），默认 30
    var autoRefreshEnabled: Bool = false // 定时刷新开关，默认关
    var lowAlertEnabled: Bool = true  // 低电量本地通知提醒，默认开

    static let `default` = MeterSettings()
}
