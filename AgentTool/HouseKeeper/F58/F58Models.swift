//
//  F58Models.swift
//  公寓管家 · 58同城找房数据模型（v2.1 b108）
//  来源字段与 58 同城顺德站租房列表页（m 站手机版，iPhone UA，关键词 key 生效）卡片对应（实测确认）
//  安全边界：只读 58 公开租房列表页，仅采集标题/缩略图/价格/位置四类信息；不做任何写操作
//

import Foundation

/// 单套房源（58 列表卡片解析）
struct F58House: Identifiable, Codable, Equatable {
    var id: String { infoid }
    let infoid: String      // 房源 ID（详情 URL 内数字，唯一）
    let title: String       // 房源标题
    let href: String        // 详情页 URL（点卡片加载 = 浏览器点击该房源）
    let coverURL: String    // 缩略图 URL（58 CDN）
    let coverPath: String?  // 缩略图本地文件名（Documents/F58/Covers/<infoid>.jpg；未下载为 nil）
    let price: String       // 租金数字（元/月 由 UI 拼接）
    let room: String        // 户型+面积（如 1室 34.23㎡）
    let loc: String         // 区域 + 小区
    /// 经纪公司（v2.2：列表页无经纪人，由详情页补抓；如 佛山市用心选房房地产经纪有限公司）
    var agentDp: String
    /// 经纪人姓名（v2.2：详情页补抓；如 李文斌）
    var agentName: String
    let tip: String         // 标签（安选）
    let ad: String          // 广告标（广告）

    /// 经纪人展示名（公司 + 人名）
    var agent: String {
        var parts: [String] = []
        if !agentDp.isEmpty { parts.append(agentDp) }
        if !agentName.isEmpty { parts.append(agentName) }
        return parts.joined(separator: " ")
    }

    /// 经纪人姓名（详情页补抓失败时回退：agent 内第一个非公司词；空则 "—"）
    var agentDisplay: String {
        if !agentName.isEmpty { return agentName }
        if !agentDp.isEmpty { return agentDp }
        return "—"
    }

    /// 租金数值（用于统计均价/最高/最低；解析失败返回 nil）
    var priceValue: Int? {
        Int(price.filter { $0.isNumber })
    }
}

/// 抓取设置（可在 58找房设置页修改，不做死）
struct F58Settings: Codable, Equatable {
    /// 完整列表页 URL（默认：利保米兰公馆 · m 站手机版。58 手机站对手机浏览器风控宽松、key 关键词生效；
    /// 手机版列表不含经纪人字段，详情页可看；URL 里带 reform=pcfront 会被自动剥离）
    var baseURL: String = "https://m.58.com/sd/zufang/?key=%E5%88%A9%E4%BF%9D%E7%B1%B3%E5%85%B0%E5%85%AC%E9%A6%86"
    /// 关键词（仅用于显示标题）
    var keyword: String = "利保米兰公馆"

    static let `default` = F58Settings()
}

/// 抓取结果概览（从本次数据现算，不落盘）
struct F58Overview {
    var count: Int = 0        // 房源套数
    var agentCount: Int = 0   // 经纪人（按姓名去重）位数
    /// 按经纪人展示房源数量排名（v2.2：姓名 → 套数，倒序）
    var agentRank: [(name: String, count: Int)] = []
    // —— 以下字段 v2.2 起顶栏不再展示（需求：删均价/广告位），保留兼容旧引用 ——
    var avgPrice: Int = 0
    var minPrice: Int = 0
    var maxPrice: Int = 0
    var adCount: Int = 0
}
