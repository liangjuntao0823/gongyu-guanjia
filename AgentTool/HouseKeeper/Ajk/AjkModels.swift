//
//  AjkModels.swift
//  公寓管家 · 安居客数据模型（v1.85）
//  来源字段与安居客经纪人后台「全部房源」页一一对应（实测确认）
//

import Foundation

/// 单套房源（从后台卡片解析）
struct AjkHouse: Identifiable, Codable, Equatable {
    var id: String { number }
    let number: String      // 编号（唯一）
    let title: String       // 房源标题
    let community: String   // 小区（如：顺德-龙江，利保米兰公馆）
    let area: String        // 面积（如：40.69平）
    let layout: String      // 户型（如：1室1厅）
    let floor: String       // 楼层（如：10层）
    let price: String       // 租金（如：1200元/月）
    let unifiedPrice: String // 公司统一房价
    let todayClick: Int     // 今日点击（点击量左边；仅内部排序/对比用，列表不再显示 xx/xx）
    let totalClick: Int     // 累计点击（点击量右边）
    let editedDays: Int     // 已编辑 N 天
    let houseStateDays: Int // 房态 N 天（≥7 需实地核验）
    let platforms: [String] // 推广平台（安居客 / 58同城）
    let promotions: [String] // 推广状态（加推/精选/普通推广 —— 位于点击量下方，v1.90 明确提取此字段）
    let verified: String    // 核验状态
    let maintainer: String  // 维护状态
    let video: String       // 视频状态
    let quality: String     // 房源质量
    let page: Int           // 所在页码
    // v1.90：封面图（optional 保证旧数据 houses.json/快照 decode 兼容；空/缺失 = 无封面）
    let coverURL: String?   // 封面图原始 URL（JS 从卡片抓取）
    let coverPath: String?  // 封面图本地文件名（Documents/Ajk/Covers/<number>.jpg；未下载为 nil）

    /// 房态达到预警阈值 → 需实地核验
    func needInspect(threshold: Int) -> Bool {
        houseStateDays >= threshold
    }

    /// 已编辑天数达到下架阈值 → 接近自动下架（页面规则：90 天未编辑自动下架删除）
    func nearRemoval(threshold: Int) -> Bool {
        editedDays >= threshold
    }
}

/// 页面顶部概览
struct AjkOverview: Codable, Equatable {
    var todayClickTotal: Int = 0   // 今日点击（次）
    var promotedCount: Int = 0     // 推广房源（套）
    var portCount: Int = 0         // 剩余端口（个）
    var packageDays: Int = 0       // 套餐剩余（天）
    var score: Int = 0             // 神奇分
    var coin: Int = 0              // 房产币（v1.90）
    var cityRank: Int = 0          // 全城排名
    var totalHouses: Int = 0       // 共找到 N 套房源

    static let empty = AjkOverview()
}

/// 抓取设置（默认值可在安居客设置页修改，不做死）
struct AjkSettings: Codable, Equatable {
    var baseURL: String = "https://vip.anjuke.com/zufang/main/zufang/subpages/allHouse"
    var inspectThreshold: Int = 7    // 房态 ≥ N 天 → 实地核验预警
    var removalThreshold: Int = 90   // 已编辑 ≥ N 天 → 自动下架预警
    var maxPages: Int = 5            // 最大翻页数
    var saveSnapshots: Bool = true   // 保存历史快照

    static let `default` = AjkSettings()
}

/// 历史快照（点击趋势对比，保留最近 30 次）
struct AjkSnapshot: Codable, Equatable {
    let timestamp: Date
    let count: Int
    let totalTodayClick: Int
    let houses: [AjkHouse]
}
