import Foundation
import SwiftData

// 数据备份/导入导出管理
class DataBackupManager {
    static let shared = DataBackupManager()
    private let isoFormatter = ISO8601DateFormatter()
    private let dateFormatters: [DateFormatter] = {
        let formats = ["yyyy-MM-dd", "yyyy.MM.dd", "yyyy/MM/dd", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy.M.d", "yyyy年M月d日"]
        return formats.map { fmt in
            let df = DateFormatter()
            df.dateFormat = fmt
            df.locale = Locale(identifier: "zh_CN")
            df.timeZone = TimeZone(identifier: "Asia/Shanghai")
            return df
        }
    }()

    // 备份文件最大10MB
    private let maxBackupFileSize = 10 * 1024 * 1024

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    private var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    }

    private func addBackupMetadata(to dict: inout [String: Any], type: String) {
        dict["schemaVersion"] = 4
        dict["exportTime"] = isoFormatter.string(from: Date())
        dict["appVersion"] = appVersion
        dict["appBuild"] = appBuild
        dict["backupType"] = type
    }

    private func parseDate(_ str: String?) -> Date? {
        guard let s = str, !s.isEmpty else { return nil }
        if let d = isoFormatter.date(from: s) { return d }
        for df in dateFormatters {
            if let d = df.date(from: s) { return d }
        }
        return nil
    }

    private func parseDateOrNow(_ str: String?) -> Date {
        parseDate(str) ?? Date()
    }

    private func requiredDate(_ value: Any?, field: String) throws -> Date {
        guard let text = value as? String, let date = parseDate(text) else {
            throw BackupError.invalidData("日期字段 \(field) 无效")
        }
        return date
    }

    private enum BackupError: LocalizedError {
        case invalidData(String)

        var errorDescription: String? {
            switch self {
            case .invalidData(let message): return message
            }
        }
    }

    private func dbl(_ v: Any?) -> Double {
        if let n = v as? Double { return n }
        if let n = v as? Int { return Double(n) }
        if let s = v as? String, let n = Double(s) { return n }
        return 0
    }

    private func intVal(_ v: Any?) -> Int {
        if let n = v as? Int { return n }
        if let n = v as? Double { return Int(n) }
        if let s = v as? String, let n = Int(s) { return n }
        return 0
    }

    private func strVal(_ v: Any?) -> String {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return ""
    }

    // MARK: - 数据校验
    private func validateRoot(_ dict: [String: Any], scope: ImportScope) throws {
        if let version = dict["schemaVersion"] as? NSNumber, version.intValue > 4 {
            throw BackupError.invalidData("备份版本过新，请升级APP后再恢复")
        }

        let requiredKeys: [String]
        switch scope {
        case .all: requiredKeys = ["deals", "incomes", "expenses", "properties", "payouts"]
        case .deals: requiredKeys = ["deals", "incomes", "expenses"]
        case .properties: requiredKeys = ["properties"]
        case .payouts: requiredKeys = ["payouts"]
        }
        for key in requiredKeys where dict[key] as? [[String: Any]] == nil {
            throw BackupError.invalidData("备份缺少或损坏字段：\(key)")
        }

        if let declared = dict["backupType"] as? String {
            let expected: String
            switch scope {
            case .all: expected = "total"
            case .deals: expected = "deals"
            case .properties: expected = "properties"
            case .payouts: expected = "payouts"
            }
            if declared != expected {
                throw BackupError.invalidData("备份类型与当前恢复板块不一致")
            }
        }
    }

    private func validateDeal(_ d: [String: Any]) throws {
        _ = try requiredDate(d["date"], field: "成交日期")
        _ = try requiredDate(d["leaseStart"], field: "租期开始")
        _ = try requiredDate(d["leaseEnd"], field: "租期结束")
        if strVal(d["roomNumber"]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw BackupError.invalidData("成交数据缺少房号")
        }
        if let value = d["rentDueDay"], !(value is NSNull) {
            let day = intVal(value)
            if day < 1 || day > 31 { throw BackupError.invalidData("成交付款日必须为1至31") }
        }
        if dbl(d["rent"]) < 0 || dbl(d["deposit"]) < 0 || dbl(d["prepayment"]) < 0 {
            throw BackupError.invalidData("成交金额不能为负数")
        }
    }

    private func validateProperty(_ p: [String: Any]) throws {
        if strVal(p["roomNumber"]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw BackupError.invalidData("收租数据缺少房号")
        }
        let rentDueDay = intVal(p["rentDueDay"])
        if rentDueDay < 1 || rentDueDay > 31 { throw BackupError.invalidData("收租付款日必须为1至31") }
        if dbl(p["rent"]) < 0 || dbl(p["deposit"]) < 0 || dbl(p["prepayment"]) < 0 {
            throw BackupError.invalidData("收租金额不能为负数")
        }
        if let monthly = p["monthlyRentRecords"] as? [[String: Any]] {
            for m in monthly {
                let month = intVal(m["month"])
                if month < 1 || month > 12 || intVal(m["year"]) < 2000 || dbl(m["amount"]) < 0 {
                    throw BackupError.invalidData("收租月度记录无效")
                }
                if let paidDate = m["paidDate"], !(paidDate is NSNull), parseDate(paidDate as? String) == nil {
                    throw BackupError.invalidData("收租到账日期无效")
                }
            }
        }
        if let quarterly = p["quarterlyUtilityRecords"] as? [[String: Any]] {
            for q in quarterly {
                let quarter = intVal(q["quarter"])
                if quarter < 1 || quarter > 4 || dbl(q["electricAmount"]) < 0 || dbl(q["waterAmount"]) < 0 {
                    throw BackupError.invalidData("收租水电记录无效")
                }
            }
        }
    }

