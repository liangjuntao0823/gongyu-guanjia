//
//  AjkParser.swift
//  公寓管家 · 安居客页面文本解析（v1.85）
//  输入：JS 注入收集的原始文本（空格归一）；输出：结构化房源 + 概览
//

import Foundation

enum AjkParser {

    /// 解析一页卡片文本 + 概览文本
    static func parse(overview: String, cards: [String], page: Int) -> (houses: [AjkHouse], overview: AjkOverview) {
        parse(overview: overview, cards: cards, covers: [:], page: page)
    }

    /// 解析一页卡片文本 + 封面 URL 表 + 概览文本
    static func parse(overview: String, cards: [String], covers: [String: String], page: Int) -> (houses: [AjkHouse], overview: AjkOverview) {
        var houses: [AjkHouse] = []
        for card in cards {
            if let h = parseCard(card, covers: covers, page: page) {
                houses.append(h)
            }
        }
        // 按编号去重（翻页时防重复收集）
        var seen = Set<String>()
        houses = houses.filter { seen.insert($0.number).inserted }
        return (houses, parseOverview(overview))
    }

    // MARK: - 单卡解析

    static func parseCard(_ text: String, page: Int) -> AjkHouse? {
        parseCard(text, covers: [:], page: page)
    }

    static func parseCard(_ text: String, covers: [String: String], page: Int) -> AjkHouse? {
        guard let numMatch = text.range(of: #"编号:(\d+)"#, options: .regularExpression) else { return nil }
        let number = String(text[numMatch]).replacingOccurrences(of: "编号:", with: "")

        var title = ""
        var community = ""
        // 小区：形如「顺德-龙江，利保米兰公馆」
        if let cRange = text.range(of: #"[\u4e00-\u9fa5]{2,6}-[\u4e00-\u9fa5]{2,8}，[\u4e00-\u9fa5]+"#, options: .regularExpression) {
            community = String(text[cRange])
            // 标题 = 小区之前的文本（去掉前缀标签）
            let before = String(text[..<cRange.lowerBound])
            title = cleanTitle(before)
        } else {
            // 无小区格式时：标题取"编号:"前去掉前缀后的第一段
            let before = String(text[..<numMatch.lowerBound])
            title = cleanTitle(before)
        }

        // 面积/户型/楼层/租金：形如「40.69平，1室1厅，10层，1200元/月」
        var area = "", layout = "", floor = "", price = ""
        if let m = text.range(of: #"(\d+\.?\d*平)，(\d+室\d+厅[^，]*?)，(\d+层)，(\d+元/月)"#, options: .regularExpression) {
            let s = String(text[m])
            let parts = s.components(separatedBy: "，")
            if parts.count >= 4 {
                area = parts[0]
                layout = parts[1]
                floor = parts[2]
                price = parts[3]
            }
        }

        // 统一房价
        var unified = ""
        if let u = text.range(of: #"公司统一房价[:：]?\s*(\d+元/月)"#, options: .regularExpression) {
            unified = String(text[u]).replacingOccurrences(of: #"公司统一房价[:：]?\s*"#, with: "", options: .regularExpression)
        }

        // 点击量：第一个「数字/数字」（今日/累计）
        var today = 0, total = 0
        if let c = text.range(of: #"(\d+)/(\d+)"#, options: .regularExpression) {
            let pair = String(text[c]).split(separator: "/")
            if pair.count == 2 {
                today = Int(pair[0]) ?? 0
                total = Int(pair[1]) ?? 0
            }
        }

        // 已编辑天数
        var edited = 0
        if let e = text.range(of: #"已编辑[:：]?(\d+)天"#, options: .regularExpression) {
            let s = String(text[e])
            if let d = s.range(of: #"\d+"#, options: .regularExpression) {
                edited = Int(s[d]) ?? 0
            }
        }

        // 房态天数
        var stateDays = 0
        if let f = text.range(of: #"房态(\d+)天"#, options: .regularExpression) {
            let s = String(text[f])
            if let d = s.range(of: #"\d+"#, options: .regularExpression) {
                stateDays = Int(s[d]) ?? 0
            }
        }

        // 推广平台 / 推广类型
        var platforms: [String] = []
        if text.contains("安居客") { platforms.append("安居客") }
        if text.contains("58同城") { platforms.append("58同城") }
        // 推广状态（v1.91：准确数据在点击量左侧——「平台 + 推广类型」逐平台精确提取，
        // 例：『安居客 普通推广 精选 58同城 普通推广 精选 11/11』→ 安居客·普通推广·精选 / 58同城·普通推广·精选）
        var promotions: [String] = []
        let promoTypeWords = ["普通推广", "精选", "加推", "免费推", "置顶",
                              "智能营销助手", "低至9.8折", "占领商圈", "优先曝光", "首发推广"]
        let promoPlatforms = ["安居客", "58同城"].filter { text.contains($0) }
        for (idx, pname) in promoPlatforms.enumerated() {
            guard let pRange = text.range(of: pname) else { continue }
            var segEnd = text.endIndex
            if idx + 1 < promoPlatforms.count, let nextR = text.range(of: promoPlatforms[idx + 1]) {
                segEnd = nextR.lowerBound
            } else if let clickR = text.range(of: #"\d+/\d+"#, options: .regularExpression) {
                segEnd = clickR.lowerBound
            }
            let seg = text[pRange.upperBound..<segEnd]
            var types: [String] = []
            for w in promoTypeWords where seg.contains(w) { types.append(w) }
            if !types.isEmpty {
                promotions.append("\(pname)·" + types.joined(separator: "·"))
            }
        }

        // 核验状态
        var verified = "未核验"
        if text.contains("核验成功") { verified = "实地核验·核验成功" }
        else if text.contains("实地核验") { verified = "实地核验（未成功）" }

        // 维护状态
        var maintainer = ""
        if text.contains("可抢维护") { maintainer = "可抢维护" }
        else if text.contains("维护人") { maintainer = "维护人" }

        // 视频状态
        var video = ""
        if text.contains("视频通过:达标") || text.contains("视频通过：达标") { video = "视频达标" }
        else if text.contains("视频未达标") { video = "视频未达标" }
        else if text.contains("暂无视频上传") { video = "暂无视频" }

        // 质量
        var quality = ""
        if text.contains("房源质量:高") || text.contains("房源质量：高") { quality = "高" }
        else if text.contains("房源质量:中") || text.contains("房源质量：中") { quality = "中" }
        else if text.contains("房源质量:低") || text.contains("房源质量：低") { quality = "低" }
        else if text.contains("质量评估中") { quality = "评估中" }

        return AjkHouse(number: number, title: title, community: community, area: area,
                        layout: layout, floor: floor, price: price, unifiedPrice: unified,
                        todayClick: today, totalClick: total, editedDays: edited, houseStateDays: stateDays,
                        platforms: platforms, promotions: promotions, verified: verified,
                        maintainer: maintainer, video: video, quality: quality, page: page,
                        coverURL: covers[number], coverPath: nil)
    }

    /// 去掉前缀标签，返回标题文本
    private static func cleanTitle(_ raw: String) -> String {
        var t = raw
        let tags = ["质量评估中", "房源质量:高", "房源质量：高", "房源质量:中", "房源质量：中", "房源质量:低", "房源质量：低",
                    "推荐推广", "问题图片", "图片质量差", "实拍核验", "业主自荐", "必看好房", "新上架", "急租", "置顶"]
        for tag in tags {
            t = t.replacingOccurrences(of: tag, with: "")
        }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        // 标题通常以「整租/合租」开头；若清理后仍为空，取编号前最后一段
        return t
    }

    // MARK: - 概览解析

    static func parseOverview(_ text: String) -> AjkOverview {
        var o = AjkOverview.empty
        if let m = firstInt(text, pattern: #"(\d+)\s*次\s*今日点击"#) { o.todayClickTotal = m }
        if let m = firstInt(text, pattern: #"(\d+)\s*套\s*推广房源"#) { o.promotedCount = m }
        if let m = firstInt(text, pattern: #"(\d+)\s*个\s*剩余端口"#) { o.portCount = m }
        if let m = firstInt(text, pattern: #"套餐剩余(\d+)天"#) { o.packageDays = m }
        // v1.90：神奇分放宽（页面可能是「神奇分96分」「神奇分:96」「神奇分 96」），新增房产币
        if let m = firstInt(text, pattern: #"神奇分[:：]?\s*(\d+)"#) { o.score = m }
        // v1.91：神奇分/房产币改从工作台首页抓取——「总分 889分」「房产币 3,134.11」（含千分位逗号）
        if let m = firstInt(text, pattern: #"总分\s*(\d+)分"#) { o.score = m }
        if let cr = text.range(of: #"房产币\s*([\d,]+)"#, options: .regularExpression) {
            let s = String(text[cr])
            if let d = s.range(of: #"[\d,]+"#, options: .regularExpression) {
                let digits = String(s[d]).replacingOccurrences(of: ",", with: "")
                o.coin = Int(digits) ?? 0
            }
        }
        if let m = firstInt(text, pattern: #"全城排名[:：]?\s*(\d+)"#) { o.cityRank = m }
        if let m = firstInt(text, pattern: #"共找到\s*(\d+)\s*套房源"#) { o.totalHouses = m }
        return o
    }

    private static func firstInt(_ text: String, pattern: String) -> Int? {
        guard let r = text.range(of: pattern, options: .regularExpression) else { return nil }
        let s = String(text[r])
        guard let d = s.range(of: #"\d+"#, options: .regularExpression) else { return nil }
        return Int(s[d])
    }
}
