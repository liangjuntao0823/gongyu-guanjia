import Foundation
import SwiftData

@MainActor
final class DataManager: ObservableObject {
    static let shared = DataManager()

    func monthlyStats(modelContext: ModelContext, month: Int, year: Int) -> (income: Double, expense: Double, net: Double) {
        let calendar = Calendar.current
        var totalIncome: Double = 0
        var totalExpense: Double = 0

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = 1
        guard let start = calendar.date(from: components),
              let end = calendar.date(byAdding: .month, value: 1, to: start) else {
            return (0, 0, 0)
        }

        // 直接在 SwiftData 层按月份过滤，避免把历史数据全部载入内存。
        let dealDescriptor = FetchDescriptor<DealRecord>(predicate: #Predicate { !$0.isDeleted && $0.date >= start && $0.date < end })
        totalIncome += ((try? modelContext.fetch(dealDescriptor)) ?? []).reduce(0) { $0 + $1.totalFee }

        let incomeDescriptor = FetchDescriptor<MiscIncome>(predicate: #Predicate { !$0.isDeleted && $0.date >= start && $0.date < end })
        totalIncome += ((try? modelContext.fetch(incomeDescriptor)) ?? []).reduce(0) { $0 + $1.amount }

        let expenseDescriptor = FetchDescriptor<MiscExpense>(predicate: #Predicate { !$0.isDeleted && $0.date >= start && $0.date < end })
        totalExpense += ((try? modelContext.fetch(expenseDescriptor)) ?? []).reduce(0) { $0 + $1.amount }

        return (totalIncome, totalExpense, totalIncome - totalExpense)
    }

    func dashboardStats(modelContext: ModelContext) -> DashboardStats {
        let calendar = Calendar.current
        let now = Date()
        let currentMonth = calendar.component(.month, from: now)
        let currentYear = calendar.component(.year, from: now)

        let propertyDescriptor = FetchDescriptor<Property>(predicate: #Predicate { !$0.isDeleted })
        let properties = (try? modelContext.fetch(propertyDescriptor)) ?? []
        // 工作台房源、应收租金与到期提醒只统计仍在租的房源。
        let activeRentalProperties = properties.filter { !$0.isTerminated }

        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
        let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart) ?? now

        let dealDescriptor = FetchDescriptor<DealRecord>(predicate: #Predicate { !$0.isDeleted && $0.date >= monthStart && $0.date < monthEnd })
        let monthlyDealRecords = (try? modelContext.fetch(dealDescriptor)) ?? []
        let totalDeals = (try? modelContext.fetchCount(FetchDescriptor<DealRecord>(predicate: #Predicate { !$0.isDeleted }))) ?? 0

        let profitDescriptor = FetchDescriptor<ProfitCalculation>()
        let profits = (try? modelContext.fetch(profitDescriptor)) ?? []

        let incomeDescriptor = FetchDescriptor<MiscIncome>(predicate: #Predicate { !$0.isDeleted && $0.date >= monthStart && $0.date < monthEnd })
        let incomes = (try? modelContext.fetch(incomeDescriptor)) ?? []

        let expenseDescriptor = FetchDescriptor<MiscExpense>(predicate: #Predicate { !$0.isDeleted && $0.date >= monthStart && $0.date < monthEnd })
        let expenses = (try? modelContext.fetch(expenseDescriptor)) ?? []

        // “管理”与“托管包租”分别按房源类型统计；兼容旧数据中的“普通”类型。
        let activeProperties = activeRentalProperties.filter { $0.typeDisplayName == "管理" }

        // 本月应收租金
        var monthlyRentReceivable: Double = 0
        var monthlyRentCollected: Double = 0
        for prop in activeRentalProperties {
            for record in prop.monthlyRentRecords {
                if record.year == currentYear && record.month == currentMonth {
                    monthlyRentReceivable += record.amount > 0 ? record.amount : prop.rent
                    if record.isPaid {
                        monthlyRentCollected += record.amount > 0 ? record.amount : prop.rent
                    }
                }
            }
            // 如果没有当月记录，按租金计入应收
            if !prop.monthlyRentRecords.contains(where: { $0.year == currentYear && $0.month == currentMonth }) {
                monthlyRentReceivable += prop.rent
            }
        }

        // 本月成交中介费
        var monthlyDealFee: Double = 0
        var monthlyDeals: Int = 0
        for deal in monthlyDealRecords {
            monthlyDealFee += deal.totalFee
            monthlyDeals += 1
        }

        // 包租盈亏
        let totalNetProfit = profits.reduce(0) { $0 + $1.netProfit }

        // 本月杂项收入
        var monthlyMiscIncome: Double = 0
        for inc in incomes {
            let comps = calendar.dateComponents([.month, .year], from: inc.date)
            if comps.month == currentMonth && comps.year == currentYear {
                monthlyMiscIncome += inc.amount
            }
        }

        // 本月杂项支出
        var monthlyMiscExpense: Double = 0
        for exp in expenses {
            let comps = calendar.dateComponents([.month, .year], from: exp.date)
            if comps.month == currentMonth && comps.year == currentYear {
                monthlyMiscExpense += exp.amount
            }
        }

        // 本月收入 = 中介费 + 杂项收入 - 杂项支出
        let monthlyNetIncome = monthlyDealFee + monthlyMiscIncome - monthlyMiscExpense

        // 即将到期（30天内），按剩余天数升序排列（越临近到期越靠前）
        var expiringSoon: [Property] = []
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy.M.d"
        for prop in activeRentalProperties {
            if let endDate = dateFormatter.date(from: prop.leaseEnd) {
                let days = calendar.dateComponents([.day], from: now, to: endDate).day ?? 0
                if days >= 0 && days <= 30 {
                    expiringSoon.append(prop)
                }
            }
        }
        expiringSoon.sort { prop1, prop2 in
            let days1 = (calendar.dateComponents([.day], from: now, to: dateFormatter.date(from: prop1.leaseEnd) ?? now).day ?? 0)
            let days2 = (calendar.dateComponents([.day], from: now, to: dateFormatter.date(from: prop2.leaseEnd) ?? now).day ?? 0)
            return days1 < days2
        }

        return DashboardStats(
            totalProperties: activeRentalProperties.count,
            activeProperties: activeProperties.count,
            managedProperties: activeRentalProperties.filter { $0.isManaged }.count,
            monthlyRentReceivable: monthlyRentReceivable,
            monthlyRentCollected: monthlyRentCollected,
            monthlyDealFee: monthlyDealFee,
            totalDeals: totalDeals,
            monthlyDeals: monthlyDeals,
            packageProfit: totalNetProfit,
            expiringSoon: expiringSoon,
            currentMonth: currentMonth,
            currentYear: currentYear,
            monthlyMiscIncome: monthlyMiscIncome,
            monthlyMiscExpense: monthlyMiscExpense,
            monthlyNetIncome: monthlyNetIncome
        )
    }
}

struct DashboardStats {
    var totalProperties: Int
    var activeProperties: Int
    var managedProperties: Int
    var monthlyRentReceivable: Double
    var monthlyRentCollected: Double
    var monthlyDealFee: Double
    var totalDeals: Int
    var monthlyDeals: Int
    var packageProfit: Double
    var expiringSoon: [Property]
    var currentMonth: Int
    var currentYear: Int
    var monthlyMiscIncome: Double
    var monthlyMiscExpense: Double
    var monthlyNetIncome: Double
}
