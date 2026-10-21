import SwiftUI
import SwiftData

struct MonthlySummary: Identifiable {
    let id = UUID()
    let year: Int
    let month: Int
    let dealCount: Int
    let agentFee: Double
    let miscIncome: Double
    let miscExpense: Double
    var netIncome: Double { agentFee + miscIncome - miscExpense }
}

struct ProfitView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<DealRecord> { !$0.isDeleted }) private var deals: [DealRecord]
    @Query(filter: #Predicate<MiscIncome> { !$0.isDeleted }) private var incomes: [MiscIncome]
    @Query(filter: #Predicate<MiscExpense> { !$0.isDeleted }) private var expenses: [MiscExpense]

    @State private var selectedYear: Int? = nil
    @State private var selectedMonth: Int? = nil
    @AppStorage("hide_profit_data") private var hideData = false

    private var calendar: Calendar { Calendar.current }

    private var monthlySummaries: [MonthlySummary] {
        var summaries: [MonthlySummary] = []

        // 确定要统计的年份范围
        let yearsToShow: [Int]
        if let y = selectedYear {
            yearsToShow = [y]
        } else {
            // 全部时间：收集所有数据中的年份
            var allYears = Set<Int>()
            deals.forEach { allYears.insert(calendar.component(.year, from: $0.date)) }
            incomes.forEach { allYears.insert(calendar.component(.year, from: $0.date)) }
            expenses.forEach { allYears.insert(calendar.component(.year, from: $0.date)) }
            yearsToShow = Array(allYears).sorted(by: >)
        }

        for year in yearsToShow {
            let monthsToShow: [Int]
            if let m = selectedMonth {
                monthsToShow = [m]
            } else {
                monthsToShow = Array(1...12)
            }
            for month in monthsToShow {
                let monthDeals = deals.filter {
                    let m = calendar.component(.month, from: $0.date)
                    let y = calendar.component(.year, from: $0.date)
                    return m == month && y == year && !$0.isDeleted
                }
                let monthIncomes = incomes.filter {
                    let m = calendar.component(.month, from: $0.date)
                    let y = calendar.component(.year, from: $0.date)
                    return m == month && y == year && !$0.isDeleted
                }
                let monthExpenses = expenses.filter {
                    let m = calendar.component(.month, from: $0.date)
                    let y = calendar.component(.year, from: $0.date)
                    return m == month && y == year && !$0.isDeleted
                }
                let agentFee = monthDeals.reduce(0) { $0 + $1.totalFee }
                let miscIncome = monthIncomes.reduce(0) { $0 + $1.amount }
                let miscExpense = monthExpenses.reduce(0) { $0 + $1.amount }
                if monthDeals.count > 0 || monthIncomes.count > 0 || monthExpenses.count > 0 {
                    summaries.append(MonthlySummary(
                        year: year,
                        month: month,
                        dealCount: monthDeals.count,
                        agentFee: agentFee,
                        miscIncome: miscIncome,
                        miscExpense: miscExpense
                    ))
                }
            }
        }
        return summaries.sorted(by: {
            if $0.year != $1.year { return $0.year > $1.year }
            return $0.month > $1.month
        })
    }

    private var filteredTotal: MonthlySummary {
        // 按筛选器统计KPI数据
        let filteredDeals: [DealRecord]
        let filteredIncomes: [MiscIncome]
        let filteredExpenses: [MiscExpense]

        if let y = selectedYear {
            if let m = selectedMonth {
                // 某年某月
                filteredDeals = deals.filter {
                    calendar.component(.year, from: $0.date) == y &&
                    calendar.component(.month, from: $0.date) == m && !$0.isDeleted
                }
                filteredIncomes = incomes.filter {
                    calendar.component(.year, from: $0.date) == y &&
                    calendar.component(.month, from: $0.date) == m && !$0.isDeleted
                }
                filteredExpenses = expenses.filter {
                    calendar.component(.year, from: $0.date) == y &&
                    calendar.component(.month, from: $0.date) == m && !$0.isDeleted
                }
            } else {
                // 某年全年
                filteredDeals = deals.filter { calendar.component(.year, from: $0.date) == y && !$0.isDeleted }
                filteredIncomes = incomes.filter { calendar.component(.year, from: $0.date) == y && !$0.isDeleted }
                filteredExpenses = expenses.filter { calendar.component(.year, from: $0.date) == y && !$0.isDeleted }
            }
        } else {
            // 全部时间
            filteredDeals = deals.filter { !$0.isDeleted }
            filteredIncomes = incomes.filter { !$0.isDeleted }
            filteredExpenses = expenses.filter { !$0.isDeleted }
        }

        return MonthlySummary(
            year: selectedYear ?? 0,
            month: selectedMonth ?? 0,
            dealCount: filteredDeals.count,
            agentFee: filteredDeals.reduce(0) { $0 + $1.totalFee },
            miscIncome: filteredIncomes.reduce(0) { $0 + $1.amount },
            miscExpense: filteredExpenses.reduce(0) { $0 + $1.amount }
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    // 筛选栏
                    HStack {
                        WheelYearMonthPicker(year: $selectedYear, month: $selectedMonth)
                        Spacer()
                        Button {
                            hideData.toggle()
                        } label: {
                            Image(systemName: hideData ? "eye.slash.fill" : "eye.fill")
                                .foregroundColor(.themeText3)
                                .frame(width: 24, height: 24)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)

                    // 汇总KPI卡片 - 按筛选器统计，2+2+1布局
                    VStack(spacing: 10) {
                        HStack(spacing: 10) {
                            SummaryCard(title: "成交", value: hideData ? "**" : "\(filteredTotal.dealCount)单", color: Color(hex: "F59E0B"), bgColor: Color(hex: "FFF3E0"))
                            SummaryCard(title: "中介费", value: hideData ? "**" : "¥\(Int(filteredTotal.agentFee))", color: Color(hex: "F59E0B"), bgColor: Color(hex: "FFF3E0"))
                        }
                        HStack(spacing: 10) {
                            SummaryCard(title: "杂项收入", value: hideData ? "**" : "¥\(Int(filteredTotal.miscIncome))", color: .themeRed, bgColor: Color(hex: "FDECEC"), valueHPadding: 4)
                            SummaryCard(title: "杂项支出", value: hideData ? "**" : "¥\(Int(filteredTotal.miscExpense))", color: .themeAccentDark, bgColor: Color(hex: "E8F5E9"), valueHPadding: 4)
                        }
                        SummaryCard(title: "净总收入", value: hideData ? "**" : "¥\(Int(filteredTotal.netIncome))", color: .themeRed, bgColor: Color(hex: "FDECEC"))
                    }
                    .padding(.horizontal)

                    // 月度汇总列表
                    LazyVStack(spacing: 10) {
                        ForEach(monthlySummaries) { summary in
                            MonthlySummaryRow(summary: summary, isCurrent: summary.month == (selectedMonth ?? calendar.component(.month, from: Date())), hideData: hideData)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 16)
                }
            }
            .background(Color.themeBg)
            .navigationTitle("汇总")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct MonthlySummaryRow: View {
    let summary: MonthlySummary
    let isCurrent: Bool
    var hideData: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(String(summary.year))年\(summary.month)月")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.themeText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Color(hex: "E8F0FE"))
                    .cornerRadius(.infinity)
                if isCurrent {
                    Text("本月")
                        .font(.system(size: 10))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.themeAccent)
                        .cornerRadius(.infinity)
                }
                Spacer()
                Text(verbatim: hideData ? "**" : "净收入 ¥\(Int(summary.netIncome))")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.themeRed)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color(hex: "FDECEC"))
                    .cornerRadius(.infinity)
            }

            HStack(spacing: 0) {
                SummaryItem(label: "成交", value: hideData ? "**" : "\(summary.dealCount)单")
                Spacer()
                SummaryItem(label: "中介费", value: hideData ? "**" : "¥\(Int(summary.agentFee))")
                Spacer()
                SummaryItem(label: "杂收入", value: hideData ? "**" : "¥\(Int(summary.miscIncome))")
                Spacer()
                SummaryItem(label: "支出", value: hideData ? "**" : "¥\(Int(summary.miscExpense))")
            }
        }
        .padding(14)
        .background(Color.themePanel)
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(isCurrent ? Color.themeAccent.opacity(0.5) : Color.themeBorder, lineWidth: isCurrent ? 1.5 : 1))
    }
}

struct SummaryItem: View {
    let label: String
    let value: String

    private var itemColor: Color {
        switch label {
        case "成交", "中介费": return Color(hex: "F59E0B")
        case "杂收入": return .themeRed
        case "支出": return .themeAccentDark
        default: return .themeText
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(itemColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(itemColor.opacity(0.1))
                .cornerRadius(.infinity)
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.themeText3)
        }
    }
}

struct SummaryCard: View {
    let title: String
    let value: String
    let color: Color
    var bgColor: Color? = nil
    var valueHPadding: CGFloat = 8

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.themeText2)
                .frame(minWidth: 56)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(Color(hex: "F0F0F0"))
                .cornerRadius(.infinity)
            HStack {
                Spacer(minLength: 0)
                Text(value)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(color)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, valueHPadding)
            .padding(.vertical, 8)
            .background(bgColor ?? color.opacity(0.1))
            .cornerRadius(.infinity)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color.themePanel)
        .cornerRadius(12)
    }
}
