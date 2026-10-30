import Foundation
import SwiftData
import WidgetKit

// 主 App → 小组件数据同步
// 启动/回前台/数据变化时调用 sync(modelContext:)，把看板指标写进 App Group，再刷新小组件。
enum WidgetDataSync {
    static let appGroupID = "group.com.gj.tg.shared"

    private static var appGroupDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    static func sync(modelContext: ModelContext) {
        let cal = Calendar.current
        let now = Date()
        let year = cal.component(.year, from: now)
        let month = cal.component(.month, from: now)

        // 本月时间区间
        let monthStart = cal.date(from: DateComponents(year: year, month: month, day: 1)) ?? now
        let nextMonth = cal.date(byAdding: DateComponents(month: 1), to: monthStart) ?? now

        // 1. 待办：未完成
        let todoReq = FetchDescriptor<TodoItem>(predicate: #Predicate { !$0.isCompleted && !$0.isDeleted })
        let todoCount = (try? modelContext.fetch(todoReq).count) ?? 0

        // 2. 未收租提醒（对齐看板「未收租提醒」口径）：从当前月向后滚动找第一个未收的应收期，
        //    该期交租日已逾期或 3 天内到期才计数（提前交下期租后提醒自动消失）
        let propReq = FetchDescriptor<Property>(predicate: #Predicate { !$0.isDeleted })
        let props = (try? modelContext.fetch(propReq)) ?? []
        var uncollected = 0
        var expiring = 0
        for p in props where !p.isTerminated {
            var targetYear = year
            var targetMonth = month
            for _ in 0..<12 {
                let rec = p.monthlyRentRecords.first { $0.year == targetYear && $0.month == targetMonth }
                if rec == nil || !rec!.isPaid { break }
                targetMonth += 1
                if targetMonth > 12 { targetMonth = 1; targetYear += 1 }
            }
            var comps = DateComponents()
            comps.year = targetYear
            comps.month = targetMonth
            comps.day = max(1, min(31, p.rentDueDay))
            let dueDate = cal.date(from: comps) ?? now
            let daysDiff = cal.dateComponents([.day], from: now, to: dueDate).day ?? 0
            if daysDiff <= 3 { uncollected += 1 }   // 逾期（负数）或 3 天内到期

            // 本月到期改为：30 天内到期（对齐看板「即将到期」口径）
            if let end = parseDate(p.leaseEnd) {
                let days = cal.dateComponents([.day], from: now, to: end).day ?? 0
                if days >= 0 && days <= 30 { expiring += 1 }
            }
        }

        // 3. 本月成交
        let dealReq = FetchDescriptor<DealRecord>(
            predicate: #Predicate { !$0.isDeleted && $0.date >= monthStart && $0.date < nextMonth }
        )
        let deals = (try? modelContext.fetch(dealReq)) ?? []
        let dealCount = deals.count
        let commission = deals.reduce(0.0) { $0 + $1.totalFee }

        // 4. 杂项收入/支出
        let incomeReq = FetchDescriptor<MiscIncome>(
            predicate: #Predicate { !$0.isDeleted && $0.date >= monthStart && $0.date < nextMonth }
        )
        let expenseReq = FetchDescriptor<MiscExpense>(
            predicate: #Predicate { !$0.isDeleted && $0.date >= monthStart && $0.date < nextMonth }
        )
        let miscIn = (try? modelContext.fetch(incomeReq)) ?? []
        let miscOut = (try? modelContext.fetch(expenseReq)) ?? []
        let miscInSum = miscIn.reduce(0.0) { $0 + $1.amount }
        let miscOutSum = miscOut.reduce(0.0) { $0 + $1.amount }
        let netIncome = commission + miscInSum - miscOutSum

        // 5. 最近包租应付：按起租月+付款方式+已付期数直接计算下一期（不依赖月计划记录是否存在）
        let payoutReq = FetchDescriptor<PayoutRecord>(predicate: #Predicate { !$0.isDeleted })
        let payouts = (try? modelContext.fetch(payoutReq)) ?? []
        var payoutRoom = "—"
        var payoutDate = "--/--"
        var payoutAmount = 0.0
        var nearest: (room: String, date: Date, amount: Double)?
        for pr in payouts {
            // 期数与每期月数
            let periodCount: Int
            switch pr.paymentMethod {
            case "季付": periodCount = 4
            case "半年付": periodCount = 2
            case "年付": periodCount = 1
            default: periodCount = 12
            }
            let periodMonths = 12 / periodCount
            let paidCount = pr.monthlyPayouts.filter { $0.isPaid }.count
            let nextIndex = paidCount
            guard nextIndex < periodCount else { continue } // 本期已全部付完
            // 实际付款月：起租月 + 期数偏移（回绕 1-12），日取起租日
            let startMonth = cal.component(.month, from: pr.leaseStartDate)
            let startDay = max(1, min(31, pr.rentDueDay))
            var payMonth = startMonth + nextIndex * periodMonths
            if payMonth > 12 { payMonth = ((payMonth - 1) % 12) + 1 }
            // 金额（含免租期摊抵，与打租计划一致）
            let monthlyRent = (pr.monthlyRent ?? 0) > 0 ? (pr.monthlyRent ?? 0) : pr.annualRent / 12.0
            var remainingFreeDays = pr.rentFreeDays
            let dailyRent = monthlyRent / 30.0
            var amount: Double = 0
            for i in 0..<periodCount {
                let totalDays = periodMonths * 30
                let freeDays = min(remainingFreeDays, totalDays)
                let payableDays = totalDays - freeDays
                if i == nextIndex { amount = dailyRent * Double(payableDays) }
                remainingFreeDays -= freeDays
            }
            // 年份：当年该期若已过本月1日，顺延到下一年
            var comps = DateComponents(year: year, month: payMonth, day: startDay)
            if let d = cal.date(from: comps), d < monthStart {
                comps.year = year + 1
            }
            guard let d = cal.date(from: comps) else { continue }
            if let nn = nearest {
                if d < nn.date { nearest = (pr.roomNumber, d, amount) }
            } else {
                nearest = (pr.roomNumber, d, amount)
            }
        }
        if let nn = nearest {
            payoutRoom = nn.room
            payoutDate = String(format: "%02d/%02d", cal.component(.month, from: nn.date), cal.component(.day, from: nn.date))
            payoutAmount = nn.amount
        }

        // 6. 本月剩余百分比
        let daysInMonth = cal.range(of: .day, in: .month, for: now)?.count ?? 30
        let dayOfMonth = cal.component(.day, from: now)
        let remain = max(0, min(100, Double(daysInMonth - dayOfMonth + 1) / Double(daysInMonth) * 100))

        // 写进 App Group
        guard let df = appGroupDefaults else { return }
        df.set(todoCount, forKey: "todoCount")
        df.set(uncollected, forKey: "uncollectedCount")
        df.set(expiring, forKey: "expiringCount")
        df.set(dealCount, forKey: "dealCount")
        df.set(netIncome, forKey: "netIncome")
        df.set(payoutRoom, forKey: "payoutRoom")
        df.set(payoutDate, forKey: "payoutDate")
        df.set(payoutAmount, forKey: "payoutAmount")
        df.set(remain, forKey: "monthRemainPercent")
        df.synchronize()

        WidgetCenter.shared.reloadAllTimelines()
    }

    // 宽松解析 yyyy-MM-dd / yyyy/MM/dd / yyyy年MM月dd日
    private static func parseDate(_ s: String) -> Date? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let fmts = ["yyyy-MM-dd", "yyyy/MM/dd", "yyyy.MM.dd", "yyyy年MM月dd日", "yyyy-MM-dd HH:mm:ss", "yyyy.M.d"]
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in fmts {
            f.dateFormat = fmt
            if let d = f.date(from: trimmed) { return d }
        }
        return nil
    }
}
