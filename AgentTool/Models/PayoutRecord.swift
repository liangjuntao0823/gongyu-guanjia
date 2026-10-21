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

@Model
final class ProfitCalculation {
    var id: UUID
    var roomNumber: String
    var totalPackageAmount: Double
    var packageStart: Date
    var packageEnd: Date
    var vacancyDays: Int
    var tenantMonthlyRent: Double
    var rentStart: Date
    var rentEnd: Date
    var notes: String

    init(id: UUID = UUID(), roomNumber: String = "", totalPackageAmount: Double = 0,
         packageStart: Date = Date(), packageEnd: Date = Date(),
         vacancyDays: Int = 0, tenantMonthlyRent: Double = 0,
         rentStart: Date = Date(), rentEnd: Date = Date(), notes: String = "") {
        self.id = id
        self.roomNumber = roomNumber
        self.totalPackageAmount = totalPackageAmount
        self.packageStart = packageStart
        self.packageEnd = packageEnd
        self.vacancyDays = vacancyDays
        self.tenantMonthlyRent = tenantMonthlyRent
        self.rentStart = rentStart
        self.rentEnd = rentEnd
        self.notes = notes
    }

    var packageTotalDays: Int {
        Calendar.current.dateComponents([.day], from: packageStart, to: packageEnd).day ?? 0
    }

    var dailyCost: Double {
        packageTotalDays > 0 ? totalPackageAmount / Double(packageTotalDays) : 0
    }

    var vacancyCost: Double {
        dailyCost * Double(vacancyDays)
    }

    var rentedDays: Int {
        Calendar.current.dateComponents([.day], from: rentStart, to: rentEnd).day ?? 0
    }

    var rentalIncome: Double {
        rentedDays > 0 ? (tenantMonthlyRent / 30.0) * Double(rentedDays) : 0
    }

    var totalCost: Double {
        dailyCost * Double(rentedDays) + vacancyCost
    }

    var netProfit: Double {
        rentalIncome - totalCost
    }

    var profitStatus: String {
        netProfit >= 0 ? "盈利" : "亏损"
    }

    var remainingPackageCost: Double {
        totalPackageAmount - totalCost
    }
}