    private func validatePayout(_ p: [String: Any]) throws {
        _ = try requiredDate(p["leaseStartDate"], field: "包租租期开始")
        _ = try requiredDate(p["leaseEndDate"], field: "包租租期结束")
        if strVal(p["roomNumber"]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw BackupError.invalidData("包租数据缺少房号")
        }
        let rentDueDay = intVal(p["rentDueDay"])
        if rentDueDay < 1 || rentDueDay > 31 { throw BackupError.invalidData("包租付款日必须为1至31") }
        if dbl(p["annualRent"]) < 0 || dbl(p["deposit"]) < 0 || intVal(p["rentFreeDays"]) < 0 {
            throw BackupError.invalidData("包租金额或免租天数无效")
        }
        if let monthly = p["monthlyPayouts"] as? [[String: Any]] {
            for m in monthly {
                let month = intVal(m["month"])
                if month < 1 || month > 12 || dbl(m["amount"]) < 0 {
                    throw BackupError.invalidData("包租月度付款记录无效")
                }
                if let paidDate = m["paidDate"], !(paidDate is NSNull), parseDate(paidDate as? String) == nil {
                    throw BackupError.invalidData("包租付款日期无效")
                }
            }
        }
        if let utilities = p["monthlyUtilityRecords"] as? [[String: Any]] {
            for u in utilities {
                _ = try requiredDate(u["date"], field: "包租水电结算日期")
                if dbl(u["waterAmount"]) < 0 || dbl(u["electricAmount"]) < 0 {
                    throw BackupError.invalidData("包租水电金额不能为负数")
                }
            }
        }
    }

