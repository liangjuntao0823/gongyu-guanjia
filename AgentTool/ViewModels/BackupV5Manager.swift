import Foundation
import SwiftData
import CryptoKit
import UIKit

// MARK: - v1.12 备份体系 v2：快照 v5（统一快照格式）
// 一份快照 = 经营 JSON + 房源 JSON + 媒体指纹清单（schemaVersion 4 → 5，兼容旧版备份导入）。
// 备份分两类：
//   · 快速备份（fast）：快照 zip（不含媒体文件本体），自动/手动均可用，自动上传云端
//   · 全量备份（full）：快照 zip + media/ 全部原文件，手动上传云端（可增量）
// 命名：快速_2026年10月22日15时30分.zip / 全量_xxx.zip（自动备份后缀 _自动；同分钟冲突追加 -2）
// 恢复：校验 → 安全快照（现有数据打包到 PreRestore/）→ 导入 → 分行统计 → 成功删安全快照；失败用安全快照回滚。

enum BackupKindV5: String, Codable {
    case fast = "fast"
    case full = "full"

    var label: String {
        switch self {
        case .fast: return "快速备份"
        case .full: return "全量备份"
        }
    }
    var shortLabel: String {
        switch self {
        case .fast: return "快速"
        case .full: return "全量"
        }
    }
}

struct BackupManifestV5: Codable {
    var schemaVersion: Int = 5
    var kind: String
    var isAuto: Bool
    var createdAt: String
    var appVersion: String
    var appBuild: String
    var deviceName: String
}

/// 媒体指纹清单（快速/全量都带；恢复全量时按清单核对文件，缺失的从云端拉取）
struct MediaFingerprintV5: Codable {
    var roomKey: String
    var fileName: String
    var kind: String
    var size: Int64
    var sha1: String
}

/// 房源导出 DTO（快照 houses.json）
struct HouseExportDTO: Codable {
    struct MediaDTO: Codable {
        var id: UUID
        var fileName: String
        var kind: String
    }
    var id: UUID
    var roomNo: String
    var tower: Int
    var landlord: String
    var layout: String
    var price: Int
    var password: String
    var remark: String
    var statusRaw: String
    var createdAt: Date
    var updatedAt: Date
    var isDeleted: Bool?
    var deletedAt: Date?
    var mediaItems: [MediaDTO]
}

struct HouseBundleDTO: Codable {
    var schemaVersion: Int
    var houses: [HouseExportDTO]
}

/// 恢复完成分行统计（用户锁定口径）
struct RestoreStatsV5 {
    var deals: Int = 0          // 成交
    var incomes: Int = 0        // 杂项收入
    var expenses: Int = 0       // 杂项支出
    var renting: Int = 0        // 在租
    var terminated: Int = 0     // 退租
    var payouts: Int = 0        // 包租
    var todosOpen: Int = 0      // 待办
    var todosDone: Int = 0      // 已办
    var houses: Int = 0         // 有效房源
    var photos: Int = 0         // 照片
    var videos: Int = 0         // 视频

    var summaryLines: [String] {
        [
            "成交 \(deals) 条",
            "杂项收入 \(incomes) 条",
            "杂项支出 \(expenses) 条",
            "在租 \(renting) 条",
            "退租 \(terminated) 条",
            "包租 \(payouts) 条",
            "待办 \(todosOpen) 条",
            "已办 \(todosDone) 条",
            "有效房源 \(houses) 套",
            "照片合计 \(photos) 张",
            "视频合计 \(videos) 个"
        ]
    }
}

enum BackupV5Error: LocalizedError {
    case invalidBackup(String)
    case restoreFailed(String)
    case rollbackFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidBackup(let msg): return "备份文件无效：\(msg)"
        case .restoreFailed(let msg): return "恢复失败：\(msg)"
        case .rollbackFailed(let msg): return "恢复失败且回滚异常：\(msg)"
        }
    }
}

// MARK: - 备份/恢复主服务

final class BackupV5Manager {

    static let shared = BackupV5Manager()
    private init() {}

