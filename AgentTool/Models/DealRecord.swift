import Foundation
import SwiftData

@Model
final class DealRecord {
    var id: UUID
    var date: Date
    var roomNumber: String
    var landlord: String
    var unitType: String
    var leaseStart: Date
    var leaseEnd: Date
    var leaseDuration: String
    var rent: Double
    var deposit: Double
    var prepayment: Double
    var rentDueDay: Int? // 1-31, nil表示未设置
    var agentFeeLandlord: Double
    var agentFeeTenant: Double
    var totalFee: Double
    var manager: String
    var source: String
    var notes: String
    var isDeleted: Bool = false
    var deletedAt: Date? = nil

    init(id: UUID = UUID(), date: Date = Date(), roomNumber: String = "", landlord: String = "",
         unitType: String = "", leaseStart: Date = Date(), leaseEnd: Date = Date(),
         leaseDuration: String = "", rent: Double = 0, deposit: Double = 0,
         prepayment: Double = 0, rentDueDay: Int? = nil, agentFeeLandlord: Double = 0,
         agentFeeTenant: Double = 0, totalFee: Double = 0, manager: String = "",
         source: String = "", notes: String = "") {
        self.id = id
        self.date = date
        self.roomNumber = roomNumber
        self.landlord = landlord
        self.unitType = unitType
        self.leaseStart = leaseStart
        self.leaseEnd = leaseEnd
        self.leaseDuration = leaseDuration
        self.rent = rent
        self.deposit = deposit
        self.prepayment = prepayment
        self.rentDueDay = rentDueDay
        self.agentFeeLandlord = agentFeeLandlord
        self.agentFeeTenant = agentFeeTenant
        self.totalFee = totalFee
        self.manager = manager
        self.source = source
        self.notes = notes
    }
}

@Model
final class MiscIncome {
    var id: UUID
    var date: Date
    var item: String
    var amount: Double
    var notes: String
    var isDeleted: Bool = false
    var deletedAt: Date? = nil

    init(id: UUID = UUID(), date: Date = Date(), item: String = "", amount: Double = 0, notes: String = "") {
        self.id = id
        self.date = date
        self.item = item
        self.amount = amount
        self.notes = notes
    }
}

@Model
final class MiscExpense {
    var id: UUID
    var date: Date
    var item: String
    var amount: Double
    var notes: String
    var isDeleted: Bool = false
    var deletedAt: Date? = nil

    init(id: UUID = UUID(), date: Date = Date(), item: String = "", amount: Double = 0, notes: String = "") {
        self.id = id
        self.date = date
        self.item = item
        self.amount = amount
        self.notes = notes
    }
}
