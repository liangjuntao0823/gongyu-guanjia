//
//  AjkStore.swift
//  公寓管家 · 安居客数据本地存储与设置（v1.85）
//  清单文件：Documents/Ajk/houses.json + settings.json + snapshots.json
//  数据来源：用户已登录态下、用户主动触发的一次性抓取（只读，不做任何后台轮询）
//

import Foundation
import SwiftUI

@MainActor
final class AjkStore: ObservableObject {

    static let shared = AjkStore()

    @Published var houses: [AjkHouse] = []
    @Published var overview: AjkOverview = .empty
    @Published var settings: AjkSettings = .default
    @Published var lastFetch: Date?
    @Published var snapshots: [AjkSnapshot] = []   // 历史快照（点击趋势对比）

    private let fileURL: URL
    private let settingsURL: URL
    private let snapshotsURL: URL

    /// Keychain 中 API Key 的账号键（AI 功能使用；安居客抓取不需要 Key）
    static let apiKeyAccount = "ai.volcengine.apiKey"
    static let aiModelAccount = "ai.model"

    private init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ajk", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("houses.json")
        settingsURL = dir.appendingPathComponent("settings.json")
        snapshotsURL = dir.appendingPathComponent("snapshots.json")
        load()
    }

    // MARK: - 加载 / 保存

    private func load() {
        do {
            if let data = try? Data(contentsOf: fileURL) {
                houses = try JSONDecoder().decode([AjkHouse].self, from: data)
            }
            if let data = try? Data(contentsOf: settingsURL) {
                settings = try JSONDecoder().decode(AjkSettings.self, from: data)
            }
            if let data = try? Data(contentsOf: snapshotsURL) {
                snapshots = try JSONDecoder().decode([AjkSnapshot].self, from: data)
            }
        } catch {
            // 配置损坏回退默认，不清用户文件
        }
    }

    func saveHouses() {
        do {
            let data = try JSONEncoder().encode(houses)
            try data.write(to: fileURL, options: .atomic)
        } catch { }
    }

    func saveSettings() {
        do {
            let data = try JSONEncoder().encode(settings)
            try data.write(to: settingsURL, options: .atomic)
        } catch { }
    }

    func saveSnapshots() {
        do {
            let data = try JSONEncoder().encode(snapshots)
            try data.write(to: snapshotsURL, options: .atomic)
        } catch { }
    }

    // MARK: - 抓取结果落地

    func applyFetch(houses: [AjkHouse], overview: AjkOverview) {
        self.houses = houses.sorted { $0.todayClick != $1.todayClick ? $0.todayClick > $1.todayClick : $0.totalClick > $1.totalClick }
        self.overview = overview
        self.lastFetch = Date()
        saveHouses()

        // v1.90：后台下载封面图（Documents/Ajk/Covers/<number>.jpg，失败静默，不阻塞主流程）
        downloadCovers()

        // 快照留存（点击趋势对比）：保留最近 30 次
        if settings.saveSnapshots {
            let snap = AjkSnapshot(timestamp: Date(), count: houses.count, totalTodayClick: overview.todayClickTotal, houses: houses)
            snapshots.append(snap)
            if snapshots.count > 30 { snapshots.removeFirst(snapshots.count - 30) }
            saveSnapshots()
        }
    }

    // MARK: - 封面图（v1.90）

    /// 封面图本地目录
    static var coversDirectory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ajk", isDirectory: true)
            .appendingPathComponent("Covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 封面本地文件 URL（按编号）
    static func coverFileURL(for number: String) -> URL {
        coversDirectory.appendingPathComponent("\(number).jpg")
    }

    /// 后台串行下载全部缺失封面；下载完成后触发 UI 刷新（封面显示只看本地文件是否存在）
    private func downloadCovers() {
        let toDownload = houses.filter { !($0.coverURL ?? "").isEmpty && !FileManager.default.fileExists(atPath: Self.coverFileURL(for: $0.number).path) }
        guard !toDownload.isEmpty else { return }
        Task.detached {
            for house in toDownload {
                guard let url = URL(string: house.coverURL ?? "") else { continue }
                do {
                    let (data, _) = try await URLSession.shared.data(from: url)
                    try data.write(to: Self.coverFileURL(for: house.number), options: .atomic)
                    await MainActor.run { self.objectWillChange.send() }
                } catch {
                    // 单张失败不重试（可能是防盗链/临时网络），保持无封面占位
                }
            }
        }
    }

    /// 编号的封面本地路径（存在才返回，供列表显示）
    func coverLocalPath(for number: String) -> String? {
        let url = Self.coverFileURL(for: number)
        return FileManager.default.fileExists(atPath: url.path) ? url.path : nil
    }

    /// 与最近一次快照对比今日点击增量（用于分析文案）
    func clickDelta(house: AjkHouse) -> Int {
        guard let prev = snapshots.dropLast().last?.houses.first(where: { $0.id == house.id }) else { return 0 }
        return house.todayClick - prev.todayClick
    }

    /// 需要实地核验的房源（房态 ≥ 阈值，默认 7 天，设置页可改）
    var needInspectHouses: [AjkHouse] {
        houses.filter { $0.needInspect(threshold: settings.inspectThreshold) }
            .sorted { $0.houseStateDays > $1.houseStateDays }
    }

    /// 接近自动下架的房源（已编辑天数 ≥ 阈值，默认 90 天，设置页可改）
    var nearRemovalHouses: [AjkHouse] {
        houses.filter { $0.nearRemoval(threshold: settings.removalThreshold) }
            .sorted { $0.editedDays > $1.editedDays }
    }
}