    /// 新备份目录：Documents/备份/Backups/（快速与全量 zip 都在这里）
    static var backupsDirectory: URL {
        let dir = DataRoot.url().appendingPathComponent("Backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 恢复前安全快照目录：Documents/备份/PreRestore/（启动时清理残留）
    static var preRestoreDirectory: URL {
        DataRoot.url().appendingPathComponent("PreRestore", isDirectory: true)
    }

    /// 清理恢复中断留下的安全快照（App 启动时调用）
    static func cleanupPreRestoreResidue() {
        try? FileManager.default.removeItem(at: preRestoreDirectory)
    }

    // MARK: - 文件命名与列表

    /// 生成备份文件名：快速_2026年10月22日15时30分.zip；自动备份追加 _自动；同分钟冲突追加 -2
    static func fileName(kind: BackupKindV5, isAuto: Bool = false, date: Date = Date()) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "zh_CN")
        fmt.dateFormat = "yyyy年M月d日H时m分"
        var name = "\(kind.shortLabel)_\(fmt.string(from: date))"
        if isAuto { name += "_自动" }
        var candidate = name + ".zip"
        var n = 2
        while FileManager.default.fileExists(atPath: backupsDirectory.appendingPathComponent(candidate).path) {
            candidate = "\(name)-\(n).zip"
            n += 1
        }
        return candidate
    }

