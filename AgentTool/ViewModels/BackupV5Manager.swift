import Foundation
import SwiftData
import CryptoKit
import UIKit

// MARK: - v1.12 备份体系 v2：快照 v5（统一快照格式）
// 一份快照 = 经营 JSON + 媒体指纹清单（schemaVersion 4 → 5 → 6，兼容旧版备份导入）。
// 备份分两类：
//   · 快速备份（fast）：快照 zip（不含房源、不含媒体文件本体），自动/手动均可用，自动上传云端；
//     v1.56 起不再写入房源（房源以云端为准，恢复后统一从云端同步，避免快照无云端状态导致同步冲突）
//   · 全量备份（full）：快照 zip（含房源 JSON）+ media/ 全部原文件，手动上传云端（可增量）
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
    /// v1.57：补齐云端状态与最后更新时间——缺失会导致全量恢复后所有房源变「仅本地」，
    /// 再同步时把云端已删房源当作本地新增补传回云端（已删房源复活）
    var cloudStatusRaw: String?
    var lastUpdatedAt: Date?
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
                cloudStatusRaw: house.cloudStatusRaw,
                lastUpdatedAt: house.lastUpdatedAt,
                mediaItems: house.mediaItems.map {
                    HouseExportDTO.MediaDTO(id: $0.id, fileName: $0.fileName, kind: $0.kind)
                }
            )
        }
        let bundle = HouseBundleDTO(schemaVersion: 6, houses: houses)
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

    /// 创建快速备份（快照 zip：manifest + business + media_manifest + 操作日志 + 崩溃日志；不含房源、不含媒体文件）
    /// v1.56：快速备份不再写 houses.json——房源以云端为准，恢复后统一从云端同步，
    /// 避免「快照不带云端状态、恢复后变仅本地、再同步把已删房源复活/覆盖」的冲突。
    @MainActor
    @discardableResult
    static func createFastBackup(mainContext: ModelContext, houseContext: ModelContext, isAuto: Bool = false, date: Date = Date()) -> URL? {
        do {
            let business = try exportBusinessJSON(mainContext: mainContext)
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
            // v1.40 第8点：操作日志 + 崩溃日志并入快速备份（诊断数据）
            var entries: [(path: String, data: Data)] = [
                ("manifest.json", manifestData),
                ("business.json", business),
                ("media_manifest.json", fingerprintData)
            ]
            entries.append(contentsOf: logEntriesForBackup())
            try ZipStore.createZip(entries: entries, to: url)
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

        // v1.40 C5：全量备份媒体完整性校验——房源清单引用的媒体 vs 本地实际文件，缺失只记日志提示（不阻塞打包）
        let missing = missingMediaReport(housesData: prepared.houses, fingerprints: prepared.fingerprints)
        if missing.missing > 0 {
            BackupLogStore.log(category: "备份", action: "全量备份", result: "提示",
                               detail: "房源清单引用 \(missing.missing) 个媒体本地缺失（\(missing.rooms.joined(separator: "，"))），已按现有文件打包，恢复后这些房源图片/视频会不全", cloud: false)
        }

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
                // v1.40 第8点：操作日志 + 崩溃日志并入全量备份（诊断数据）
                entries.append(contentsOf: BackupV5Manager.logEntriesForBackup())
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
        guard manifest.schemaVersion <= 6 else { throw BackupV5Error.invalidBackup("备份版本 \(manifest.schemaVersion) 高于当前 App 支持的 6，请升级 App 后再恢复") }
        let kind = BackupKindV5(rawValue: manifest.kind) ?? .fast
        guard let businessData = try? ZipStore.extract(at: zipURL, path: "business.json") else {
            throw BackupV5Error.invalidBackup("缺少 business.json")
        }
        // v1.56：houses.json 仅全量备份必需；快速备份不含房源（房源统一从云端同步恢复）
        let housesData: Data? = try? ZipStore.extract(at: zipURL, path: "houses.json")
        if kind == .full && housesData == nil {
            throw BackupV5Error.invalidBackup("全量备份缺少 houses.json")
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

            // 3.2 房源数据：仅全量备份恢复（清空 → 重建，含媒体引用）
            // v1.56：快速备份不恢复房源——房源以云端为准，恢复后从云端同步拉回，
            // 避免「快照不带云端状态、恢复后变仅本地、再同步把已删房源复活/覆盖」的冲突。
            if kind == .full, let housesData = housesData {
                stageMessage("正在导入房源数据…")
                try await MainActor.run {
                    try clearAllHouses(houseContext: houseContext)
                    try importHousesJSON(data: housesData, houseContext: houseContext)
                }
                phaseProgress(0.70)
            } else {
                stageMessage("房源数据将从云端同步恢复（快速备份不含房源）…")
                phaseProgress(0.70)
            }

            // 3.3 媒体文件：仅全量备份覆盖 media 目录
            if kind == .full {
                stageMessage("正在还原照片视频…")
                // v1.40 第5点修复：zip 内媒体条目为 media/<房号>/<文件>，解压到 Documents 根目录
                // → 自动落位 Documents/media/<房号>/<文件>（此前解压到 media 目录内，多套一层 media/media 导致详情页识别不到）
                let docsRoot = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                try await MainActor.run {
                    try? FileManager.default.removeItem(at: MediaStore.mediaDirectory())
                    try FileManager.default.createDirectory(at: MediaStore.mediaDirectory(), withIntermediateDirectories: true)
                }
                // 解压媒体（流式，后台线程执行；只解压 media/ 前缀条目，避免 manifest 等散落到 Documents 根）
                try await Task.detached(priority: .userInitiated) {
                    try ZipStore.extractAll(at: zipURL, to: docsRoot) { $0.hasPrefix("media/") }
                }.value
                phaseProgress(0.90)
            } else {
                // 3.4 v1.41：快速备份不带媒体本体，恢复后做「媒体对账」——
                // 磁盘上已有但 houses.json 记录里没有的文件（如之前同步下载过、备份时刻不存在）
                // 自动补建 MediaItem 记录，避免「视频明明在 media 文件夹里，详情页却打不开」。
                let extraMedia = await MainActor.run { reconcileLocalMedia(houseContext: houseContext) }
                if extraMedia > 0 {
                    stageMessage("已补录 \(extraMedia) 个本地媒体记录…")
                }
                phaseProgress(0.90)
            }

            // 4. 统计（数据库口径）
            stageMessage("正在核对恢复结果…")
            let stats: RestoreStatsV5 = await MainActor.run {
                // v1.41：房源/照片/视频统计仅全量恢复才展示（快速备份不含媒体本体，统计口径不含房源媒体）
                computeStats(mainContext: mainContext, houseContext: houseContext, includeHouse: kind == .full)
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
            // v1.69：全量恢复同样强制带前缀口径——备份里房号若意外带前缀（历史脏数据），
            // 归一为内部「无前缀 + tower」结构，保证恢复后 mediaRoomKey/显示房号统一带 1-/2- 前缀
            var roomNo = dto.roomNo.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "2－", with: "2-")
                .replacingOccurrences(of: "1－", with: "1-")
            var tower = dto.tower
            if roomNo.hasPrefix("2-") {
                roomNo = String(roomNo.dropFirst(2))
                if tower == 0 { tower = 2 }
            } else if roomNo.hasPrefix("1-") {
                roomNo = String(roomNo.dropFirst(2))
                if tower == 0 { tower = 1 }
            }
            let house = House(
                roomNo: roomNo,
                tower: tower,
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
            // v1.57：还原云端状态与最后更新时间（旧备份无此字段 → nil，维持原行为）
            house.cloudStatusRaw = dto.cloudStatusRaw
            house.lastUpdatedAt = dto.lastUpdatedAt
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
            // v1.40 第5点：与恢复一致——解压到 Documents 根，落位 Documents/media/
            let docsRoot = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            try? FileManager.default.removeItem(at: MediaStore.mediaDirectory())
            try FileManager.default.createDirectory(at: MediaStore.mediaDirectory(), withIntermediateDirectories: true)
            try await Task.detached(priority: .userInitiated) {
                try ZipStore.extractAll(at: mediaBeforeZip, to: docsRoot) { $0.hasPrefix("media/") }
            }.value
        }
    }

    // MARK: - 统计

    /// 恢复完成分行统计（两个容器都要：主容器经营数据 + 房源容器）
    /// v1.41：房源/照片/视频统计仅全量恢复才统计（includeHouse=false 时跳过房源媒体），
    ///        快速备份不含媒体本体、只含记录引用，不应展示「房源N套/照片N张/视频N个」。
    @MainActor
    static func computeStats(mainContext: ModelContext, houseContext: ModelContext?, includeHouse: Bool = true) -> RestoreStatsV5 {
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
        if let houseContext = houseContext, includeHouse {
            stats.houses = count(House.self, in: houseContext, where: { !($0.isDeleted ?? false) })
            let allMedia = (try? houseContext.fetch(FetchDescriptor<MediaItem>())) ?? []
            stats.photos = allMedia.filter { $0.kind == "image" }.count
            stats.videos = allMedia.filter { $0.kind == "video" }.count
        }
        return stats
    }

    /// v1.41：恢复（快速）后的媒体对账——扫描本地 media/<房号>/ 磁盘文件，
    /// 与 MediaItem 记录补齐差异，返回补录数量。解决「恢复快速备份后视频打不开」：
    /// 快速备份只带记录引用不带媒体本体，若磁盘上已有文件（如同步下载过）而记录缺失 → 详情页识别不到。
    @MainActor
    static func reconcileLocalMedia(houseContext: ModelContext) -> Int {
        let mediaDir = MediaStore.mediaDirectory()
        guard let roomKeys = try? FileManager.default.contentsOfDirectory(atPath: mediaDir.path) else { return 0 }
        guard let houses = try? houseContext.fetch(FetchDescriptor<House>()) else { return 0 }
        var added = 0
        for house in houses {
            let roomKey = house.mediaRoomKey
            guard !roomKey.isEmpty else { continue }
            let houseDir = mediaDir.appendingPathComponent(roomKey, isDirectory: true)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: houseDir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let diskFiles = try? FileManager.default.contentsOfDirectory(atPath: houseDir.path) else { continue }
            let recorded = Set(house.mediaItems.map { $0.fileName })
            for name in diskFiles {
                guard !recorded.contains(name) else { continue }
                let lower = name.lowercased()
                let isVideo = lower.hasSuffix(".mp4") || lower.hasSuffix(".mov")
                let isImage = [".jpg", ".jpeg", ".png", ".heic", ".webp", ".gif"].contains { lower.hasSuffix($0) }
                guard isVideo || isImage else { continue }
                let item = MediaItem(fileName: name, kind: isVideo ? "video" : "image")
                item.house = house
                houseContext.insert(item)
                added += 1
            }
        }
        if added > 0 { try? houseContext.save() }
        return added
    }

    // MARK: - 工具

    /// v1.40 C5：媒体完整性校验——房源清单（houses.json）里引用的媒体 vs 本地 media 实际文件。
    /// 返回缺失数量与涉及房号（用于备份前提示，防止「备份存在但恢复后发现媒体不全」）。
    static func missingMediaReport(housesData: Data, fingerprints: [MediaFingerprintV5]) -> (missing: Int, rooms: [String]) {
        guard let bundle = try? JSONDecoder().decode(HouseBundleDTO.self, from: housesData) else { return (0, []) }
        let actual = Set(fingerprints.map { "\($0.roomKey)|\($0.fileName)" })
        var missing = 0
        var rooms: Set<String> = []
        for h in bundle.houses {
            let clean = h.roomNo.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "2－", with: "2-")
            let noPrefix = clean.hasPrefix("2-") ? String(clean.dropFirst(2)) : clean
            let roomKey = h.tower == 2 ? "2-\(noPrefix)" : noPrefix
            for m in h.mediaItems where !actual.contains("\(roomKey)|\(m.fileName)") {
                missing += 1
                rooms.insert(h.roomNo)
            }
        }
        return (missing, rooms.sorted())
    }

    /// v1.40 第8点：操作日志 + 崩溃日志 → 备份 zip 条目（诊断数据；恢复时不导入，仅随备份留档）
    static func logEntriesForBackup() -> [(path: String, data: Data)] {
        var entries: [(path: String, data: Data)] = []
        // 操作日志（本地最近 45 天）
        let ops = BackupLogStore.all()
        if let data = try? JSONEncoder().encode(ops) {
            entries.append(("ops_log.json", data))
        }
        // 崩溃日志（最近 5 份文本合并）
        let crashFiles = CrashLogCollector.logFiles()
        if !crashFiles.isEmpty {
            var text = ""
            for url in crashFiles {
                if let s = try? String(contentsOf: url, encoding: .utf8) {
                    text += "===== \(url.lastPathComponent) =====\n\(s)\n\n"
                }
            }
            if let data = text.data(using: .utf8) {
                entries.append(("crash_log.txt", data))
            }
        }
        return entries
    }

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
