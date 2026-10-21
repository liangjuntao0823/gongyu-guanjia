import Foundation
import SwiftData

/// 从 SwiftData 生成当前 iPhone 的完整上传快照。
/// 现有业务模型没有 revision/变更日志，因此在服务端不存在同 ID 记录时按基线 0 上传；
/// 已经成功同步的实体由 SyncStore 记录其服务端 revision，后续再次预检不会重复计入。
@MainActor
enum SwiftDataSyncSnapshot {
    static func makePendingChanges(
        modelContext: ModelContext,
        deviceId: UUID,
        revisions: [String: Int64]
    ) throws -> [PendingChangeDTO] {
        var values: [(SyncEntityType, UUID, Date, [String: JSONValue])] = []

        for item in try modelContext.fetch(FetchDescriptor<Property>()) {
            values.append((.property, item.id, item.createdAt, [
                "roomNumber": .string(item.roomNumber), "landlord": .string(item.landlord),
                "unitType": .string(item.unitType), "rent": .number(item.rent),
                "deposit": .number(item.deposit), "prepayment": .number(item.prepayment),
                "leaseStart": .string(item.leaseStart), "leaseEnd": .string(item.leaseEnd),
                "leaseDuration": .string(item.leaseDuration), "rentDueDay": .integer(Int64(item.rentDueDay)),
                "waterMeterBase": .integer(Int64(item.waterMeterBase)), "electricMeterBase": .integer(Int64(item.electricMeterBase)),
                "propertyType": .string(item.propertyType), "notes": .string(item.notes),
                "createdAt": date(item.createdAt)
            ]))
        }
        for item in try modelContext.fetch(FetchDescriptor<RentMonthRecord>()) {
            values.append((.rentMonthRecord, item.id, item.paidDate ?? .distantPast, [
                "year": .integer(Int64(item.year)), "month": .integer(Int64(item.month)),
                "amount": .number(item.amount), "isPaid": .boolean(item.isPaid),
                "paidDate": optionalDate(item.paidDate)
            ]))
        }
        for item in try modelContext.fetch(FetchDescriptor<UtilityQuarterRecord>()) {
            values.append((.utilityQuarterRecord, item.id, .distantPast, [
                "quarter": .integer(Int64(item.quarter)), "electricAmount": .number(item.electricAmount),
                "waterAmount": .number(item.waterAmount), "isSettled": .boolean(item.isSettled)
            ]))
        }
        for item in try modelContext.fetch(FetchDescriptor<DealRecord>()) {
            values.append((.dealRecord, item.id, item.date, [
                "date": date(item.date), "roomNumber": .string(item.roomNumber), "landlord": .string(item.landlord),
                "unitType": .string(item.unitType), "leaseStart": date(item.leaseStart), "leaseEnd": date(item.leaseEnd),
                "leaseDuration": .string(item.leaseDuration), "rent": .number(item.rent), "deposit": .number(item.deposit),
                "prepayment": .number(item.prepayment), "rentDueDay": optionalInt(item.rentDueDay),
                "agentFeeLandlord": .number(item.agentFeeLandlord), "agentFeeTenant": .number(item.agentFeeTenant),
                "totalFee": .number(item.totalFee), "manager": .string(item.manager), "source": .string(item.source),
                "notes": .string(item.notes)
            ]))
        }
        for item in try modelContext.fetch(FetchDescriptor<MiscIncome>()) {
            values.append((.miscIncome, item.id, item.date, [
                "date": date(item.date), "item": .string(item.item), "amount": .number(item.amount), "notes": .string(item.notes)
            ]))
        }
        for item in try modelContext.fetch(FetchDescriptor<MiscExpense>()) {
            values.append((.miscExpense, item.id, item.date, [
                "date": date(item.date), "item": .string(item.item), "amount": .number(item.amount), "notes": .string(item.notes)
            ]))
        }
        for item in try modelContext.fetch(FetchDescriptor<PayoutRecord>()) {
            values.append((.payoutRecord, item.id, item.leaseStartDate, [
                "roomNumber": .string(item.roomNumber), "manager": .string(item.manager), "unitType": .string(item.unitType),
                "leaseStartDate": date(item.leaseStartDate), "leaseEndDate": date(item.leaseEndDate),
                "leaseDuration": .string(item.leaseDuration), "rentFreeDays": .integer(Int64(item.rentFreeDays)),
                "monthlyRent": optionalDouble(item.monthlyRent), "annualRent": .number(item.annualRent),
                "deposit": .number(item.deposit), "waterMeterBase": .integer(Int64(item.waterMeterBase)),
                "electricMeterBase": .integer(Int64(item.electricMeterBase)), "rentDueDay": .integer(Int64(item.rentDueDay)),
                "paymentMethod": .string(item.paymentMethod), "notes": .string(item.notes)
            ]))
        }
        for item in try modelContext.fetch(FetchDescriptor<PayoutMonthRecord>()) {
            values.append((.payoutMonthRecord, item.id, item.paidDate ?? .distantPast, [
                "month": .integer(Int64(item.month)), "amount": .number(item.amount),
                "isPaid": .boolean(item.isPaid), "paidDate": optionalDate(item.paidDate)
            ]))
        }
        for item in try modelContext.fetch(FetchDescriptor<PayoutUtilityRecord>()) {
            values.append((.payoutUtilityRecord, item.id, item.date, [
                "date": date(item.date), "waterAmount": .number(item.waterAmount),
                "electricAmount": .number(item.electricAmount), "isSettled": .boolean(item.isSettled)
            ]))
        }
        for item in try modelContext.fetch(FetchDescriptor<ProfitCalculation>()) {
            values.append((.profitCalculation, item.id, item.packageStart, [
                "roomNumber": .string(item.roomNumber), "totalPackageAmount": .number(item.totalPackageAmount),
                "packageStart": date(item.packageStart), "packageEnd": date(item.packageEnd),
                "vacancyDays": .integer(Int64(item.vacancyDays)), "tenantMonthlyRent": .number(item.tenantMonthlyRent),
                "rentStart": date(item.rentStart), "rentEnd": date(item.rentEnd), "notes": .string(item.notes)
            ]))
        }

        return values.compactMap { entityType, id, timestamp, payload in
            let key = SyncStore.entityKey(entityType: entityType, entityId: id)
            guard revisions[key] == nil else { return nil }
            return PendingChangeDTO(
                id: deterministicChangeId(deviceId: deviceId, entityType: entityType, entityId: id),
                entityType: entityType, entityId: id, baseRevision: 0, operation: .upsert,
                payload: payload, createdAt: timestamp == .distantPast ? Date() : timestamp, retryCount: 0
            )
        }
    }