    /// 列出本地方言备份文件（快速/全量 zip，不含旧版 JSON——旧版由 DataBackupManager 管理）
    static func listLocalBackups() -> [URL] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: backupsDirectory.path) else { return [] }
        let urls = names.filter { $0.hasSuffix(".zip") }
            .map { backupsDirectory.appendingPathComponent($0) }
        return urls.sorted { a, b in
            (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast >
            (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
        }
    }

    /// 解析 zip 内 manifest（快速/全量通用）
    static func readManifest(from url: URL) -> BackupManifestV5? {
        guard let data = try? ZipStore.extract(at: url, path: "manifest.json") else { return nil }
        return try? JSONDecoder().decode(BackupManifestV5.self, from: data)
    }

    /// 判断 zip 备份类型（识别不了返回 nil）
    static func kind(of url: URL) -> BackupKindV5? {
        guard let manifest = readManifest(from: url) else { return nil }
        return BackupKindV5(rawValue: manifest.kind)
    }

    // MARK: - 备份创建

    /// 导出经营数据 JSON（复用 DataBackupManager.exportAllData：含成交/杂项收入/杂项支出/收租/包租/待办/水电历史）
    @MainActor
    static func exportBusinessJSON(mainContext: ModelContext) throws -> Data {
        try DataBackupManager().exportAllData(modelContext: mainContext)
    }

    /// 导出房源数据 JSON（含媒体引用清单）
    @MainActor
    static func exportHousesJSON(houseContext: ModelContext) throws -> Data {
        let descriptor = FetchDescriptor<House>(sortBy: [SortDescriptor(\House.createdAt, order: .reverse)])
        let all = (try? houseContext.fetch(descriptor)) ?? []
        let houses = all.map { house -> HouseExportDTO in
            HouseExportDTO(
                id: house.id,
                roomNo: house.roomNo,
                tower: house.tower,
                landlord: house.landlord,
                layout: house.layout,
                price: house.price,
                password: house.password,
                remark: house.remark,
                statusRaw: house.statusRaw,
                createdAt: house.createdAt,
                updatedAt: house.updatedAt,
                isDeleted: house.isDeleted,
                deletedAt: house.deletedAt,
                mediaItems: house.mediaItems.map {
                    HouseExportDTO.MediaDTO(id: $0.id, fileName: $0.fileName, kind: $0.kind)
                }
            )
        }
        let bundle = HouseBundleDTO(schemaVersion: 5, houses: houses)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(bundle)
    }

    /// 扫描媒体目录生成指纹清单（含 sha1），全量备份同时返回文件条目供打包
    static func collectMediaFingerprints() -> [MediaFingerprintV5] {
        let mediaDir = MediaStore.mediaDirectory()
        guard let roomKeys = try? FileManager.default.contentsOfDirectory(atPath: mediaDir.path) else { return [] }
        var list: [MediaFingerprintV5] = []
        for roomKey in roomKeys {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: mediaDir.appendingPathComponent(roomKey).path, isDirectory: &isDir),
                  isDir.boolValue else { continue }
            let roomDir = mediaDir.appendingPathComponent(roomKey)
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: roomDir.path) else { continue }
            for name in files.sorted() {
                let fileURL = roomDir.appendingPathComponent(name)
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                      let size = attrs[.size] as? Int64 else { continue }
                let kind = name.lowercased().hasSuffix(".mov") || name.lowercased().hasSuffix(".mp4") ? "video" : "image"
                let sha1 = sha1OfFile(at: fileURL) ?? ""
                list.append(MediaFingerprintV5(roomKey: roomKey, fileName: name, kind: kind, size: size, sha1: sha1))
            }
        }
        return list
    }

    /// 创建快速备份（快照 zip：manifest + business + houses + media_manifest；不含媒体文件）
    @MainActor
    @discardableResult
    static func createFastBackup(mainContext: ModelContext, houseContext: ModelContext, isAuto: Bool = false, date: Date = Date()) -> URL? {
        do {
            let business = try exportBusinessJSON(mainContext: mainContext)
            let houses = try exportHousesJSON(houseContext: houseContext)
            let fingerprints = collectMediaFingerprints()
            let manifest = BackupManifestV5(
                kind: BackupKindV5.fast.rawValue,
                isAuto: isAuto,
                createdAt: ISO8601DateFormatter().string(from: date),
                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
                deviceName: UIDevice.current.name
            )
            let manifestData = try JSONEncoder().encode(manifest)
            let fingerprintData = try JSONEncoder().encode(fingerprints)
            let name = fileName(kind: .fast, isAuto: isAuto, date: date)
            let url = backupsDirectory.appendingPathComponent(name)
            try ZipStore.createZip(entries: [
                ("manifest.json", manifestData),
                ("business.json", business),
                ("houses.json", houses),
                ("media_manifest.json", fingerprintData)
            ], to: url)
            return url
        } catch {
            return nil
        }
    }

    /// 创建全量备份（快照 + media/ 全部原文件），progress 0~1。
    /// 主线程只做数据库导出（值类型数据），zip 打包与媒体读取在后台线程执行，避免卡 UI。
    @MainActor
    static func createFullBackup(mainContext: ModelContext, houseContext: ModelContext, isAuto: Bool = false, date: Date = Date(), progress: (@Sendable (Double) -> Void)? = nil) async -> URL? {
        // 1. 主线程导出（SwiftData 上下文只能在主线程访问）
        let prepared: (business: Data, houses: Data, fingerprints: [MediaFingerprintV5], manifest: BackupManifestV5)?
        do {
            let business = try exportBusinessJSON(mainContext: mainContext)
            let houses = try exportHousesJSON(houseContext: houseContext)
            let fingerprints = collectMediaFingerprints()
            let manifest = BackupManifestV5(
                kind: BackupKindV5.full.rawValue,
                isAuto: isAuto,
                createdAt: ISO8601DateFormatter().string(from: date),
                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
                deviceName: UIDevice.current.name
            )
            prepared = (business, houses, fingerprints, manifest)
        } catch {
            return nil
        }
        guard let prepared = prepared else { return nil }

        // 2. 后台打包（不碰 ModelContext，只读写文件与内存）
        let name = fileName(kind: .full, isAuto: isAuto, date: date)
        let url = backupsDirectory.appendingPathComponent(name)
        return await Task.detached(priority: .userInitiated) {
            do {
                let manifestData = try JSONEncoder().encode(prepared.manifest)
                let fingerprintData = try JSONEncoder().encode(prepared.fingerprints)
                let mediaEntries = BackupV5Manager.collectMediaFileEntries()
                var entries: [(path: String, data: Data)] = [
                    ("manifest.json", manifestData),
                    ("business.json", prepared.business),
                    ("houses.json", prepared.houses),
                    ("media_manifest.json", fingerprintData)
                ]
                var body = Data()
                var central: [Data] = []
                var offset: UInt64 = 0
                var seen = Set<String>()
                for (path, data) in entries {
                    let normalized = path.hasPrefix("/") ? String(path.dropFirst()) : path
                    guard !seen.contains(normalized) else { continue }
                    seen.insert(normalized)
                    let nameData = Data(normalized.utf8)
                    let crc = ZipStore.crc32(of: data)
                    var lfh = ZipStore.localHeaderData(nameData: nameData, crc: crc, size: UInt64(data.count), offset: &offset)
                    lfh.append(data)
                    body.append(lfh)
                    central.append(ZipStore.centralRecordData(nameData: nameData, crc: crc, size: UInt64(data.count), localHeaderOffset: offset - UInt64(lfh.count)))
                }
                var totalBytes: Int64 = 0
                for entry in mediaEntries {
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: entry.fileURL.path),
                       let size = attrs[.size] as? Int64 { totalBytes += size }
                }
                var writtenBytes: Int64 = 0
                for (path, fileURL) in mediaEntries {
                    let normalized = path.hasPrefix("/") ? String(path.dropFirst()) : path
                    guard !seen.contains(normalized) else { continue }
                    seen.insert(normalized)
                    let fileData = try Data(contentsOf: fileURL)
                    let nameData = Data(normalized.utf8)
                    let crc = ZipStore.crc32(of: fileData)
                    var lfh = ZipStore.localHeaderData(nameData: nameData, crc: crc, size: UInt64(fileData.count), offset: &offset)
                    lfh.append(fileData)
                    body.append(lfh)
                    writtenBytes += Int64(fileData.count)
                    if totalBytes > 0 {
                        let p = min(Double(writtenBytes) / Double(totalBytes), 1.0)
                        await MainActor.run { progress?(p) }
                    }
                    central.append(ZipStore.centralRecordData(nameData: nameData, crc: crc, size: UInt64(fileData.count), localHeaderOffset: offset - UInt64(lfh.count)))
                }
                var full = body
                ZipStore.appendCentralAndEOCD(central: central, bodyCount: body.count, centralRecords: &central, to: &full, startOffset: offset)
                try full.write(to: url, options: .atomic)
                await MainActor.run { progress?(1.0) }
                return url
            } catch {
                return nil
            }
        }.value
    }

    // MARK: - 恢复（带进度与分行统计；防失败机制：恢复前安全快照，失败自动回滚）

    /// 恢复 zip 备份。phaseProgress: 0~1；完成返回统计。
    /// isFull 由 zip 内 manifest 决定：全量覆盖媒体目录（恢复前打包现有媒体做安全快照），快速不碰媒体。
    static func restore(zipURL: URL, mainContext: ModelContext, houseContext: ModelContext,
                        phaseProgress: @escaping (Double) -> Void,
                        stageMessage: @escaping (String) -> Void) async throws -> RestoreStatsV5 {
        // 1. 校验
        guard ZipStore.isZip(url: zipURL) else { throw BackupV5Error.invalidBackup("不是有效的 zip 文件") }
        guard let manifest = readManifest(from: zipURL) else { throw BackupV5Error.invalidBackup("缺少 manifest.json（可能不是公寓管家备份）") }
        guard manifest.schemaVersion <= 5 else { throw BackupV5Error.invalidBackup("备份版本 \(manifest.schemaVersion) 高于当前 App 支持的 5，请升级 App 后再恢复") }
        let kind = BackupKindV5(rawValue: manifest.kind) ?? .fast
        guard let businessData = try? ZipStore.extract(at: zipURL, path: "business.json") else {
            throw BackupV5Error.invalidBackup("缺少 business.json")
        }
        guard let housesData = try? ZipStore.extract(at: zipURL, path: "houses.json") else {
            throw BackupV5Error.invalidBackup("缺少 houses.json")
        }

        stageMessage("校验通过，正在打包当前数据做安全快照…")
        phaseProgress(0.02)

        // 2. 安全快照（恢复前现有数据备份到 PreRestore/，失败时用其回滚）
        let preDir = preRestoreDirectory
        try? FileManager.default.removeItem(at: preDir)
        try FileManager.default.createDirectory(at: preDir, withIntermediateDirectories: true)
        let businessBeforeURL = preDir.appendingPathComponent("business_before.json")
        let housesBeforeURL = preDir.appendingPathComponent("houses_before.json")
        do {
            try await MainActor.run {
                let businessBefore = try exportBusinessJSON(mainContext: mainContext)
                try businessBefore.write(to: businessBeforeURL, options: .atomic)
                let housesBefore = try exportHousesJSON(houseContext: houseContext)
                try housesBefore.write(to: housesBeforeURL, options: .atomic)
            }
            // 全量恢复：现有媒体整体打包（恢复成功后自动删除；失败时还原）
            if kind == .full {
                stageMessage("正在打包现有照片视频（全量恢复前的安全备份）…")
                let mediaBeforeZip = preDir.appendingPathComponent("media_before.zip")
                let mediaEntries = collectMediaFileEntries()
                try ZipStore.createZipStreamed(entries: mediaEntries, to: mediaBeforeZip) { p in
                    phaseProgress(0.02 + p * 0.35)
                }
            }
        } catch {
            throw BackupV5Error.restoreFailed("安全快照创建失败：\(error.localizedDescription)")
        }
        phaseProgress(0.38)

        // 3. 导入（数据库操作必须在主线程）
        do {
            // 3.1 经营数据：清空 → 导入
            stageMessage("正在导入账本数据…")
            try await MainActor.run {
                try clearAllMainData(mainContext: mainContext)
            }
            let dm = DataBackupManager()
            let (importOK, _) = await dm.importAllDataAsync(from: businessData, modelContext: mainContext, scope: .all)
            guard importOK else { throw BackupV5Error.restoreFailed("账本数据导入失败") }
            phaseProgress(0.55)

            // 3.2 房源数据：清空 → 重建（含媒体引用）
            stageMessage("正在导入房源数据…")
            try await MainActor.run {
                try clearAllHouses(houseContext: houseContext)
                try importHousesJSON(data: housesData, houseContext: houseContext)
            }
            phaseProgress(0.70)

            // 3.3 媒体文件：仅全量备份覆盖 Media 目录
            if kind == .full {
                stageMessage("正在还原照片视频…")
                try await MainActor.run {
                    try? FileManager.default.removeItem(at: MediaStore.mediaDirectory())
                    try FileManager.default.createDirectory(at: MediaStore.mediaDirectory(), withIntermediateDirectories: true)
                }
                // 解压媒体（流式，后台线程执行）
                try await Task.detached(priority: .userInitiated) {
                    try ZipStore.extractAll(at: zipURL, to: MediaStore.mediaDirectory())
                }.value
                phaseProgress(0.90)
            }

            // 4. 统计（数据库口径）
            stageMessage("正在核对恢复结果…")
            let stats: RestoreStatsV5 = await MainActor.run {
                computeStats(mainContext: mainContext, houseContext: houseContext)
            }
            phaseProgress(0.98)

            // 5. 成功：删除恢复前安全快照（含媒体 zip），返回统计
            stageMessage("恢复完成，正在清理临时文件…")
            try? FileManager.default.removeItem(at: preDir)
            phaseProgress(1.0)
            return stats
        } catch {
            // 6. 失败回滚：用安全快照还原
            stageMessage("恢复失败，正在还原原有数据…")
            do {
                try await rollback(preDir: preDir, mainContext: mainContext, houseContext: houseContext)
            } catch {
                throw BackupV5Error.rollbackFailed(error.localizedDescription)
            }
            throw error
        }
    }

    /// 恢复旧版 JSON 备份（v4 及更早：分板块 total/deals/properties/payouts），复用 DataBackupManager
    static func restoreLegacyJSON(data: Data, mainContext: ModelContext, scope: DataBackupManager.ImportScope) async throws -> RestoreStatsV5 {
        // 先做安全快照（经营数据）
        let preDir = preRestoreDirectory
        try? FileManager.default.removeItem(at: preDir)
        try FileManager.default.createDirectory(at: preDir, withIntermediateDirectories: true)
        do {
            try await MainActor.run {
                let businessBefore = try exportBusinessJSON(mainContext: mainContext)
                try businessBefore.write(to: preDir.appendingPathComponent("business_before.json"), options: .atomic)
            }
        } catch {
            throw BackupV5Error.restoreFailed("安全快照创建失败：\(error.localizedDescription)")
        }
        do {
            let dm = DataBackupManager()
            let (importOK, _) = await dm.importAllDataAsync(from: data, modelContext: mainContext, scope: scope)
            guard importOK else { throw BackupV5Error.restoreFailed("旧版备份导入失败") }
        } catch {
            // 回滚经营数据
            if let before = try? Data(contentsOf: preDir.appendingPathComponent("business_before.json")) {
                let dm = DataBackupManager()
                _ = await dm.importAllDataAsync(from: before, modelContext: mainContext, scope: .all)
            }
            try? FileManager.default.removeItem(at: preDir)
            throw error
        }
        try? FileManager.default.removeItem(at: preDir)
        return await MainActor.run { computeStats(mainContext: mainContext, houseContext: nil) }
    }

    // MARK: - 清空与导入（主线程执行）

    @MainActor
    private static func clearAllMainData(mainContext: ModelContext) throws {
        // 逐类 fetch 删除（与 Schema 13 模型一一对应，恢复导入前清空账本）
        deleteAll(type: DealRecord.self, ctx: mainContext)
        deleteAll(type: MiscIncome.self, ctx: mainContext)
        deleteAll(type: MiscExpense.self, ctx: mainContext)
        deleteAll(type: Property.self, ctx: mainContext)
        deleteAll(type: RentMonthRecord.self, ctx: mainContext)
        deleteAll(type: UtilitySettlementRecord.self, ctx: mainContext)
        deleteAll(type: UtilityQuarterRecord.self, ctx: mainContext)   // 主容器 13 模型之一
        deleteAll(type: PayoutRecord.self, ctx: mainContext)
        deleteAll(type: PayoutMonthRecord.self, ctx: mainContext)
        deleteAll(type: PayoutUtilityRecord.self, ctx: mainContext)
        deleteAll(type: TodoItem.self, ctx: mainContext)
        deleteAll(type: ProfitCalculation.self, ctx: mainContext)
        deleteAll(type: UtilitySettlementHistory.self, ctx: mainContext)
        try mainContext.save()
    }

    @MainActor
    private static func deleteAll<T: PersistentModel>(type: T.Type, ctx: ModelContext) {
        let descriptor = FetchDescriptor<T>()
        guard let all = try? ctx.fetch(descriptor) else { return }
        for item in all { ctx.delete(item) }
    }

    @MainActor
    private static func clearAllHouses(houseContext: ModelContext) throws {
        let hd = FetchDescriptor<House>()
        if let houses = try? houseContext.fetch(hd) {
            for house in houses { houseContext.delete(house) }
        }
        let md = FetchDescriptor<MediaItem>()
        if let medias = try? houseContext.fetch(md) {
            for media in medias { houseContext.delete(media) }
        }
        try houseContext.save()
    }

    @MainActor
    private static func importHousesJSON(data: Data, houseContext: ModelContext) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let bundle = try decoder.decode(HouseBundleDTO.self, from: data)
        for dto in bundle.houses {
            let house = House(
                roomNo: dto.roomNo,
                tower: dto.tower,
                landlord: dto.landlord,
                layout: dto.layout,
                price: dto.price,
                password: dto.password,
                remark: dto.remark,
                status: HouseStatus(rawValue: dto.statusRaw) ?? .available
            )
            // 保留原 id/时间戳/删除状态
            house.id = dto.id
            house.createdAt = dto.createdAt
            house.updatedAt = dto.updatedAt
            house.isDeleted = dto.isDeleted
            house.deletedAt = dto.deletedAt
            houseContext.insert(house)
            for mediaDTO in dto.mediaItems {
                let media = MediaItem(fileName: mediaDTO.fileName, kind: mediaDTO.kind)
                media.id = mediaDTO.id
                media.house = house
                houseContext.insert(media)
            }
        }
        try houseContext.save()
    }

    /// 回滚：用安全快照还原
    private static func rollback(preDir: URL, mainContext: ModelContext, houseContext: ModelContext?) async throws {
        // 经营数据
        if let before = try? Data(contentsOf: preDir.appendingPathComponent("business_before.json")) {
            try await MainActor.run {
                try clearAllMainData(mainContext: mainContext)
            }
            let dm = DataBackupManager()
            _ = await dm.importAllDataAsync(from: before, modelContext: mainContext, scope: .all)
        }
        // 房源数据
        if let houseContext = houseContext, let before = try? Data(contentsOf: preDir.appendingPathComponent("houses_before.json")) {
            try await MainActor.run {
                try clearAllHouses(houseContext: houseContext)
                try importHousesJSON(data: before, houseContext: houseContext)
            }
        }
        // 媒体：存在 media_before.zip 时还原（全量恢复场景）
        let mediaBeforeZip = preDir.appendingPathComponent("media_before.zip")
        if FileManager.default.fileExists(atPath: mediaBeforeZip.path) {
            try? FileManager.default.removeItem(at: MediaStore.mediaDirectory())
            try FileManager.default.createDirectory(at: MediaStore.mediaDirectory(), withIntermediateDirectories: true)
            try await Task.detached(priority: .userInitiated) {
                try ZipStore.extractAll(at: mediaBeforeZip, to: MediaStore.mediaDirectory())
            }.value
        }
    }

    // MARK: - 统计

    /// 恢复完成分行统计（两个容器都要：主容器经营数据 + 房源容器）
    @MainActor
    static func computeStats(mainContext: ModelContext, houseContext: ModelContext?) -> RestoreStatsV5 {
        var stats = RestoreStatsV5()
        func count<T: PersistentModel>(_ type: T.Type, in ctx: ModelContext, where predicate: (T) -> Bool = { _ in true }) -> Int {
            guard let all = try? ctx.fetch(FetchDescriptor<T>()) else { return 0 }
            return all.filter(predicate).count
        }
        stats.deals = count(DealRecord.self, in: mainContext)
        stats.incomes = count(MiscIncome.self, in: mainContext)
        stats.expenses = count(MiscExpense.self, in: mainContext)
        stats.renting = count(Property.self, in: mainContext, where: { !$0.isTerminated })
        stats.terminated = count(Property.self, in: mainContext, where: { $0.isTerminated })
        stats.payouts = count(PayoutRecord.self, in: mainContext)
        stats.todosOpen = count(TodoItem.self, in: mainContext, where: { !$0.isCompleted && !($0.isDeleted) })
        stats.todosDone = count(TodoItem.self, in: mainContext, where: { $0.isCompleted && !($0.isDeleted) })
        if let houseContext = houseContext {
            stats.houses = count(House.self, in: houseContext, where: { !($0.isDeleted ?? false) })
            let allMedia = (try? houseContext.fetch(FetchDescriptor<MediaItem>())) ?? []
            stats.photos = allMedia.filter { $0.kind == "image" }.count
            stats.videos = allMedia.filter { $0.kind == "video" }.count
        }
        return stats
    }

    // MARK: - 工具

    /// 扫描 Media/ 下全部媒体文件（归档条目）
    static func collectMediaFileEntries() -> [(path: String, fileURL: URL)] {
        var entries: [(path: String, fileURL: URL)] = []
        let mediaDir = MediaStore.mediaDirectory()
        guard let roomKeys = try? FileManager.default.contentsOfDirectory(atPath: mediaDir.path) else { return entries }
        for roomKey in roomKeys.sorted() {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: mediaDir.appendingPathComponent(roomKey).path, isDirectory: &isDir),
                  isDir.boolValue else { continue }
            let roomDir = mediaDir.appendingPathComponent(roomKey)
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: roomDir.path) else { continue }
            for name in files.sorted() {
                entries.append((path: "media/\(roomKey)/\(name)", fileURL: roomDir.appendingPathComponent(name)))
            }
        }
        return entries
    }

    static func sha1OfFile(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let digest = Insecure.SHA1.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func sha1OfData(_ data: Data) -> String {
        let digest = Insecure.SHA1.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 文件大小（字节）
    static func fileSize(at url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 ?? 0
    }

    /// 检查剩余磁盘空间是否足够（bytes 需求，返回剩余字节数；不足返回 false）
    static func hasFreeSpace(needed bytes: Int64) -> Bool {
        let attrs = (try? FileManager.default.attributesOfFileSystem(forPath: DataRoot.url().path)) ?? [:]
        guard let free = attrs[.systemFreeSize] as? NSNumber else { return true }
        return free.int64Value > bytes * 2  // 要求剩余 ≥ 需求 2 倍
    }
}
