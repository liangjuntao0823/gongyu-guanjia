//
//  F58Models.swift
//  公寓管家 · 58同城找房数据模型（v1.99 b105）
//  来源字段与 58 同城顺德站租房列表页（reform=pcfront PC 前端）卡片一一对应（实测确认）
//  安全边界：只读 58 公开租房列表页，仅采集标题/缩略图/价格/经纪人四类信息；不做任何写操作
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
    let agentDp: String     // 经纪公司（如 一米公寓）
    let agentName: String   // 经纪人姓名（如 颜家康）
    let tip: String         // 标签（安选）
    let ad: String          // 广告标（广告）

    /// 经纪人展示名（公司 + 人名）
    var agent: String {
        var parts: [String] = []
        if !agentDp.isEmpty { parts.append(agentDp) }
        if !agentName.isEmpty { parts.append(agentName) }
        return parts.joined(separator: " ")
    }

    /// 租金数值（用于统计均价/最高/最低；解析失败返回 nil）
    var priceValue: Int? {
        Int(price.filter { $0.isNumber })
    }
}

/// 抓取设置（可在 58找房设置页修改，不做死）
struct F58Settings: Codable, Equatable {
    /// 完整列表页 URL（默认：利保米兰公馆 · reform=pcfront PC 前端，含经纪人字段）
    var baseURL: String = "https://m.58.com/sd/zufang/?key=%E5%88%A9%E4%BF%9D%E7%B1%B3%E5%85%B0%E5%85%AC%E9%A6%86&reform=pcfront"
    /// 关键词（仅用于显示标题）
    var keyword: String = "利保米兰公馆"

    static let `default` = F58Settings()
}

/// 抓取结果概览（从本次数据现算，不落盘）
struct F58Overview {
    var count: Int = 0        // 房源套数
    var agentCount: Int = 0   // 经纪人（公司+人名去重）位数
    var avgPrice: Int = 0     // 均价（元/月）
    var minPrice: Int = 0     // 最低
    var maxPrice: Int = 0     // 最高
    var adCount: Int = 0      // 广告位套数
}
