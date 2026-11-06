import Foundation
import SwiftData

@Model
final class PayoutRecord {
    var id: UUID
    var roomNumber: String
    var manager: String
    var unitType: String
    var leaseStartDate: Date
    var leaseEndDate: Date
    var leaseDuration: String
    var rentFreeDays: Int // 免租期（天）
    var monthlyRent: Double? // 月租金（可选，兼容旧数据）
    var annualRent: Double // 年租金（=月租金*12，自动计算）
    var deposit: Double
    var waterMeterBase: Int
    var electricMeterBase: Int
    var rentDueDay: Int // 付款日 1-31
    var paymentMethod: String // 月付, 季付, 半年付, 年付
    var monthlyPayouts: [PayoutMonthRecord]
    var monthlyUtilityRecords: [PayoutUtilityRecord]
    var notes: String
    var isDeleted: Bool = false
    var deletedAt: Date? = nil

    init(id: UUID = UUID(), roomNumber: String = "", manager: String = "", unitType: String = "",
         leaseStartDate: Date = Date(), leaseEndDate: Date = Date(),
         leaseDuration: String = "", rentFreeDays: Int = 0, monthlyRent: Double? = nil,
         annualRent: Double = 0,
         deposit: Double = 0, waterMeterBase: Int = 0, electricMeterBase: Int = 0,
         rentDueDay: Int = 1, paymentMethod: String = "月付",
         notes: String = "") {
        self.id = id
        self.roomNumber = roomNumber
        self.manager = manager
        self.unitType = unitType
        self.leaseStartDate = leaseStartDate
        self.leaseEndDate = leaseEndDate
        self.leaseDuration = leaseDuration
        self.rentFreeDays = rentFreeDays
        self.monthlyRent = monthlyRent
        self.annualRent = annualRent
        self.deposit = deposit
        self.waterMeterBase = waterMeterBase
        self.electricMeterBase = electricMeterBase
        self.rentDueDay = rentDueDay
        self.paymentMethod = paymentMethod
        self.monthlyPayouts = []
        self.monthlyUtilityRecords = []
        self.notes = notes
    }
}

@Model
final class PayoutMonthRecord {
    var id: UUID
    var month: Int
    var amount: Double
    var isPaid: Bool
    var paidDate: Date?

    init(id: UUID = UUID(), month: Int, amount: Double = 0, isPaid: Bool = false) {
        self.id = id
        self.month = month
        self.amount = amount
        self.isPaid = isPaid
        self.paidDate = nil
    }
}

@Model
final class PayoutUtilityRecord {
    var id: UUID
    var date: Date // 结算日期
    var waterAmount: Double
    var electricAmount: Double
    var isSettled: Bool

    init(id: UUID = UUID(), date: Date = Date(), waterAmount: Double = 0, electricAmount: Double = 0, isSettled: Bool = false) {
        self.id = id
        self.date = date
        self.waterAmount = waterAmount
        self.electricAmount = electricAmount
        self.isSettled = isSettled
    }
}

// v2.19：付租计划金额（与包租板块付租计划同口径，含免租期按天扣减）。
// 工作台提醒、付租计划展示统一走这里，避免“月租×期数月”与实际应付不一致。
extension PayoutRecord {
    var planPeriodCount: Int {
        switch paymentMethod {
        case "季付": return 4
        case "半年付": return 2
        case "年付": return 1
        default: return 12
        }
    }

    /// 第 index 期（0 起）应付金额：月租按 30 天折算，免租期从第一期起逐期扣减。
    func plannedAmount(forPeriodIndex index: Int) -> Double {
        let periodCount = planPeriodCount
        let periodMonths = 12 / periodCount
        let monthlyRent = (monthlyRent ?? 0) > 0 ? (monthlyRent ?? 0) : annualRent / 12.0
        let dailyRent = monthlyRent / 30.0
        var remainingFreeDays = max(rentFreeDays, 0)
        var amount = monthlyRent * Double(periodMonths)

        for _ in 0...max(index, 0) {
            let totalDays = periodMonths * 30
            let freeDays = min(remainingFreeDays, totalDays)
            amount = dailyRent * Double(totalDays - freeDays)
            remainingFreeDays -= freeDays
        }
        return amount
    }
}