    private static func date(_ value: Date) -> JSONValue { .string(ISO8601DateFormatter().string(from: value)) }
    private static func optionalDate(_ value: Date?) -> JSONValue { value.map(date) ?? .null }
    private static func optionalInt(_ value: Int?) -> JSONValue { value.map { .integer(Int64($0)) } ?? .null }
    private static func optionalDouble(_ value: Double?) -> JSONValue { value.map { .number($0) } ?? .null }

    private static func deterministicChangeId(deviceId: UUID, entityType: SyncEntityType, entityId: UUID) -> UUID {
        var bytes = Array((deviceId.uuidString + "|" + entityType.rawValue + "|" + entityId.uuidString).utf8)
        var hash1: UInt64 = 14_695_981_039_346_656_037
        var hash2: UInt64 = 10_995_116_282_11
        for byte in bytes { hash1 = (hash1 ^ UInt64(byte)) &* 1_099_511_628_211 }
        bytes.reverse()
        for byte in bytes { hash2 = (hash2 ^ UInt64(byte)) &* 1_099_511_628_211 }
        let raw: [UInt8] = (0..<8).map { UInt8(truncatingIfNeeded: hash1 >> ($0 * 8)) }
            + (0..<8).map { UInt8(truncatingIfNeeded: hash2 >> ($0 * 8)) }
        let tuple: uuid_t = (raw[0], raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[7], raw[8], raw[9], raw[10], raw[11], raw[12], raw[13], raw[14], raw[15])
        return UUID(uuid: tuple)
    }
}