    // MARK: - 导出所有数据为JSON（P0-3: 补齐所有字段，P1-5: 查询失败抛出错误）
    func exportAllData(modelContext: ModelContext) throws -> Data {
        let deals = try modelContext.fetch(FetchDescriptor<DealRecord>())
        let incomes = try modelContext.fetch(FetchDescriptor<MiscIncome>())
        let expenses = try modelContext.fetch(FetchDescriptor<MiscExpense>())
        let properties = try modelContext.fetch(FetchDescriptor<Property>())
        let payouts = try modelContext.fetch(FetchDescriptor<PayoutRecord>())
        let todos = try modelContext.fetch(FetchDescriptor<TodoItem>())
        let utilityHistories = try modelContext.fetch(FetchDescriptor<UtilitySettlementHistory>())

        var dict: [String: Any] = [:]
        addBackupMetadata(to: &dict, type: "total")

        dict["deals"] = deals.map { deal in
            [
                "id": deal.id.uuidString,
                "date": isoFormatter.string(from: deal.date),
                "roomNumber": deal.roomNumber,
                "landlord": deal.landlord,
                "unitType": deal.unitType,
                "leaseStart": isoFormatter.string(from: deal.leaseStart),
                "leaseEnd": isoFormatter.string(from: deal.leaseEnd),
                "leaseDuration": deal.leaseDuration,
                "rent": deal.rent,
                "deposit": deal.deposit,
                "prepayment": deal.prepayment,
                "rentDueDay": deal.rentDueDay as Any,
                "agentFeeLandlord": deal.agentFeeLandlord,
                "agentFeeTenant": deal.agentFeeTenant,
                "totalFee": deal.totalFee,
                "manager": deal.manager,
                "source": deal.source,
                "notes": deal.notes,
                "isDeleted": deal.isDeleted,
                "deletedAt": deal.deletedAt.map { isoFormatter.string(from: $0) } as Any
            ]
        }

        dict["incomes"] = incomes.map { inc in
            ["id": inc.id.uuidString, "date": isoFormatter.string(from: inc.date), "item": inc.item, "amount": inc.amount, "notes": inc.notes, "isDeleted": inc.isDeleted, "deletedAt": inc.deletedAt.map { isoFormatter.string(from: $0) } as Any]
        }

        dict["expenses"] = expenses.map { exp in
            ["id": exp.id.uuidString, "date": isoFormatter.string(from: exp.date), "item": exp.item, "amount": exp.amount, "notes": exp.notes, "isDeleted": exp.isDeleted, "deletedAt": exp.deletedAt.map { isoFormatter.string(from: $0) } as Any]
        }

        dict["properties"] = properties.map { prop in
            [
                "id": prop.id.uuidString,
                "roomNumber": prop.roomNumber,
                "landlord": prop.landlord,
                "unitType": prop.unitType,
                "rent": prop.rent,
                "deposit": prop.deposit,
                "prepayment": prop.prepayment,
                "leaseStart": prop.leaseStart,
                "leaseEnd": prop.leaseEnd,
                "leaseDuration": prop.leaseDuration,
                "rentDueDay": prop.rentDueDay,
                "waterMeterBase": prop.waterMeterBase,
                "electricMeterBase": prop.electricMeterBase,
                "propertyType": prop.propertyType,
                "notes": prop.notes,
                "isTerminated": prop.isTerminated,
                "terminationDate": prop.terminationDate.map { isoFormatter.string(from: $0) } as Any,
                "terminationReason": prop.terminationReason,
                "depositRefundStatus": prop.depositRefundStatus,
                "roomDamageStatus": prop.roomDamageStatus,
                "utilitySettlementStatus": prop.utilitySettlementStatus,
                "terminationPerson": prop.terminationPerson,
                "terminationPhone": prop.terminationPhone,
                "isDeleted": prop.isDeleted,
                "deletedAt": prop.deletedAt.map { isoFormatter.string(from: $0) } as Any,
                "createdAt": isoFormatter.string(from: prop.createdAt),
                "monthlyRentRecords": prop.monthlyRentRecords.map { ["id": $0.id.uuidString, "year": $0.year, "month": $0.month, "amount": $0.amount, "isPaid": $0.isPaid, "paidDate": $0.paidDate.map { isoFormatter.string(from: $0) } as Any] },
                "quarterlyUtilityRecords": prop.quarterlyUtilityRecords.map { ["id": $0.id.uuidString, "quarter": $0.quarter, "electricAmount": $0.electricAmount, "waterAmount": $0.waterAmount, "isSettled": $0.isSettled] },
                "utilitySettlementFrequency": prop.utilitySettlementFrequency,
                "utilitySettlementRecords": prop.utilitySettlementRecords.map { ["id":$0.id.uuidString,"year":$0.year,"period":$0.period,"frequency":$0.frequency,"electricAmount":$0.electricAmount,"waterAmount":$0.waterAmount,"balance":$0.balance,"isSettled":$0.isSettled,"statement":$0.statement,"settledAt":$0.settledAt.map{isoFormatter.string(from:$0)} as Any,"dueDate":$0.dueDate.map{isoFormatter.string(from:$0)} as Any] }
            ]
        }

        dict["todos"] = todos.map { item in
            [
                "id": item.id.uuidString,
                "content": item.content,
                "createdDate": isoFormatter.string(from: item.createdDate),
                "isCompleted": item.isCompleted,
                "completedDate": item.completedDate.map { isoFormatter.string(from: $0) } as Any,
                "sortOrder": item.sortOrder,
                "reminderDate": item.reminderDate.map { isoFormatter.string(from: $0) } as Any,
                "isDeleted": item.isDeleted,
                "deletedAt": item.deletedAt.map { isoFormatter.string(from: $0) } as Any
            ]
        }

        dict["utilityHistories"] = utilityHistories.map { h in
            ["id": h.id.uuidString, "roomNumber": h.roomNumber, "statement": h.statement, "settledAt": isoFormatter.string(from: h.settledAt), "includesMaster": h.includesMaster, "electricLatest": h.electricLatest, "waterLatest": h.waterLatest, "electricCost": h.electricCost, "waterCost": h.waterCost, "balance": h.balance, "sortOrder": h.sortOrder]
        }

        dict["payouts"] = payouts.map { p in
            [
                "id": p.id.uuidString,
                "roomNumber": p.roomNumber,
                "manager": p.manager,
                "unitType": p.unitType,
                "monthlyRent": p.monthlyRent as Any,
                "annualRent": p.annualRent,
                "deposit": p.deposit,
                "leaseStartDate": isoFormatter.string(from: p.leaseStartDate),
                "leaseEndDate": isoFormatter.string(from: p.leaseEndDate),
                "leaseDuration": p.leaseDuration,
                "rentFreeDays": p.rentFreeDays,
                "waterMeterBase": p.waterMeterBase,
                "electricMeterBase": p.electricMeterBase,
                "rentDueDay": p.rentDueDay,
                "paymentMethod": p.paymentMethod,
                "notes": p.notes,
                "isDeleted": p.isDeleted,
                "deletedAt": p.deletedAt.map { isoFormatter.string(from: $0) } as Any,
                "monthlyPayouts": p.monthlyPayouts.map { ["id": $0.id.uuidString, "month": $0.month, "amount": $0.amount, "isPaid": $0.isPaid, "paidDate": $0.paidDate.map { isoFormatter.string(from: $0) } as Any] },
                "monthlyUtilityRecords": p.monthlyUtilityRecords.map { ["id": $0.id.uuidString, "date": isoFormatter.string(from: $0.date), "waterAmount": $0.waterAmount, "electricAmount": $0.electricAmount, "isSettled": $0.isSettled] }
            ]
        }

        return try JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted)
    }

    // MARK: - 导入数据（P0-1: 分板块只删对应数据，P0-2: 先校验再导入，失败不修改数据库）
    enum ImportScope {
        case all
        case deals
        case properties
        case payouts
    }

    /// v1.13：异步导入（不阻塞主线程）。原 importAllData 的完成回调走 DispatchQueue.main.async，
    /// 若调用方在主线程 sem.wait() 同步等待会死锁（恢复卡死在 38% 的根因），此方法用 withCheckedContinuation 正确等待。
    func importAllDataAsync(from data: Data, modelContext: ModelContext, scope: ImportScope = .all) async -> (Bool, String) {
        await withCheckedContinuation { continuation in
            importAllData(from: data, modelContext: modelContext, scope: scope) { ok, message in
                continuation.resume(returning: (ok, message))
            }
        }
    }

    func importAllData(from data: Data, modelContext: ModelContext, scope: ImportScope = .all, completion: @escaping (Bool, String) -> Void) {
        // P2-13: 文件大小限制
        if data.count > maxBackupFileSize {
            completion(false, "备份文件过大（超过10MB）")
            return
        }

        // 第一步：解析和校验（不修改数据库）
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            completion(false, "备份文件格式错误")
            return
        }

        do {
            try validateRoot(dict, scope: scope)
            let dealsData = (dict["deals"] as? [[String: Any]]) ?? []
            let propertiesData = (dict["properties"] as? [[String: Any]]) ?? []
            let payoutsData = (dict["payouts"] as? [[String: Any]]) ?? []
            if scope == .all || scope == .deals { try dealsData.forEach(validateDeal) }
            if scope == .all || scope == .properties { try propertiesData.forEach(validateProperty) }
            if scope == .all || scope == .payouts { try payoutsData.forEach(validatePayout) }
        } catch {
            completion(false, error.localizedDescription)
            return
        }

        let dealsData = (dict["deals"] as? [[String: Any]]) ?? []
        let incomesData = (dict["incomes"] as? [[String: Any]]) ?? []
        let expensesData = (dict["expenses"] as? [[String: Any]]) ?? []
        let propertiesData = (dict["properties"] as? [[String: Any]]) ?? []
        let payoutsData = (dict["payouts"] as? [[String: Any]]) ?? []
        let todosData = (dict["todos"] as? [[String: Any]]) ?? []
        let historiesData = (dict["utilityHistories"] as? [[String: Any]]) ?? []

        // 第二步：校验通过后，在独立后台 ModelContext 中替换并保存。
        // 不跨线程传递传入的 ModelContext，只复用其 container，避免阻塞 SwiftUI 主线程。
        let container = modelContext.container
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let importContext = ModelContext(container)
            importContext.autosaveEnabled = false
            do {
                switch scope {
                case .all:
                    try clearDealsInternal(modelContext: importContext, save: false)
                    try clearPropertiesInternal(modelContext: importContext, save: false)
                    try clearPayoutsInternal(modelContext: importContext, save: false)
                    try clearTodosInternal(modelContext: importContext, save: false)
                case .deals:
                    try clearDealsInternal(modelContext: importContext, save: false)
                case .properties:
                    try clearPropertiesInternal(modelContext: importContext, save: false)
                case .payouts:
                    try clearPayoutsInternal(modelContext: importContext, save: false)
                }

                var importedCount = 0
            if scope == .all || scope == .deals {
                for d in dealsData {
                    let deal = DealRecord(
                        id: UUID(uuidString: strVal(d["id"])) ?? UUID(), date: try requiredDate(d["date"], field: "成交日期"),
                        roomNumber: strVal(d["roomNumber"]), landlord: strVal(d["landlord"]),
                        unitType: strVal(d["unitType"]),
                        leaseStart: try requiredDate(d["leaseStart"], field: "租期开始"),
                        leaseEnd: try requiredDate(d["leaseEnd"], field: "租期结束"),
                        leaseDuration: strVal(d["leaseDuration"]), rent: dbl(d["rent"]),
                        deposit: dbl(d["deposit"]), prepayment: dbl(d["prepayment"]),
                        rentDueDay: (d["rentDueDay"] is NSNull || d["rentDueDay"] == nil) ? nil : intVal(d["rentDueDay"]),
                        agentFeeLandlord: dbl(d["agentFeeLandlord"]),
                        agentFeeTenant: dbl(d["agentFeeTenant"]), totalFee: dbl(d["totalFee"]),
                        manager: strVal(d["manager"]), source: strVal(d["source"]), notes: strVal(d["notes"])
                    )
                    deal.isDeleted = d["isDeleted"] as? Bool ?? false
                    deal.deletedAt = parseDate(d["deletedAt"] as? String)
                    importContext.insert(deal)
                    importedCount += 1
                }
                for inc in incomesData {
                    let m = MiscIncome(id: UUID(uuidString: strVal(inc["id"])) ?? UUID(), date: try requiredDate(inc["date"], field: "其他收入日期"), item: strVal(inc["item"]), amount: dbl(inc["amount"]), notes: strVal(inc["notes"]))
                    m.isDeleted = inc["isDeleted"] as? Bool ?? false
                    m.deletedAt = parseDate(inc["deletedAt"] as? String)
                    importContext.insert(m)
                    importedCount += 1
                }
                for exp in expensesData {
                    let m = MiscExpense(id: UUID(uuidString: strVal(exp["id"])) ?? UUID(), date: try requiredDate(exp["date"], field: "其他支出日期"), item: strVal(exp["item"]), amount: dbl(exp["amount"]), notes: strVal(exp["notes"]))
                    m.isDeleted = exp["isDeleted"] as? Bool ?? false
                    m.deletedAt = parseDate(exp["deletedAt"] as? String)
                    importContext.insert(m)
                    importedCount += 1
                }
            }

            if scope == .all || scope == .properties {
                for p in propertiesData {
                    let prop = Property(
                        id: UUID(uuidString: strVal(p["id"])) ?? UUID(), roomNumber: strVal(p["roomNumber"]), landlord: strVal(p["landlord"]), unitType: strVal(p["unitType"]),
                        rent: dbl(p["rent"]), deposit: dbl(p["deposit"]), prepayment: dbl(p["prepayment"]),
                        leaseStart: strVal(p["leaseStart"]), leaseEnd: strVal(p["leaseEnd"]), leaseDuration: strVal(p["leaseDuration"]),
                        rentDueDay: intVal(p["rentDueDay"]), waterMeterBase: intVal(p["waterMeterBase"]),
                        electricMeterBase: intVal(p["electricMeterBase"]), propertyType: strVal(p["propertyType"]), notes: strVal(p["notes"]),
                        isTerminated: p["isTerminated"] as? Bool ?? false,
                        terminationDate: parseDate(p["terminationDate"] as? String),
                        terminationReason: strVal(p["terminationReason"]),
                        depositRefundStatus: strVal(p["depositRefundStatus"]),
                        roomDamageStatus: strVal(p["roomDamageStatus"]),
                        utilitySettlementStatus: strVal(p["utilitySettlementStatus"]),
                        terminationPerson: strVal(p["terminationPerson"]),
                        terminationPhone: strVal(p["terminationPhone"])
                    )
                    if let createdAt = parseDate(p["createdAt"] as? String) { prop.createdAt = createdAt }
                    prop.utilitySettlementFrequency = strVal(p["utilitySettlementFrequency"]).isEmpty ? "quarterly" : strVal(p["utilitySettlementFrequency"])
                    prop.isDeleted = p["isDeleted"] as? Bool ?? false
                    prop.deletedAt = parseDate(p["deletedAt"] as? String)
                    importContext.insert(prop)
                    for r in (p["utilitySettlementRecords"] as? [[String:Any]]) ?? [] { let rec=UtilitySettlementRecord(id:UUID(uuidString:strVal(r["id"])) ?? UUID(),year:intVal(r["year"]),period:intVal(r["period"]),frequency:strVal(r["frequency"]).isEmpty ? prop.utilitySettlementFrequency:strVal(r["frequency"]),electricAmount:dbl(r["electricAmount"]),waterAmount:dbl(r["waterAmount"]),balance:dbl(r["balance"]),isSettled:r["isSettled"] as? Bool ?? false,statement:strVal(r["statement"]),settledAt:parseDate(r["settledAt"] as? String),dueDate:parseDate(r["dueDate"] as? String));importContext.insert(rec);prop.utilitySettlementRecords.append(rec) }
                    for m in (p["monthlyRentRecords"] as? [[String: Any]]) ?? [] {
                        let rec = RentMonthRecord(id: UUID(uuidString: strVal(m["id"])) ?? UUID(), year: intVal(m["year"]), month: intVal(m["month"]), amount: dbl(m["amount"]), isPaid: m["isPaid"] as? Bool ?? false)
                        rec.paidDate = parseDate(m["paidDate"] as? String)
                        importContext.insert(rec)
                        prop.monthlyRentRecords.append(rec)
                    }
                    for q in (p["quarterlyUtilityRecords"] as? [[String: Any]]) ?? [] {
                        let rec = UtilityQuarterRecord(id: UUID(uuidString: strVal(q["id"])) ?? UUID(), quarter: intVal(q["quarter"]), electricAmount: dbl(q["electricAmount"]), waterAmount: dbl(q["waterAmount"]), isSettled: q["isSettled"] as? Bool ?? false)
                        importContext.insert(rec)
                        prop.quarterlyUtilityRecords.append(rec)
                    }
                    importedCount += 1
                }
            }

            if scope == .all {
                for h in try importContext.fetch(FetchDescriptor<UtilitySettlementHistory>()) { importContext.delete(h) }
                for h in historiesData {
                    importContext.insert(UtilitySettlementHistory(id: UUID(uuidString: strVal(h["id"])) ?? UUID(), roomNumber: strVal(h["roomNumber"]), statement: strVal(h["statement"]), settledAt: try requiredDate(h["settledAt"], field: "结算日期"), includesMaster: h["includesMaster"] as? Bool ?? false, electricLatest: dbl(h["electricLatest"]), waterLatest: dbl(h["waterLatest"]), electricCost: intVal(h["electricCost"]), waterCost: intVal(h["waterCost"]), balance: intVal(h["balance"]), sortOrder: intVal(h["sortOrder"])))
                    importedCount += 1
                }
                for item in todosData {
                    let todo = TodoItem(
                        id: UUID(uuidString: strVal(item["id"])) ?? UUID(), content: strVal(item["content"]),
                        createdDate: try requiredDate(item["createdDate"], field: "待办新增时间"),
                        isCompleted: item["isCompleted"] as? Bool ?? false,
                        completedDate: parseDate(item["completedDate"] as? String),
                        sortOrder: intVal(item["sortOrder"]),
                        reminderDate: parseDate(item["reminderDate"] as? String),
                        isDeleted: item["isDeleted"] as? Bool ?? false,
                        deletedAt: parseDate(item["deletedAt"] as? String)
                    )
                    importContext.insert(todo)
                    importedCount += 1
                }
            }

            if scope == .all || scope == .payouts {
                for p in payoutsData {
                    let payout = PayoutRecord(
                        id: UUID(uuidString: strVal(p["id"])) ?? UUID(), roomNumber: strVal(p["roomNumber"]), manager: strVal(p["manager"]), unitType: strVal(p["unitType"]),
                        leaseStartDate: try requiredDate(p["leaseStartDate"], field: "包租租期开始"),
                        leaseEndDate: try requiredDate(p["leaseEndDate"], field: "包租租期结束"),
                        leaseDuration: strVal(p["leaseDuration"]), rentFreeDays: intVal(p["rentFreeDays"]),
                        monthlyRent: p["monthlyRent"] is NSNull ? nil : dbl(p["monthlyRent"]),
                        annualRent: dbl(p["annualRent"]), deposit: dbl(p["deposit"]),
                        waterMeterBase: intVal(p["waterMeterBase"]), electricMeterBase: intVal(p["electricMeterBase"]),
                        rentDueDay: intVal(p["rentDueDay"]), paymentMethod: strVal(p["paymentMethod"]), notes: strVal(p["notes"])
                    )
                    payout.isDeleted = p["isDeleted"] as? Bool ?? false
                    payout.deletedAt = parseDate(p["deletedAt"] as? String)
                    importContext.insert(payout)
                    for m in (p["monthlyPayouts"] as? [[String: Any]]) ?? [] {
                        let rec = PayoutMonthRecord(id: UUID(uuidString: strVal(m["id"])) ?? UUID(), month: intVal(m["month"]), amount: dbl(m["amount"]), isPaid: m["isPaid"] as? Bool ?? false)
                        rec.paidDate = parseDate(m["paidDate"] as? String)
                        importContext.insert(rec)
                        payout.monthlyPayouts.append(rec)
                    }
                    for u in (p["monthlyUtilityRecords"] as? [[String: Any]]) ?? [] {
                        let rec = PayoutUtilityRecord(id: UUID(uuidString: strVal(u["id"])) ?? UUID(), date: try requiredDate(u["date"], field: "包租水电结算日期"), waterAmount: dbl(u["waterAmount"]), electricAmount: dbl(u["electricAmount"]), isSettled: u["isSettled"] as? Bool ?? false)
                        importContext.insert(rec)
                        payout.monthlyUtilityRecords.append(rec)
                    }
                    importedCount += 1
                }
            }

                try importContext.save()
                DispatchQueue.main.async { completion(true, "成功导入 \(importedCount) 条主记录") }
            } catch {
                importContext.rollback()
                DispatchQueue.main.async { completion(false, "导入失败，原数据已保留：\(error.localizedDescription)") }
            }
        }
    }

    // 从bundle中的initialData.json导入初始数据
    func importInitialData(modelContext: ModelContext, completion: @escaping (Bool, String) -> Void) {
        guard let url = Bundle.main.url(forResource: "initialData", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            print("initialData.json not found in bundle")
            completion(false, "未找到初始数据文件")
            return
        }
        importAllData(from: data, modelContext: modelContext, scope: .all, completion: completion)
    }

    // MARK: - 分板块导出（P0-3: 补齐字段，P1-5: 查询失败抛出错误）
    enum BackupType: String {
        case deals = "成交备份"
        case properties = "收租备份"
        case payouts = "包租备份"
        case total = "总备份"
    }

    func exportDeals(modelContext: ModelContext) throws -> Data {
        let deals = try modelContext.fetch(FetchDescriptor<DealRecord>())
        let incomes = try modelContext.fetch(FetchDescriptor<MiscIncome>())
        let expenses = try modelContext.fetch(FetchDescriptor<MiscExpense>())
        var dict: [String: Any] = [:]
        addBackupMetadata(to: &dict, type: "deals")
        dict["deals"] = deals.map { deal in
            ["id":deal.id.uuidString,"date": isoFormatter.string(from: deal.date), "roomNumber": deal.roomNumber, "landlord": deal.landlord, "unitType": deal.unitType, "leaseStart": isoFormatter.string(from: deal.leaseStart), "leaseEnd": isoFormatter.string(from: deal.leaseEnd), "leaseDuration": deal.leaseDuration, "rent": deal.rent, "deposit": deal.deposit, "prepayment": deal.prepayment, "rentDueDay": deal.rentDueDay as Any, "agentFeeLandlord": deal.agentFeeLandlord, "agentFeeTenant": deal.agentFeeTenant, "totalFee": deal.totalFee, "manager": deal.manager, "source": deal.source, "notes": deal.notes]
        }
        dict["incomes"] = incomes.map { ["id":$0.id.uuidString,"date": isoFormatter.string(from: $0.date), "item": $0.item, "amount": $0.amount, "notes": $0.notes] }
        dict["expenses"] = expenses.map { ["id":$0.id.uuidString,"date": isoFormatter.string(from: $0.date), "item": $0.item, "amount": $0.amount, "notes": $0.notes] }
        dict["properties"] = []
        dict["todos"] = []
        dict["payouts"] = []
        return try JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted)
    }

    func exportProperties(modelContext: ModelContext) throws -> Data {
        let properties = try modelContext.fetch(FetchDescriptor<Property>())
        var dict: [String: Any] = [:]
        addBackupMetadata(to: &dict, type: "properties")
        dict["deals"] = []
        dict["incomes"] = []
        dict["expenses"] = []
        dict["properties"] = properties.map { prop in
            ["id":prop.id.uuidString,"roomNumber":prop.roomNumber,"landlord":prop.landlord,"unitType":prop.unitType,"rent":prop.rent,"deposit":prop.deposit,"prepayment":prop.prepayment,"leaseStart":prop.leaseStart,"leaseEnd":prop.leaseEnd,"leaseDuration":prop.leaseDuration,"rentDueDay":prop.rentDueDay,"waterMeterBase":prop.waterMeterBase,"electricMeterBase":prop.electricMeterBase,"propertyType":prop.propertyType,"notes":prop.notes,"isTerminated":prop.isTerminated,"terminationDate":prop.terminationDate.map{isoFormatter.string(from:$0)} as Any,"terminationReason":prop.terminationReason,"depositRefundStatus":prop.depositRefundStatus,"roomDamageStatus":prop.roomDamageStatus,"utilitySettlementStatus":prop.utilitySettlementStatus,"terminationPerson":prop.terminationPerson,"terminationPhone":prop.terminationPhone,"createdAt":isoFormatter.string(from:prop.createdAt),"utilitySettlementFrequency":prop.utilitySettlementFrequency,"monthlyRentRecords":prop.monthlyRentRecords.map{["id":$0.id.uuidString,"year":$0.year,"month":$0.month,"amount":$0.amount,"isPaid":$0.isPaid,"paidDate":$0.paidDate.map{isoFormatter.string(from:$0)} as Any]},"quarterlyUtilityRecords":prop.quarterlyUtilityRecords.map{["id":$0.id.uuidString,"quarter":$0.quarter,"electricAmount":$0.electricAmount,"waterAmount":$0.waterAmount,"isSettled":$0.isSettled]},"utilitySettlementRecords":prop.utilitySettlementRecords.map{["id":$0.id.uuidString,"year":$0.year,"period":$0.period,"frequency":$0.frequency,"electricAmount":$0.electricAmount,"waterAmount":$0.waterAmount,"balance":$0.balance,"isSettled":$0.isSettled,"statement":$0.statement,"settledAt":$0.settledAt.map{isoFormatter.string(from:$0)} as Any,"dueDate":$0.dueDate.map{isoFormatter.string(from:$0)} as Any]}]
        }
        dict["todos"] = []
        dict["payouts"] = []
        return try JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted)
    }

    func exportPayouts(modelContext: ModelContext) throws -> Data {
        let payouts = try modelContext.fetch(FetchDescriptor<PayoutRecord>())
        var dict: [String: Any] = [:]
        addBackupMetadata(to: &dict, type: "payouts")
        dict["deals"] = []
        dict["incomes"] = []
        dict["expenses"] = []
        dict["properties"] = []
        dict["todos"] = []
        dict["payouts"] = payouts.map { p in
            ["id":p.id.uuidString,"roomNumber": p.roomNumber, "manager": p.manager, "unitType": p.unitType, "monthlyRent": p.monthlyRent as Any, "annualRent": p.annualRent, "deposit": p.deposit, "leaseStartDate": isoFormatter.string(from: p.leaseStartDate), "leaseEndDate": isoFormatter.string(from: p.leaseEndDate), "leaseDuration": p.leaseDuration, "rentFreeDays": p.rentFreeDays, "waterMeterBase": p.waterMeterBase, "electricMeterBase": p.electricMeterBase, "rentDueDay": p.rentDueDay, "paymentMethod": p.paymentMethod, "notes": p.notes, "monthlyPayouts": p.monthlyPayouts.map { ["id":$0.id.uuidString,"month": $0.month, "amount": $0.amount, "isPaid": $0.isPaid, "paidDate": $0.paidDate.map { isoFormatter.string(from: $0) } as Any] }, "monthlyUtilityRecords": p.monthlyUtilityRecords.map { ["id":$0.id.uuidString,"date": isoFormatter.string(from: $0.date), "waterAmount": $0.waterAmount, "electricAmount": $0.electricAmount, "isSettled": $0.isSettled] }]
        }
        return try JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted)
    }

    // MARK: - 分板块清空
    private func clearDealsInternal(modelContext: ModelContext, save: Bool = true) throws {
        for item in try modelContext.fetch(FetchDescriptor<DealRecord>()) { modelContext.delete(item) }
        for item in try modelContext.fetch(FetchDescriptor<MiscIncome>()) { modelContext.delete(item) }
        for item in try modelContext.fetch(FetchDescriptor<MiscExpense>()) { modelContext.delete(item) }
        if save { try modelContext.save() }
    }

    private func clearPropertiesInternal(modelContext: ModelContext, save: Bool = true) throws {
        for item in try modelContext.fetch(FetchDescriptor<Property>()) { modelContext.delete(item) }
        for item in try modelContext.fetch(FetchDescriptor<RentMonthRecord>()) { modelContext.delete(item) }
        for item in try modelContext.fetch(FetchDescriptor<UtilityQuarterRecord>()) { modelContext.delete(item) }
        for item in try modelContext.fetch(FetchDescriptor<UtilitySettlementRecord>()) { modelContext.delete(item) }
        if save { try modelContext.save() }
    }

    private func clearPayoutsInternal(modelContext: ModelContext, save: Bool = true) throws {
        for item in try modelContext.fetch(FetchDescriptor<PayoutRecord>()) { modelContext.delete(item) }
        for item in try modelContext.fetch(FetchDescriptor<PayoutMonthRecord>()) { modelContext.delete(item) }
        for item in try modelContext.fetch(FetchDescriptor<PayoutUtilityRecord>()) { modelContext.delete(item) }
        if save { try modelContext.save() }
    }

    private func clearTodosInternal(modelContext: ModelContext, save: Bool = true) throws {
        for item in try modelContext.fetch(FetchDescriptor<TodoItem>()) { modelContext.delete(item) }
        if save { try modelContext.save() }
    }

    // MARK: - 公开清空方法
    func clearDeals(modelContext: ModelContext) -> Bool { clear { try clearDealsInternal(modelContext: modelContext) } }
    func clearProperties(modelContext: ModelContext) -> Bool { clear { try clearPropertiesInternal(modelContext: modelContext) } }
    func clearPayouts(modelContext: ModelContext) -> Bool { clear { try clearPayoutsInternal(modelContext: modelContext) } }

    func clearAll(modelContext: ModelContext) -> Bool {
        clear {
            try clearDealsInternal(modelContext: modelContext, save: false)
            try clearPropertiesInternal(modelContext: modelContext, save: false)
            try clearPayoutsInternal(modelContext: modelContext, save: false)
            try clearTodosInternal(modelContext: modelContext, save: false)
            for item in try modelContext.fetch(FetchDescriptor<UtilitySettlementHistory>()) { modelContext.delete(item) }
            try modelContext.save()
        }
    }

    private func clear(_ action: () throws -> Void) -> Bool {
        do {
            try action()
            return true
        } catch {
            return false
        }
    }

    // MARK: - 备份文件管理
    /// v1.13 需求16：旧版分板块 JSON 统一收纳到 Documents/备份/旧版备份/<板块>/（不再在根目录生成 成交备份/收租备份/… 文件夹）
    /// 静态版本：供静态迁移方法使用
    static func staticBackupFolderURL(for type: BackupType) -> URL {
        let legacyRoot = DataRoot.url().appendingPathComponent("旧版备份", isDirectory: true)
        return legacyRoot.appendingPathComponent(type.rawValue, isDirectory: true)
    }

    /// 实例便捷入口（内部实现与静态版一致）
    func backupFolderURL(for type: BackupType) -> URL {
        DataBackupManager.staticBackupFolderURL(for: type)
    }

    /// v1.13 需求16：一次性目录迁移（App 启动时调用，幂等，可重复执行不产生重复文件）
    /// ① Documents 根目录的旧分区备份文件夹（成交备份/收租备份/包租备份/总备份）
    ///    → 整体迁入 备份/旧版备份/<板块>/；原目录内若只剩 JSON（已全部迁走）则删除空目录
    /// ② 备份/ 根目录下的 COS 配置 json → 备份/CosConfig/
    static func migrateLegacyDirectories() {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]

        // ① 旧分区备份：Documents/<板块>/ → 备份/旧版备份/<板块>/
        for type in [BackupType.deals, .properties, .payouts, .total] {
            let legacyDir = docs.appendingPathComponent(type.rawValue, isDirectory: true)
            guard fm.fileExists(atPath: legacyDir.path) else { continue }
            let destDir = staticBackupFolderURL(for: type)
            try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)
            if let names = try? fm.contentsOfDirectory(atPath: legacyDir.path) {
                for name in names where name.lowercased().hasSuffix(".json") {
                    let src = legacyDir.appendingPathComponent(name)
                    let dst = destDir.appendingPathComponent(name)
                    if fm.fileExists(atPath: dst.path) {
                        try? fm.removeItem(at: src)
                    } else {
                        try? fm.moveItem(at: src, to: dst)
                    }
                }
            }
            // 目录已空则删除（残留非 JSON 文件时保留原目录，避免误删用户文件）
            if let remain = try? fm.contentsOfDirectory(atPath: legacyDir.path), remain.isEmpty {
                try? fm.removeItem(at: legacyDir)
            }
        }

        // ② COS 配置备份 json：备份/ 根目录 → 备份/CosConfig/
        let cosDir = DataRoot.url().appendingPathComponent("CosConfig", isDirectory: true)
        try? fm.createDirectory(at: cosDir, withIntermediateDirectories: true)
        if let names = try? fm.contentsOfDirectory(atPath: DataRoot.url().path) {
            for name in names where name.lowercased().hasSuffix(".json") {
                let src = DataRoot.url().appendingPathComponent(name)
                let dst = cosDir.appendingPathComponent(name)
                if fm.fileExists(atPath: dst.path) {
                    try? fm.removeItem(at: src)
                } else {
                    try? fm.moveItem(at: src, to: dst)
                }
            }
        }
    }

    func listBackups(in type: BackupType) -> [URL] {
        let folder = backupFolderURL(for: type)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            print("创建备份目录失败: \(error)")
            return []
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension.lowercased() == "json" && isAllowedBackupURL($0, type: type) }.sorted { url1, url2 in
            let date1 = (try? url1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            let date2 = (try? url2.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            return date1 > date2
        }
    }

    // P2-13: 原子写入（先写临时文件，成功后替换）
    func saveBackup(_ data: Data, type: BackupType, name: String? = nil, isAuto: Bool = false) -> URL? {
        guard data.count <= maxBackupFileSize else {
            print("保存备份失败: 文件超过10MB")
            return nil
        }
        let folder = backupFolderURL(for: type)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            print("创建备份目录失败: \(error)")
            return nil
        }
        let prefix = isAuto ? "自动备份" : "手动备份"
        let typeName = type == .total ? "总备份" : type.rawValue
        let fileName = name ?? "\(prefix)-\(typeName)-\(timestampString()).json"
        let url = folder.appendingPathComponent(fileName)
        let tempURL = folder.appendingPathComponent("~\(fileName).tmp")

        do {
            // 先写临时文件
            try data.write(to: tempURL, options: .atomic)
            // 校验临时文件可读
            let verifyData = try Data(contentsOf: tempURL)
            if verifyData.count != data.count {
                try? FileManager.default.removeItem(at: tempURL)
                return nil
            }
            // 原子替换
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
            } else {
                try FileManager.default.moveItem(at: tempURL, to: url)
            }
            // 设置文件保护
            try (url as NSURL).setResourceValue(URLFileProtection.complete, forKey: .fileProtectionKey)

            // 如果是按天自动备份，删除7天前的自动备份
            if isAuto {
                cleanupOldAutoBackups(in: folder)
            }
            return url
        } catch {
            print("保存备份失败: \(error)")
            try? FileManager.default.removeItem(at: tempURL)
            return nil
        }
    }

    // 清理7天前的自动备份文件（只删除自动备份，不删除手动备份）
    private func cleanupOldAutoBackups(in folder: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date.distantPast
        for file in files {
            let name = file.lastPathComponent
            if name.hasPrefix("自动备份") {
                if let modDate = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   modDate < sevenDaysAgo {
                    try? FileManager.default.removeItem(at: file)
                    print("已删除7天前的自动备份: \(name)")
                }
            }
        }
    }

    func isAllowedBackupURL(_ url: URL, type: BackupType) -> Bool {
        let candidate = url.standardizedFileURL.resolvingSymlinksInPath()
        let folder = backupFolderURL(for: type).standardizedFileURL.resolvingSymlinksInPath()
        let parent = candidate.deletingLastPathComponent()
        return candidate.isFileURL && candidate.pathExtension.lowercased() == "json" && parent == folder
    }

    func backupFileSize(at url: URL, type: BackupType) throws -> Int64 {
        guard isAllowedBackupURL(url, type: type) else {
            throw BackupError.invalidData("备份文件路径无效")
        }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else {
            throw BackupError.invalidData("备份文件无效")
        }
        return Int64(values.fileSize ?? 0)
    }

    func deleteBackup(_ url: URL, type: BackupType) -> Bool {
        guard isAllowedBackupURL(url, type: type) else {
            print("删除备份失败: 文件不在指定备份目录")
            return false
        }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            print("删除备份失败: \(error)")
            return false
        }
    }

    private func timestampString() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy.M.d-H.mm"
        return df.string(from: Date())
    }
}

// 自动备份设置
struct AutoBackupSettings: Codable {
    var enabled: Bool = false
    var frequency: String = "day"
    var hour: Int = 23
    var minute: Int = 0
    var lastBackupDate: Date?
}
