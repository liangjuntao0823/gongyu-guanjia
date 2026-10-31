//
//  F58Store.swift
//  公寓管家 · 58同城找房数据本地存储与设置（v1.99 b105）
//  清单文件：Documents/F58/houses.json + settings.json
//  数据来源：用户主动点击「读取」的一次性抓取（只读，不做任何后台轮询）
//

import Foundation
import SwiftUI

@MainActor
final class F58Store: ObservableObject {

    static let shared = F58Store()

    @Published var houses: [F58House] = []
    @Published var settings: F58Settings = .default
    @Published var lastFetch: Date?

    private let fileURL: URL
    private let settingsURL: URL

    private init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("F58", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("houses.json")
        settingsURL = dir.appendingPathComponent("settings.json")
        load()
    }

    // MARK: - 加载 / 保存

    private func load() {
        if let data = try? Data(contentsOf: fileURL),
           let list = try? JSONDecoder().decode([F58House].self, from: data) {
            houses = list
        }
        if let data = try? Data(contentsOf: settingsURL),
           let s = try? JSONDecoder().decode(F58Settings.self, from: data) {
            settings = s
        }
    }

    func saveHouses() {
        if let data = try? JSONEncoder().encode(houses) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            try? data.write(to: settingsURL, options: .atomic)
        }
    }

    // MARK: - 抓取结果落地（v2.2：接详情页经纪人补抓进度）

    /// 详情页经纪人补抓进度（current/total；nil = 未开始）
    @Published var detailProgress: (current: Int, total: Int)?

    func applyFetch(houses: [F58House]) {
        self.houses = houses
        self.lastFetch = Date()
        saveHouses()
        downloadCovers()
        detailProgress = nil
    }

    func fetch() async {
        let provider = F58WebViewProvider.shared
        provider.onDetailProgress = { [weak self] cur, total in
            self?.detailProgress = (cur, total)
        }
        do {
            let result = try await provider.fetchFirstPage(urlString: settings.baseURL)
            if result.needCaptcha {
                detailProgress = nil
                lastError = "58 弹出验证码校验，请稍后重试（连续出现可在设置里更换关键词或稍后再试）"
                return
            }
            if !result.error.isEmpty {
                detailProgress = nil
                lastError = result.error
                return
            }
            applyFetch(houses: result.houses)
        } catch {
            detailProgress = nil
            lastError = error.localizedDescription
        }
    }

    /// 最近一次错误（UI 提示用）
    @Published var lastError: String?

    // MARK: - 缩略图（参考安居客封面机制）

    static var coversDirectory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("F58", isDirectory: true)
            .appendingPathComponent("Covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func coverFileURL(for infoid: String) -> URL {
        coversDirectory.appendingPathComponent("\(infoid).jpg")
    }

    /// 后台串行下载全部缺失缩略图；单张失败静默（保持无图占位），下载完成触发 UI 刷新
    private func downloadCovers() {
        let toDownload = houses.filter {
            !$0.coverURL.isEmpty && !FileManager.default.fileExists(atPath: Self.coverFileURL(for: $0.infoid).path)
        }
        guard !toDownload.isEmpty else { return }
        let dir = Self.coversDirectory
        Task.detached {
            for house in toDownload {
                guard let url = URL(string: house.coverURL) else { continue }
                do {
                    let (data, _) = try await URLSession.shared.data(from: url)
                    try data.write(to: dir.appendingPathComponent("\(house.infoid).jpg"), options: .atomic)
                    await MainActor.run { self.objectWillChange.send() }
                } catch {
                    // 单张失败不重试（可能是防盗链/临时网络），保持无图占位
                }
            }
        }
    }

    func coverLocalPath(for infoid: String) -> String? {
        let url = Self.coverFileURL(for: infoid)
        return FileManager.default.fileExists(atPath: url.path) ? url.path : nil
    }

    // MARK: - 概览（从本次数据现算）

    var overview: F58Overview {
        var o = F58Overview()
        o.count = houses.count
        var agents: Set<String> = []
        var prices: [Int] = []
        for h in houses {
            agents.insert(h.agentDisplay)
            if let p = h.priceValue { prices.append(p) }
            if !h.ad.isEmpty { o.adCount += 1 }
        }
        o.agentCount = agents.count
        o.agentRank = agentList
        if !prices.isEmpty {
            o.minPrice = prices.min() ?? 0
            o.maxPrice = prices.max() ?? 0
            o.avgPrice = prices.reduce(0, +) / prices.count
        }
        return o
    }

    /// 经纪人排名（v2.2：按经纪人姓名计数倒序；姓名全空的极端情况回退按公司名）
    var agentList: [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for h in houses where !h.agentName.isEmpty {
            counts[h.agentName, default: 0] += 1
        }
        if counts.isEmpty {
            for h in houses where !h.agentDp.isEmpty {
                counts[h.agentDp, default: 0] += 1
            }
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { ($0.key, $0.value) }
    }
}
