import SwiftUI
import SwiftData
import PhotosUI
import WebKit
import UIKit

// v2.19：成交 / 杂项 / 收租合同保存后广播，工作台立即重算，不必切 tab 或下拉刷新。
extension Notification.Name {
    static let dashboardDataChanged = Notification.Name("dashboardDataChanged")
}

struct DashboardView: View {
    let isActive: Bool

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var tabRouter: TabRouter
    @Query(filter: #Predicate<TodoItem> { !$0.isDeleted }, sort: [SortDescriptor(\TodoItem.createdDate, order: .reverse), SortDescriptor(\TodoItem.sortOrder)]) private var todos: [TodoItem]
    @State private var stats: DashboardStats?
    @State private var statsLoadFailed = false   // v2.9（P1-14）：统计加载失败不再静默显示 0
    // 提醒使用状态缓存，避免 SwiftUI 每次 body 重算时反复全表 fetch。
    @State private var rentReminders: [RentReminder] = []
    @State private var payoutReminders: [PayoutReminder] = []
    @State private var currentTime = Date()
    @State private var showUtility = false
    @State private var showAdmin = false   // v1.36 需求4：管理后台（App 内原生后台）
    @State private var showMeter = false   // v1.84：电表监控板块
    @State private var showAjk = false     // v1.85：安居客经纪人后台数据
    @State private var showF58 = false     // v1.99 b105：58同城找房（第一页约40条）
    @State private var showAI = false      // v1.85：AI 助手（对话驱动动作）
    @State private var showRentStat = false // v1.99：单月收租统计
    @State private var showMoreActions = false  // v1.84：更多收纳面板
    @State private var showQuickActionEdit = false // v1.84：快捷操作自定义排序
    // v2.21：在线更新——工作台显示当前版本号，有更新时后面跟橙色胶囊
    @ObservedObject private var updateCenter = UpdateCenter.shared
    @State private var showUpdateDetail = false
    @AppStorage("qa.dashboardOrder") private var qaDashOrder = ""
    @AppStorage("qa.moreOrder") private var qaMoreOrder = ""
    @State private var showAddDeal = false
    @State private var showAddRent = false
    @State private var showAddPayout = false
    @State private var showAddIncome = false
    @State private var showAddExpense = false
    @State private var showAddTodo = false
    @State private var showAllTodos = false
    @State private var completingTodo: TodoItem?
    @State private var editingTodo: TodoItem?
    @AppStorage("dashboardQuickActionsCollapsed") private var quickActionsCollapsed = false
    @AppStorage("dashboardKpiCollapsed") private var kpiCollapsed = false
    @AppStorage("dashboardTodosCollapsed") private var todosCollapsed = false
    @AppStorage("dashboardRentReminderCollapsed") private var rentReminderCollapsed = false
    @AppStorage("dashboardPayoutReminderCollapsed") private var payoutReminderCollapsed = false
    @AppStorage("dashboardExpiryCollapsed") private var expiryCollapsed = false
    @State private var quickCollectReminder: RentReminder?
    /// v1.98：快捷收租保存失败提示（修复"点收保存无效"无任何提示的问题）
    @State private var collectErrorText: String?
    @State private var payErrorText: String?
    @State private var quickCollectRent = ""
    // 包租快捷付租
    @State private var quickPayPayout: PayoutRecord?
    @State private var quickPayAmount = ""
    @State private var quickPayMonth = 0
    @State private var quickPayRecordMonth = 0
    @State private var showRefreshTip = false
    /// v1.3：工作台「新增房源」→ 直接弹出登记表单（保存后房源列表自动刷新）
    @State private var showAddHouse = false
    @State private var viewingProperty: Property?
    @State private var viewingPayout: PayoutRecord?

    // 顶栏用户信息
    @State private var avatarImage: UIImage?
    @State private var userTitle = "A0-米兰租赁梁涛13288251132"
    @State private var userSubtitle = "选择大于一切，专业省心租好房"
    @State private var showImagePicker = false
    @State private var showEditTitle = false
    @State private var showEditSubtitle = false
    @State private var editText = ""

    private let timer = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    // MARK: - v1.84 快捷操作自定义排序

    /// 工作台动作顺序写回（迁移用）
    private func writeDashOrder(_ ids: [String]) {
        if let data = try? JSONEncoder().encode(ids) {
            qaDashOrder = String(data: data, encoding: .utf8) ?? ""
        }
    }
    private func writeMoreOrder(_ ids: [String]) {
        if let data = try? JSONEncoder().encode(ids) {
            qaMoreOrder = String(data: data, encoding: .utf8) ?? ""
        }
    }

    /// 解析工作台动作顺序（空/损坏回退默认；旧缓存自动补入安居客/AI 助手，让新入口可见）
    /// 注意：仅计算不写回，持久化写回由 onAppear 的 migrateQuickActionOrdersIfNeeded 完成，
    /// 避免在视图渲染期间修改 @AppStorage 导致 SwiftUI 运行时崩溃。
    private var dashboardActionIDs: [String] {
        if qaDashOrder.isEmpty { return QuickActionRegistry.defaultDashboard }
        if let data = qaDashOrder.data(using: .utf8),
           let arr = try? JSONDecoder().decode([String].self, from: data) {
            var valid = arr.filter { QuickActionRegistry.meta($0) != nil }
            if valid.isEmpty { return QuickActionRegistry.defaultDashboard }
            // 迁移计算：旧缓存缺安居客/AI 助手 → 补入（先电表后，满 7 个后多出的收进「更多」）
            var more = moreActionIDs
            for id in ["ajk", "ai", "f58"] where !valid.contains(id) {
                if valid.count < 7 {
                    if let idx = valid.firstIndex(of: "meter") { valid.insert(id, at: idx + 1) }
                    else { valid.append(id) }
                } else {
                    if !more.contains(id) { more.insert(id, at: 0) }
                }
            }
            // 超 7 个的收进「更多」（旧缓存可能超过 7）
            while valid.count > 7 {
                guard let last = valid.last else { break }
                valid.removeLast()
                if !more.contains(last) { more.insert(last, at: 0) }
            }
            // v1.99：旧缓存补入「收租统计」入口（收进更多区，不挤占工作台）
            if !more.contains("rentStat") { more.append("rentStat") }
            return valid
        }
        return QuickActionRegistry.defaultDashboard
    }

    /// 旧版本快捷操作缓存自动迁移（补入安居客/AI 助手；超 7 个收进「更多」）
    /// 只在 onAppear 执行一次写回，避免渲染期间修改状态导致崩溃
    private func migrateQuickActionOrdersIfNeeded() {
        guard !qaDashOrder.isEmpty else { return }
        guard let data = qaDashOrder.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return }
        var valid = arr.filter { QuickActionRegistry.meta($0) != nil }
        if valid.isEmpty { return }
        var migrated = false
        var more = moreActionIDs
        for id in ["ajk", "ai", "f58"] where !valid.contains(id) {
            migrated = true
            if valid.count < 7 {
                if let idx = valid.firstIndex(of: "meter") { valid.insert(id, at: idx + 1) }
                else { valid.append(id) }
            } else {
                if !more.contains(id) { more.insert(id, at: 0) }
            }
        }
        while valid.count > 7 {
            guard let last = valid.last else { break }
            migrated = true
            valid.removeLast()
            if !more.contains(last) { more.insert(last, at: 0) }
        }
        // v1.99：旧缓存补入「收租统计」入口（更多区）
        if !more.contains("rentStat") {
            migrated = true
            more.append("rentStat")
        }
        if migrated {
            writeDashOrder(valid)
            writeMoreOrder(more)
        }
    }

    /// 解析「更多」收纳顺序
    private var moreActionIDs: [String] {
        if qaMoreOrder.isEmpty { return QuickActionRegistry.defaultMore }
        if let data = qaMoreOrder.data(using: .utf8),
           let arr = try? JSONDecoder().decode([String].self, from: data) {
            let valid = arr.filter { QuickActionRegistry.meta($0) != nil }
            return valid.isEmpty ? QuickActionRegistry.defaultMore : valid
        }
        return QuickActionRegistry.defaultMore
    }

    /// 动作 id → 图标/文案/颜色/触发闭包
    private func quickActionSpec(_ id: String) -> (imageName: String?, icon: String, label: String, color: Color, action: () -> Void)? {
        guard let meta = QuickActionRegistry.meta(id) else { return nil }
        let action: () -> Void
        switch id {
        case "deal": action = { showAddDeal = true }
        case "income": action = { showAddIncome = true }
        case "expense": action = { showAddExpense = true }
        case "rent": action = { showAddRent = true }
        case "todo": action = { showAddTodo = true }
        case "meter": action = { showMeter = true }
        case "ajk": action = { showAjk = true }
        case "f58": action = { showF58 = true }
        case "ai": action = { showAI = true }
        case "admin": action = { showAdmin = true }
        case "payout": action = { showAddPayout = true }
        case "utility": action = { showUtility = true }
        case "house": action = { showAddHouse = true }
        case "rentStat": action = { showRentStat = true }
        default: return nil
        }
        return (meta.imageName, meta.icon, meta.label, meta.color, action)
    }

    private var currentMonth: Int {
        Calendar.current.component(.month, from: currentTime)
    }

    private var daysRemainingInMonth: Int {
        let calendar = Calendar.current
        let now = currentTime
        let range = calendar.range(of: .day, in: .month, for: now)!
        let currentDay = calendar.component(.day, from: now)
        return range.count - currentDay
    }

    private var timeRemainingInMonth: (days: Int, hours: Int) {
        let calendar = Calendar.current
        let now = currentTime
        // 下个月第一天
        var components = calendar.dateComponents([.year, .month], from: now)
        components.month! += 1
        components.day = 1
        components.hour = 0
        components.minute = 0
        components.second = 0
        guard let nextMonth = calendar.date(from: components) else { return (0, 0) }
        let diff = calendar.dateComponents([.day, .hour], from: now, to: nextMonth)
        return (diff.day ?? 0, diff.hour ?? 0)
    }

    private var timeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: currentTime)
    }

    private var dateString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy年M月d日 EEEE"
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: currentTime)
    }

    private var dateStringShort: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日 EEE"
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: currentTime)
    }

    // 未收租提醒：以"下一应收期"为准——当月未收则关注当月；当月已收则关注下一期（如1号交租，本月已收后下月1号临近3天即提醒）。到期前3天内或已逾期均显示。
    private func loadRentReminders() -> [RentReminder] {
        let calendar = Calendar.current
        let now = Date()
        let currentMonth = calendar.component(.month, from: now)
        let currentYear = calendar.component(.year, from: now)

        var reminders: [RentReminder] = []
        let descriptor = FetchDescriptor<Property>(predicate: #Predicate { !$0.isDeleted })
        guard let properties = try? modelContext.fetch(descriptor) else { return [] }

        for prop in properties {
            if prop.isTerminated { continue }
            let dueDay = prop.rentDueDay

            // 确定关注的应收期：从当前月起向后滚动找第一个"未收"的期（无记录或未收即视为未收）。
            // v1.98：原逻辑只判断"当月已收→看下月"，不校验下月是否已收——提前交了下期租
            // （如10月收11月）后，提醒仍把11月当应收期、永不消失（"保存后待收租还在"根因）。
            var targetYear = currentYear
            var targetMonth = currentMonth
            for _ in 0..<12 {
                let rec = prop.monthlyRentRecords.first { $0.year == targetYear && $0.month == targetMonth }
                if rec == nil || !rec!.isPaid { break }
                targetMonth += 1
                if targetMonth > 12 { targetMonth = 1; targetYear += 1 }
            }

            // 计算距离目标期交租日的天数和逾期状态（按真实日期差，跨月也准确）
            var dateComps = DateComponents()
            dateComps.year = targetYear
            dateComps.month = targetMonth
            // v2.19：交租日 31 号遇到 30 天的月份会被落到次月 1 号，这里收敛到当月最后一天
            var monthFirstComps = DateComponents()
            monthFirstComps.year = targetYear
            monthFirstComps.month = targetMonth
            monthFirstComps.day = 1
            let monthFirst = calendar.date(from: monthFirstComps) ?? now
            let daysInMonth = calendar.range(of: .day, in: .month, for: monthFirst)?.count ?? 31
            dateComps.day = min(max(dueDay, 1), daysInMonth)
            let dueDate = calendar.date(from: dateComps) ?? now
            let daysDiff = calendar.dateComponents([.day], from: now, to: dueDate).day ?? 0
            let isOverdue = daysDiff < 0
            let overdueDays = isOverdue ? -daysDiff : 0
            let daysUntilDue = isOverdue ? 0 : daysDiff

            // 显示条件：逾期 或 3天内到期
            if isOverdue || daysUntilDue <= 3 {
                // 水电结算状态：直接读取对应应收期的结算计划（有记录且未结算→需结算；有记录且已结算→已结算；无记录→不需要）
                let utilityRecord = settlementRecord(for: prop, year: targetYear, month: targetMonth)
                let needUtilitySettlement = utilityRecord != nil && !utilityRecord!.isSettled
                let utilitySettled = utilityRecord?.isSettled ?? true

                reminders.append(RentReminder(
                    property: prop,
                    roomNumber: prop.roomNumber,
                    landlord: prop.landlord,
                    amount: prop.monthlyRentRecords.first { $0.year == targetYear && $0.month == targetMonth }?.amount ?? (prop.rent + prop.prepayment),
                    year: targetYear,
                    month: targetMonth,
                    dueDay: dueDay,
                    daysUntilDue: daysUntilDue,
                    isOverdue: isOverdue,
                    overdueDays: overdueDays,
                    needUtility: needUtilitySettlement,
                    utilitySettled: utilitySettled
                ))
            }
        }
        // 排序：逾期优先，逾期越久越靠上；然后是未逾期的，时间越临近越靠前
        return reminders.sorted { a, b in
            if a.isOverdue != b.isOverdue { return a.isOverdue && !b.isOverdue }
            if a.isOverdue && b.isOverdue { return a.overdueDays > b.overdueDays }
            return a.daysUntilDue < b.daysUntilDue
        }
    }

    // 获取指定年月的水电结算计划记录（按 dueDate 年月匹配）
    private func settlementRecord(for prop: Property, year: Int, month: Int) -> UtilitySettlementRecord? {
        let cal = Calendar.current
        return prop.utilitySettlementRecords.first { rec in
            guard let d = rec.dueDate else { return false }
            return cal.component(.year, from: d) == year && cal.component(.month, from: d) == month
        }
    }

    // 根据付款方式获取每期对应的月份（用于关联monthlyPayouts，与详情页一致）
    private func periodMonth(for payout: PayoutRecord, index: Int) -> Int {
        switch payout.paymentMethod {
        case "季付": return (index + 1) * 3
        case "半年付": return (index + 1) * 6
        case "年付": return 12
        default: return index + 1
        }
    }

    // 包租房付租提醒：离付租日3天内或已逾期的
    private func loadPayoutReminders() -> [PayoutReminder] {
        let calendar = Calendar.current
        let now = Date()

        var reminders: [PayoutReminder] = []
        let descriptor = FetchDescriptor<PayoutRecord>(predicate: #Predicate { !$0.isDeleted })
        guard let payouts = try? modelContext.fetch(descriptor) else { return [] }

        for payout in payouts {
            let startDate = payout.leaseStartDate
            let startMonth = calendar.component(.month, from: startDate)
            let startDay = calendar.component(.day, from: startDate)
            let periodCount = payout.paymentMethod == "月付" ? 12 : payout.paymentMethod == "季付" ? 4 : payout.paymentMethod == "半年付" ? 2 : 1
            let periodMonths = 12 / periodCount

            // 找到下一个未付的期
            for i in 0..<periodCount {
                // 查找记录用固定期数月（与详情页periodMonth一致）
                let recordMonth = periodMonth(for: payout, index: i)
                // 显示用实际付款月（考虑起租月）
                var displayMonth = startMonth + i * periodMonths
                if displayMonth > 12 { displayMonth = ((displayMonth - 1) % 12) + 1 }

                let record = payout.monthlyPayouts.first(where: { $0.month == recordMonth })
                if record == nil || !record!.isPaid {
                    // v2.19：金额优先用记录中的金额，否则直接取付租计划该期应付（已按免租期扣减）
                    let amount = (record?.amount ?? 0) > 0 ? record!.amount : payout.plannedAmount(forPeriodIndex: i)

                    // 计算付款日期（用于判断逾期和天数差）
                    var dateComps = DateComponents()
                    dateComps.year = calendar.component(.year, from: startDate) + (startMonth + i * periodMonths - 1) / 12
                    dateComps.month = displayMonth
                    // v2.19：付款日 31 号遇到 30 天的月份同样收敛到当月最后一天
                    var monthFirstComps = DateComponents()
                    monthFirstComps.year = dateComps.year
                    monthFirstComps.month = displayMonth
                    monthFirstComps.day = 1
                    let monthFirst = calendar.date(from: monthFirstComps) ?? startDate
                    let daysInMonth = calendar.range(of: .day, in: .month, for: monthFirst)?.count ?? 31
                    dateComps.day = min(max(startDay, 1), daysInMonth)
                    let payDate = calendar.date(from: dateComps) ?? startDate

                    // 使用日历准确计算天数差
                    let isOverdue = payDate < now
                    let rawDays = calendar.dateComponents([.day], from: now, to: payDate).day ?? 0
                    let daysDiff = abs(rawDays)

                    // 显示条件：逾期 或 3天内到期
                    if isOverdue || rawDays <= 7 {
                        reminders.append(PayoutReminder(
                            payout: payout,
                            roomNumber: payout.roomNumber,
                            paymentMethod: payout.paymentMethod,
                            amount: amount,
                            payMonth: displayMonth,
                            recordMonth: recordMonth,
                            payDay: startDay,
                            isOverdue: isOverdue,
                            daysDiff: daysDiff
                        ))
                    }
                    break
                }
            }
        }

        // 排序：逾期优先，逾期越久越靠上；然后是未逾期的，时间越临近越靠前
        return reminders.sorted { a, b in
            if a.isOverdue != b.isOverdue { return a.isOverdue && !b.isOverdue }
            if a.isOverdue && b.isOverdue { return a.daysDiff > b.daysDiff }
            return a.daysDiff < b.daysDiff
        }
    }

    // 快捷收租保存（v1.98：修复"点收保存无效"——①新建月度记录必须先 insert 进容器再 append，
    // 否则 SwiftData 保存抛异常被 try? 吞掉、界面无提示；②跨月根因：提醒列表显示的是"下一应收期"
    // （1号交租、提前几天就出现 11 月应交），原代码却写当前月（10 月）的记录，10 月已收时被覆盖、
    // 11 月记录根本没写——现按提醒携带的应收期 year/month 写入）
    private func saveQuickCollect(property: Property, year: Int, month: Int) -> Bool {
        collectErrorText = nil // 重试时清空上次错误

        // 1. 添加/更新应收期（year/month）的月度收租记录
        let rentAmount = Double(quickCollectRent) ?? property.rent
        // 检查该应收期是否已有记录，有则更新，无则新增
        if let existing = property.monthlyRentRecords.first(where: { $0.year == year && $0.month == month }) {
            existing.amount = rentAmount
            existing.isPaid = true
            existing.paidDate = Date()
        } else {
            let record = RentMonthRecord(year: year, month: month, amount: rentAmount, isPaid: true)
            record.paidDate = Date()
            modelContext.insert(record)
            property.monthlyRentRecords.append(record)
        }

        // 水电结算由收租详情表单的结算计划维护，快捷收租只记录租金
        do {
            try modelContext.save()
        } catch {
            collectErrorText = "保存失败：\(error.localizedDescription)"
            return false
        }
        refreshDashboard()
        quickCollectReminder = nil
        return true
    }

    // 计算距离到期的天数
    private func daysUntilExpiry(_ prop: Property) -> Int {
        let calendar = Calendar.current
        let now = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy.M.d"
        if let endDate = dateFormatter.date(from: prop.leaseEnd) {
            return max(0, calendar.dateComponents([.day], from: now, to: endDate).day ?? 0)
        }
        return 0
    }

    var body: some View {
        VStack(spacing: 12) {
            // 顶部用户栏（固定）
            HStack(spacing: 12) {
                // 头像（可替换，正方形圆角）
                Button {
                    showImagePicker = true
                } label: {
                    if let avatar = avatarImage {
                        Image(uiImage: avatar)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 52, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    } else {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(hex: "E8E8E8"))
                            .frame(width: 52, height: 52)
                            .overlay(
                                Image(systemName: "person.fill")
                                    .foregroundColor(.white)
                                    .font(.system(size: 22))
                            )
                    }
                }
                .buttonStyle(.plain)

                // 中间：标题+副标题
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Button {
                            editText = userTitle
                            showEditTitle = true
                        } label: {
                            Text(userTitle)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.themeText)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        versionBadge
                    }

                    // 副标题：X月还剩X天X小时，加油
                    HStack(spacing: 0) {
                        Text("\(currentMonth)月还剩")
                            .font(.system(size: 12))
                            .foregroundColor(.themeText2)
                        Text("\(timeRemainingInMonth.days)")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.themeAccentDark)
                        Text("天")
                            .font(.system(size: 12))
                            .foregroundColor(.themeText2)
                        Text("\(timeRemainingInMonth.hours)")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.themeAccentDark)
                        Text("小时，加油")
                            .font(.system(size: 12))
                            .foregroundColor(.themeText2)
                    }
                }

                Spacer()

                // 右边：时间+日期
                VStack(alignment: .trailing, spacing: 2) {
                    Text(timeString)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.themeText)
                        .fontDesign(.rounded)
                    Text(dateStringShort)
                        .font(.system(size: 12))
                        .foregroundColor(.themeText2)
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 4)

            // 以下内容可滑动
            ScrollView {
                if showRefreshTip {
                    HStack {
                        Spacer()
                        Text("已刷新")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.themeAccent)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(Color.themeAccentWeak)
                            .cornerRadius(12)
                        Spacer()
                    }
                    .padding(.bottom, 8)
                }
                LazyVStack(spacing: 16) {
                    // 快捷操作
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            DashboardSectionHeader(title: "快捷操作", subtitle: "", isCollapsed: $quickActionsCollapsed)
                            Spacer()
                            Button {
                                showQuickActionEdit = true
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: "arrow.up.arrow.down")
                                        .font(.system(size: 11, weight: .semibold))
                                    Text("排序")
                                        .font(.system(size: 12, weight: .semibold))
                                }
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(Color.themeBorder.opacity(0.4))
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                        if !quickActionsCollapsed {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 8) {
                                // 按自定义顺序渲染工作台动作（最多 7 个），第 8 位固定「更多」入口
                                ForEach(dashboardActionIDs, id: \.self) { id in
                                    if let spec = quickActionSpec(id) {
                                        QuickActionItem(icon: spec.icon, label: spec.label, color: spec.color, action: spec.action, imageName: spec.imageName)
                                    }
                                }
                                // 第 8 位固定「更多」入口
                                QuickActionItem(icon: "ellipsis.circle.fill", label: "更多", color: .themeText3) {
                                    showMoreActions = true
                                }
                            }
                        }
                    }
                    .padding(quickActionsCollapsed ? 10 : 16)
                    .background(Color.themePanel)
                    .cornerRadius(14)
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.themeBorder, lineWidth: 1))
                    .padding(.horizontal)

                    // KPI 看板
                VStack(spacing: 10) {
                    DashboardSectionHeader(title: "KPI 看板", subtitle: "", isCollapsed: $kpiCollapsed)
                    if statsLoadFailed {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("统计加载失败，当前数据可能不准确，请下拉刷新重试")
                                .font(.footnote)
                                .foregroundColor(.orange)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(10)
                        .padding(.horizontal)
                    }
                    if !kpiCollapsed {
                    // 第一行：收租房间、即将到期
                    HStack(spacing: 10) {
                        KpiCard(
                            label: "收租房间",
                            value: "\(stats?.totalProperties ?? 0)",
                            unit: "套",
                            foot: "",
                            style: .normal,
                            footBuilder: { hidden in
                                AnyView(
                                    HStack(spacing: 0) {
                                        Text("管理")
                                            .font(.system(size: 11))
                                            .foregroundColor(.themeText3)
                                        Text(verbatim: hidden ? "**" : "\(stats?.activeProperties ?? 0)")
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundColor(.themeAccentDark)
                                        Text("套 · 托管包租")
                                            .font(.system(size: 11))
                                            .foregroundColor(.themeText3)
                                        Text(verbatim: hidden ? "**" : "\(stats?.managedProperties ?? 0)")
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundColor(.themeAccentDark)
                                        Text("套")
                                            .font(.system(size: 11))
                                            .foregroundColor(.themeText3)
                                    }
                                )
                            },
                            storageKey: "active_rooms"
                        )
                        KpiCard(
                            label: "即将到期",
                            value: "\(stats?.expiringSoon.count ?? 0)",
                            unit: "套",
                            foot: "",
                            style: (stats?.expiringSoon.count ?? 0) > 0 ? .alert : .normal,
                            footBuilder: { _ in
                                AnyView(Text("30天内到期")
                                    .font(.system(size: 11))
                                    .foregroundColor(.themeText3))
                            },
                            storageKey: "expiring"
                        )
                    }

                    // 第二行：本月中介费、杂项收入
                    HStack(spacing: 10) {
                        KpiCard(
                            label: "本月中介费",
                            value: "\(Int(stats?.monthlyDealFee ?? 0))",
                            unit: "元",
                            foot: "",
                            style: .normal,
                            footBuilder: { hidden in
                                AnyView(
                                    HStack(spacing: 0) {
                                        Text("本月")
                                            .font(.system(size: 11))
                                            .foregroundColor(.themeText3)
                                        Text(verbatim: hidden ? "**" : "\(stats?.monthlyDeals ?? 0)")
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundColor(.themeAccentDark)
                                        Text("单")
                                            .font(.system(size: 11))
                                            .foregroundColor(.themeText3)
                                    }
                                )
                            },
                            valueColor: .themeRed,
                            storageKey: "monthly_fee"
                        )
                        KpiCard(
                            label: "杂项收入",
                            value: "\(Int(stats?.monthlyMiscIncome ?? 0))",
                            unit: "元",
                            foot: "",
                            style: .normal,
                            footBuilder: { _ in
                                AnyView(Text("本月")
                                    .font(.system(size: 11))
                                    .foregroundColor(.themeText3))
                            },
                            valueColor: .themeRed,
                            storageKey: "misc_income"
                        )
                    }

                    // 第三行：本月收入、杂项支出
                    HStack(spacing: 10) {
                        KpiCard(
                            label: "本月收入",
                            value: "\(Int(stats?.monthlyNetIncome ?? 0))",
                            unit: "元",
                            foot: "",
                            style: .normal,
                            footBuilder: { _ in
                                AnyView(Text("中介费+收入-支出")
                                    .font(.system(size: 11))
                                    .foregroundColor(.themeText3))
                            },
                            valueColor: .themeRed,
                            storageKey: "monthly_income"
                        )
                        KpiCard(
                            label: "杂项支出",
                            value: "\(Int(stats?.monthlyMiscExpense ?? 0))",
                            unit: "元",
                            foot: "",
                            style: .normal,
                            footBuilder: { _ in
                                AnyView(Text("本月")
                                    .font(.system(size: 11))
                                    .foregroundColor(.themeText3))
                            },
                            valueColor: Color(hex: "2E8B57"),
                            storageKey: "misc_expense"
                        )
                    }
                    }
                }
                .padding(kpiCollapsed ? 10 : 16)
                .background(Color.themePanel)
                .cornerRadius(14)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.themeBorder, lineWidth: 1))
                .padding(.horizontal)

                DashboardTodoSection(todos: todos, isCollapsed: $todosCollapsed, completingTodo: $completingTodo, editingTodo: $editingTodo, showAllTodos: $showAllTodos, modelContext: modelContext)
                DashboardRentSection(reminders: rentReminders, isCollapsed: $rentReminderCollapsed, quickCollectReminder: $quickCollectReminder, quickCollectRent: $quickCollectRent, viewingProperty: $viewingProperty)
                DashboardPayoutSection(reminders: payoutReminders, isCollapsed: $payoutReminderCollapsed, quickPayPayout: $quickPayPayout, quickPayAmount: $quickPayAmount, quickPayMonth: $quickPayMonth, quickPayRecordMonth: $quickPayRecordMonth, viewingPayout: $viewingPayout)
                DashboardExpirySection(properties: stats?.expiringSoon ?? [], isCollapsed: $expiryCollapsed, viewingProperty: $viewingProperty)

                    Spacer().frame(height: 16)
                }
                .padding(.top, 4)
            }
            .refreshable {
                try? modelContext.save()
                refreshDashboard()
                withAnimation {
                    showRefreshTip = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    withAnimation {
                        showRefreshTip = false
                    }
                }
            }
            .background(Color.themeBg)
        }
        .background(Color.themeBg)
        .onAppear {
            refreshDashboard()
            loadUserProfile()
            currentTime = Date()
            migrateQuickActionOrdersIfNeeded()
        }
        .onReceive(timer) { _ in
            guard isActive else { return }
            currentTime = Date()
        }
        .onReceive(NotificationCenter.default.publisher(for: .dashboardDataChanged)) { _ in
            refreshDashboard()
        }
        .onChange(of: isActive) { _, active in
            guard active else { return }
            currentTime = Date()
            refreshDashboard()
        }
        .sheet(isPresented: $showUpdateDetail) {
            if let a = updateCenter.available { UpdateDetailView(update: a) }
        }
        .sheet(isPresented: $showImagePicker) {
            ImagePickerView { image in
                if let image = image {
                    avatarImage = image
                    saveUserProfile()
                }
                showImagePicker = false
            }
        }
        .alert("编辑标题", isPresented: $showEditTitle) {
            TextField("请输入标题", text: $editText)
            Button("取消", role: .cancel) { }
            Button("保存") {
                userTitle = editText
                saveUserProfile()
            }
        }
        .alert("编辑副标题", isPresented: $showEditSubtitle) {
            TextField("请输入副标题", text: $editText)
            Button("取消", role: .cancel) { }
            Button("保存") {
                userSubtitle = editText
                saveUserProfile()
            }
        }
        .sheet(isPresented: $showUtility) {
            NavigationStack { UtilityView(onWriteSuccess: { refreshDashboard() }) }
        }
        .sheet(isPresented: $showMeter) {
            NavigationStack { MeterBoardView() }
        }
        .sheet(isPresented: $showAjk) {
            NavigationStack { AjkBoardView() }
        }
        .sheet(isPresented: $showF58) {
            NavigationStack { F58BoardView() }
        }
        .sheet(isPresented: $showAI) {
            NavigationStack { AIAssistantView() }
        }
        .sheet(isPresented: $showRentStat) {
            RentStatView()
        }
        .sheet(isPresented: $showMoreActions, onDismiss: { showMoreActions = false }) {
            MoreActionsSheet(specs: moreActionIDs.compactMap { quickActionSpec($0) })
        }
        .sheet(isPresented: $showQuickActionEdit, onDismiss: { showQuickActionEdit = false }) {
            QuickActionEditSheet(dashOrder: $qaDashOrder, moreOrder: $qaMoreOrder)
        }
        .sheet(isPresented: $showAdmin) {
            // v1.37：App 内管理后台改用原生后台（获客分析/分享记录/桶管理），完全免登录、不走网页、无缓存问题；
            // 需要手机/电脑自适应网页版时，在原生后台右上角「safari」一键跳浏览器（带免登录口令）
            AdminDashboardView()
        }
        .sheet(isPresented: $showAddDeal) {
            NavigationStack { AddDealView() }
        }
        .sheet(isPresented: $showAddHouse) {
            HouseEditView(house: nil)
        }
        .sheet(isPresented: $showAddRent) {
            NavigationStack { AddPropertyView() }
        }
        .sheet(isPresented: $showAddPayout) {
            NavigationStack { AddPayoutView() }
        }
        .sheet(isPresented: $showAddIncome) {
            NavigationStack { AddMiscView(type: .income) }
        }
        .sheet(isPresented: $showAddExpense) {
            NavigationStack { AddMiscView(type: .expense) }
        }
        .sheet(isPresented: $showAddTodo) {
            TodoFormView()
        }
        .sheet(isPresented: $showAllTodos) {
            NavigationStack { AllTodosView() }
        }
        .sheet(item: $editingTodo) { TodoFormView(item: $0) }
        .alert("确认已办？", isPresented: Binding(get: { completingTodo != nil }, set: { if !$0 { completingTodo = nil } })) {
            Button("取消", role: .cancel) { completingTodo = nil }
            Button("确认") {
                completingTodo?.isCompleted = true
                completingTodo?.completedDate = Date()
                try? modelContext.save()
                LocalNotificationManager.shared.rebuildAll(modelContext: modelContext)
                completingTodo = nil
            }
        } message: {
            Text("完成后将归档到“已办”。")
        }
        .sheet(item: $quickCollectReminder) { reminder in
            QuickCollectSheet(property: reminder.property,
                              year: reminder.year, month: reminder.month,
                              rentText: $quickCollectRent, errorText: $collectErrorText, onSave: {
                saveQuickCollect(property: reminder.property, year: reminder.year, month: reminder.month)
            })
        }
        // v1.98：快捷收租保存失败提示（失败时弹窗不关闭，修正后可重试）
        .alert("保存失败", isPresented: Binding(get: { collectErrorText != nil }, set: { if !$0 { collectErrorText = nil } })) {
            Button("好", role: .cancel) { collectErrorText = nil }
        } message: {
            Text(collectErrorText ?? "")
        }
        .sheet(item: $quickPayPayout) { payout in
            QuickPaySheet(payout: payout, amountText: $quickPayAmount, payMonth: quickPayMonth, recordMonth: quickPayRecordMonth, errorText: $payErrorText, onSave: {
                let record = payout.monthlyPayouts.first(where: { $0.month == quickPayRecordMonth })
                if let r = record {
                    r.isPaid = true
                    r.paidDate = Date()
                    r.amount = Double(quickPayAmount) ?? r.amount
                } else {
                    let newRecord = PayoutMonthRecord(month: quickPayRecordMonth, amount: Double(quickPayAmount) ?? 0, isPaid: true)
                    newRecord.paidDate = Date()
                    modelContext.insert(newRecord)
                    payout.monthlyPayouts.append(newRecord)
                }
                // v2.19：付租保存失败不再静默，弹窗内红字提示并允许重试
                do {
                    try modelContext.save()
                } catch {
                    payErrorText = "保存失败：\(error.localizedDescription)"
                    return false
                }
                payErrorText = nil
                refreshDashboard()
                quickPayPayout = nil
                return true
            })
        }
        .sheet(item: $viewingProperty) { prop in
            NavigationStack {
                PropertyDetailView(property: prop)
            }
        }
        .sheet(item: $viewingPayout) { payout in
            NavigationStack {
                PayoutDetailView(payout: payout)
            }
        }
        .navigationTitle("工作台")
        .navigationBarHidden(true)
    }

    private func refreshDashboard() {
        // v2.9（P1-14）：统计读取失败必须显性提示，不再静默按 0 显示
        do {
            stats = try DataManager.shared.dashboardStats(modelContext: modelContext)
            statsLoadFailed = false
        } catch {
            stats = nil
            statsLoadFailed = true
            BackupLogStore.log(category: "统计", action: "工作台统计", result: "失败", detail: error.localizedDescription)
        }
        rentReminders = loadRentReminders()
        payoutReminders = loadPayoutReminders()
    }

    // MARK: - 用户信息保存/加载
    private func loadUserProfile() {
        let defaults = UserDefaults.standard
        if let title = defaults.string(forKey: "userTitle") {
            userTitle = title
        }
        if let subtitle = defaults.string(forKey: "userSubtitle") {
            userSubtitle = subtitle
        }
        if let imageData = defaults.data(forKey: "userAvatar") {
            avatarImage = UIImage(data: imageData)
        }
    }

    private func saveUserProfile() {
        let defaults = UserDefaults.standard
        defaults.set(userTitle, forKey: "userTitle")
        defaults.set(userSubtitle, forKey: "userSubtitle")
        if let image = avatarImage, let data = image.jpegData(compressionQuality: 0.8) {
            defaults.set(data, forKey: "userAvatar")
        }
    }
}


private struct DashboardSectionHeader<Trailing: View>: View {
    let title: String; let subtitle: String; @Binding var isCollapsed: Bool; @ViewBuilder let trailing: () -> Trailing
    init(title: String, subtitle: String, isCollapsed: Binding<Bool>, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title; self.subtitle = subtitle; self._isCollapsed = isCollapsed; self.trailing = trailing
    }
    var body: some View {
        HStack(spacing: 8) {
            HStack { SectionTitle(title: title, subtitle: subtitle); Spacer(minLength: 8) }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation { isCollapsed.toggle() } }
            trailing()
        }
        .frame(minHeight: 28)
    }
}

private struct DashboardSectionCard<Content: View, Trailing: View>: View {
    let title: String; let subtitle: String; @Binding var isCollapsed: Bool; @ViewBuilder let trailing: () -> Trailing; @ViewBuilder let content: () -> Content
    init(title: String, subtitle: String, isCollapsed: Binding<Bool>, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.subtitle = subtitle; self._isCollapsed = isCollapsed; self.trailing = trailing; self.content = content
    }
    var body: some View {
        VStack(alignment: .leading, spacing: isCollapsed ? 0 : 10) {
            DashboardSectionHeader(title: title, subtitle: subtitle, isCollapsed: $isCollapsed, trailing: trailing)
            if !isCollapsed { content() }
        }
        .padding(isCollapsed ? 10 : 16).background(Color.themePanel).cornerRadius(14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.themeBorder, lineWidth: 1)).padding(.horizontal)
    }
}

private struct DashboardTodoSection: View {
    let todos: [TodoItem]; @Binding var isCollapsed: Bool; @Binding var completingTodo: TodoItem?; @Binding var editingTodo: TodoItem?; @Binding var showAllTodos: Bool; let modelContext: ModelContext
    private var pending: [TodoItem] { todos.filter { !$0.isCompleted }.sorted { $0.sortOrder < $1.sortOrder } }
    var body: some View {
        DashboardSectionCard(title: "待办事项", subtitle: "\(pending.count)项", isCollapsed: $isCollapsed, trailing: {
            Button("全部待办") { showAllTodos = true }.font(.system(size: 12, weight: .semibold)).foregroundColor(.themeAccentDark)
        }) {
            if pending.isEmpty { Text("暂无待办事项").font(.system(size: 13)).foregroundColor(.themeText3) }
            else {
                List {
                    ForEach(pending) { item in
                        TodoRow(item: item, showComplete: true) { completingTodo = item }
                            .contentShape(Rectangle()).onTapGesture { editingTodo = item }
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                            .listRowBackground(Color.clear)
                    }
                    .onMove(perform: move)
                }
                .listStyle(.plain)
                .scrollDisabled(true)
                .frame(height: pending.reduce(CGFloat(0)) { total, item in
                    total + Self.rowHeight(for: item.content)
                })
            }
        }
    }
    private func move(from source: IndexSet, to destination: Int) {
        var ordered = pending; ordered.move(fromOffsets: source, toOffset: destination)
        for (index, item) in ordered.enumerated() { item.sortOrder = index }; try? modelContext.save()
    }

    /// v2.19：按真实文本宽度测行高（原来按 22 字两档硬算，长待办会被裁半行）。
    /// 宽度取保守值，宁可多留 4pt 也不裁字。
    fileprivate static func rowHeight(for content: String) -> CGFloat {
        let textWidth: CGFloat = 250
        let font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        let rect = (content as NSString).boundingRect(
            with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        )
        // 内容行 + 间距5 + 日期行17 + 行内上下8 + listRowInsets上下8 + 余量4
        return ceil(rect.height) + 42
    }
}

private struct DashboardRentSection: View {
    let reminders: [RentReminder]; @Binding var isCollapsed: Bool
    @Binding var quickCollectReminder: RentReminder?; @Binding var quickCollectRent: String; @Binding var viewingProperty: Property?

    var body: some View {
        DashboardSectionCard(title: "未收租提醒", subtitle: "\(reminders.count)套", isCollapsed: $isCollapsed) {
            ForEach(reminders) { reminder in
                HStack(spacing: 10) {
                    VStack(spacing: 2) { Text("\(reminder.dueDay)").font(.system(size: 18, weight: .bold)); Text("号交租").font(.system(size: 10)) }
                        .frame(width: 44).padding(.vertical, 6).background(reminder.isOverdue ? Color(hex: "FDF0F0") : Color(hex: "FBF1DE")).cornerRadius(8)
                    VStack(alignment: .leading, spacing: 3) { Text(reminder.roomNumber).font(.system(size: 16, weight: .bold)); Text("房东: \(reminder.landlord)").font(.system(size: 13, weight: .bold)).foregroundColor(.themeText2) }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(verbatim: "¥\(Int(reminder.amount))").font(.system(size: 14, weight: .bold))
                        if reminder.needUtility { Text("✅需结算水电").font(.system(size: 11, weight: .semibold)).foregroundColor(.themeAmber) }
                    }
                    Button("收") { quickCollectReminder = reminder; quickCollectRent = String(Int(reminder.amount)) }
                        .font(.system(size: 13, weight: .semibold)).foregroundColor(.white).frame(width: 36, height: 36).background(Circle().fill(Color.themeAccent))
                }.contentShape(Rectangle()).onTapGesture { viewingProperty = reminder.property }
            }
        }
    }
}

private struct DashboardPayoutSection: View {
    let reminders: [PayoutReminder]; @Binding var isCollapsed: Bool; @Binding var quickPayPayout: PayoutRecord?; @Binding var quickPayAmount: String; @Binding var quickPayMonth: Int; @Binding var quickPayRecordMonth: Int; @Binding var viewingPayout: PayoutRecord?
    var body: some View {
        DashboardSectionCard(title: "包租房付租提醒", subtitle: "\(reminders.count)套", isCollapsed: $isCollapsed) {
            ForEach(reminders) { reminder in
                PayoutReminderRow(reminder: reminder, onPay: {
                    quickPayPayout = reminder.payout; quickPayAmount = String(Int(reminder.amount)); quickPayMonth = reminder.payMonth; quickPayRecordMonth = reminder.recordMonth
                }, onTap: { viewingPayout = reminder.payout })
            }
        }
    }
}

private struct DashboardExpirySection: View {
    let properties: [Property]; @Binding var isCollapsed: Bool; @Binding var viewingProperty: Property?
    var body: some View {
        DashboardSectionCard(title: "即将到期", subtitle: "\(properties.count)套", isCollapsed: $isCollapsed) {
            ForEach(properties, id: \.id) { prop in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(prop.roomNumber).font(.system(size: 20, weight: .bold))
                            Text("到期:\(prop.leaseEnd)").font(.system(size: 14)).foregroundColor(.themeText2)
                        }
                        HStack(spacing: 6) {
                            Text("房东: \(prop.landlord)")
                            Text(verbatim: "租金: ¥\(Int(prop.rent))")
                            Text(verbatim: "押金: ¥\(Int(prop.deposit))")
                        }.font(.system(size: 14, weight: .medium)).foregroundColor(.themeText3)
                    }
                    Spacer()
                    if let endDate = DashboardExpirySection.parseLeaseEnd(prop.leaseEnd) {
                        let days = Calendar.current.dateComponents([.day], from: Date(), to: endDate).day ?? 0
                        Text(days >= 0 ? "还剩\(days)天" : "已超期\(-days)天")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(days >= 0 ? .themeAccentDark : .red)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle()).onTapGesture { viewingProperty = prop }
            }
        }
    }
    private static func parseLeaseEnd(_ s: String) -> Date? {
        let f = DateFormatter(); f.dateFormat = "yyyy.M.d"; return f.date(from: s)
    }
}

// MARK: - 未收租提醒模型
struct RentReminder: Identifiable {
    let id = UUID()
    let property: Property
    let roomNumber: String
    let landlord: String
    let amount: Double
    /// v1.98：应收期（年/月）——提前交下期租的场景，提醒显示的是"下一应收期"（如 10 月显示 11 月应交），
    /// 快捷收租必须写这个期而不是当前月，否则跨月收租写错期（老 bug 根因）
    let year: Int
    let month: Int
    let dueDay: Int
    let daysUntilDue: Int
    let isOverdue: Bool
    let overdueDays: Int
    let needUtility: Bool
    let utilitySettled: Bool
}

// MARK: - 包租房付租提醒模型
struct PayoutReminder: Identifiable {
    let id = UUID()
    let payout: PayoutRecord
    let roomNumber: String
    let paymentMethod: String
    let amount: Double
    let payMonth: Int
    let recordMonth: Int
    let payDay: Int
    let isOverdue: Bool
    let daysDiff: Int
}

// MARK: - 包租房付租提醒卡片（参考包租板块PayoutRow样式）
struct PayoutReminderRow: View {
    let reminder: PayoutReminder
    let onPay: () -> Void
    let onTap: () -> Void

    private var payout: PayoutRecord { reminder.payout }

    // 根据付款方式计算付款期数
    private var periodCount: Int {
        switch payout.paymentMethod {
        case "季付": return 4
        case "半年付": return 2
        case "年付": return 1
        default: return 12
        }
    }

    // 计算所有期的金额（免租期可跨越多期）
    private var allPeriodAmounts: [Double] {
        let monthlyRent = (payout.monthlyRent ?? 0) > 0 ? (payout.monthlyRent ?? 0) : payout.annualRent / 12.0
        var remainingFreeDays = payout.rentFreeDays
        let periodMonths = 12 / periodCount
        let dailyRent = monthlyRent / 30.0
        var amounts: [Double] = []

        for _ in 0..<periodCount {
            let totalDays = periodMonths * 30
            let freeDays = min(remainingFreeDays, totalDays)
            let payableDays = totalDays - freeDays
            amounts.append(dailyRent * Double(payableDays))
            remainingFreeDays -= freeDays
        }
        return amounts
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                // 第一行：下次打租金额（重点突出，加粗放大）
                HStack(spacing: 0) {
                    Text("下次\(reminder.payMonth)月\(reminder.payDay)号应付：")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                    Text(verbatim: "\(Int(reminder.amount))")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                    Text("元")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.themeAccentDark)
                .cornerRadius(.infinity)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

                // 第二行：房号 + 户型 + 付款方式（统一大小，加粗）
                HStack(spacing: 5) {
                    Text(payout.roomNumber)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.themeText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color(hex: "F0F0F0"))
                        .cornerRadius(.infinity)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    if !payout.unitType.isEmpty {
                        Text(payout.unitType)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.themeText)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color(hex: "E3F2FD"))
                            .cornerRadius(.infinity)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    if !payout.paymentMethod.isEmpty {
                        Text(payout.paymentMethod)
                            .font(.system(size: 14, weight: .bold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color(hex: "F0E8FE"))
                            .foregroundColor(Color(hex: "6B3FA0"))
                            .cornerRadius(.infinity)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    Spacer(minLength: 0)
                }

                // 第三行：备注
                if !payout.notes.isEmpty {
                    Text(payout.notes)
                        .font(.system(size: 10))
                        .foregroundColor(.themeText2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color(hex: "F3E5F5"))
                        .cornerRadius(.infinity)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer()

            // 右侧：只保留付按钮
            Button(action: onPay) {
                Text("付")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color(hex: "6B3FA0")))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

// MARK: - 快捷收租弹窗
struct QuickCollectSheet: View {
    @Environment(\.dismiss) private var dismiss
    let property: Property
    /// v1.98：应收期（年/月）——提醒显示的可能不是当前月（如 10 月提醒 11 月应交），弹窗明示应收期，
    /// 保存按此期写入，杜绝"跨月收租写错期"（老 bug 根因）
    let year: Int
    let month: Int
    @Binding var rentText: String
    /// v1.98：保存失败原因回显在弹窗内（红字），无论系统 alert 是否被遮挡都可见
    @Binding var errorText: String?
    /// v1.98：返回 true=保存成功才关闭弹窗；false=保存失败保留弹窗可重试
    let onSave: () -> Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("房源信息") {
                    LabeledContent("房号", value: property.roomNumber)
                    LabeledContent("房东", value: property.landlord)
                    LabeledContent("应收期", value: "\(year)年\(month)月")
                }
                Section("收租金额") {
                    TextField("实收租金", text: $rentText)
                        .keyboardType(.decimalPad)
                    if let errorText {
                        Text(errorText)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.red)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.themeBg)
            .labeledContentStyle(DetailLabeledContentStyle())
            .navigationTitle("快捷收租")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        // v1.98：保存成功才关弹窗；失败保留弹窗（父级弹错误提示）
                        if onSave() { dismiss() }
                    }
                    .foregroundColor(.themeAccent)
                }
            }
        }
        .presentationDetents([.height(360)])
    }
}

// MARK: - 快捷付租弹窗
struct QuickPaySheet: View {
    @Environment(\.dismiss) private var dismiss
    let payout: PayoutRecord
    @Binding var amountText: String
    let payMonth: Int
    let recordMonth: Int
    @Binding var errorText: String?
    let onSave: () -> Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("房源信息") {
                    LabeledContent("房号", value: payout.roomNumber)
                    LabeledContent("付款月", value: "\(payMonth)月")
                }
                Section("付租金额") {
                    TextField("实付金额", text: $amountText)
                        .keyboardType(.decimalPad)
                    if let errorText {
                        Text(errorText)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.red)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.themeBg)
            .labeledContentStyle(DetailLabeledContentStyle())
            .navigationTitle("快捷付租")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        // v2.19：保存成功才关弹窗；失败保留弹窗并显示红字
                        if onSave() { dismiss() }
                    }
                    .foregroundColor(.themeAccent)
                }
            }
        }
        .presentationDetents([.height(360)])
    }
}

// MARK: - KPI 卡片
struct KpiCard: View {
    let label: String
    let value: String
    let unit: String
    let foot: String
    var style: KpiStyle = .normal
    var footBuilder: ((Bool) -> AnyView)? = nil
    var valueColor: Color? = nil
    var storageKey: String = ""
    @AppStorage private var isHidden: Bool

    init(label: String, value: String, unit: String, foot: String, style: KpiStyle = .normal, footBuilder: ((Bool) -> AnyView)? = nil, valueColor: Color? = nil, storageKey: String = "") {
        self.label = label
        self.value = value
        self.unit = unit
        self.foot = foot
        self.style = style
        self.footBuilder = footBuilder
        self.valueColor = valueColor
        self.storageKey = storageKey
        _isHidden = AppStorage(wrappedValue: false, "kpi_hidden_\(storageKey)")
    }

    enum KpiStyle {
        case normal, accent, alert
    }

    private var dotColor: Color {
        switch style {
        case .accent: return .white
        case .alert: return .themeRed
        case .normal: return .themeAccent
        }
    }

    private var actualValueColor: Color {
        if let color = valueColor { return color }
        return style == .accent ? .white : (style == .alert ? .themeRed : .themeText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 标题行：标题胶囊 + 独立眼睛胶囊
            HStack(spacing: 4) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 6, height: 6)
                    Text(label)
                        .font(.system(size: 11))
                        .foregroundColor(style == .accent ? .white.opacity(0.9) : .themeText2)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(style == .accent ? Color.white.opacity(0.2) : Color(hex: "F0F0F0"))
                .cornerRadius(.infinity)

                Spacer()

                Button {
                    isHidden.toggle()
                } label: {
                    Image(systemName: isHidden ? "eye.slash.fill" : "eye.fill")
                        .font(.system(size: 11))
                        .foregroundColor(style == .accent ? .white.opacity(0.9) : .themeText2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(style == .accent ? Color.white.opacity(0.2) : Color(hex: "F0F0F0"))
                        .cornerRadius(.infinity)
                }
                .buttonStyle(.plain)
            }

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(isHidden ? "**" : value)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(actualValueColor)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                Text(unit)
                    .font(.system(size: 11))
                    .foregroundColor(style == .accent ? .white.opacity(0.7) : .themeText3)
            }
            if let footBuilder = footBuilder {
                footBuilder(isHidden)
            } else {
                Text(isHidden ? "**" : foot)
                    .font(.system(size: 11))
                    .foregroundColor(style == .accent ? .white.opacity(0.7) : .themeText3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            Group {
                if style == .accent {
                    LinearGradient(gradient: Gradient(colors: [Color.themeAccent, Color.themeAccentDark]),
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                } else if style == .alert {
                    Color(hex: "FDF5F5")
                } else {
                    Color.themePanel
                }
            }
        )
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(style == .normal ? Color.themeBorder : (style == .alert ? Color(hex: "F4D9D9") : Color.clear), lineWidth: 1)
        )
    }
}

struct QuickActionItem: View {
    let icon: String
    let label: String
    let color: Color
    let action: () -> Void
    var imageName: String? = nil
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                if let img = imageName {
                    Image(img)
                        .resizable()
                        .frame(width: 34, height: 34)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 26))
                        .foregroundColor(color)
                }
                Text(label)
                    .font(.system(size: 11))
                    .foregroundColor(.themeText)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}

/// v1.84：「更多」收纳面板（放不下的快捷操作入口）
struct MoreActionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let specs: [(imageName: String?, icon: String, label: String, color: Color, action: () -> Void)]

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(Color.themeBorder).frame(width: 40, height: 4).padding(.top, 10)
            Text("更多")
                .font(.system(size: 16, weight: .bold))
                .padding(.top, 12)
                .padding(.bottom, 6)
            if specs.isEmpty {
                Text("暂无更多入口，可在「快捷操作 → 排序」里收纳")
                    .font(.system(size: 13))
                    .foregroundColor(.themeText3)
                    .padding(.top, 30)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 8) {
                    ForEach(Array(specs.enumerated()), id: \.offset) { _, spec in
                        QuickActionItem(icon: spec.icon, label: spec.label, color: spec.color, action: {
                            dismiss()
                            // 先等面板完全关闭再打开目标页，避免同一 presenter 的 sheet 关闭/打开竞争
                            // 导致 showMoreActions 状态残留、切换板块后面板又自动弹出
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                                spec.action()
                            }
                        }, imageName: spec.imageName)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            Spacer()
        }
        .presentationDetents([.height(240)])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - 图片选择器
struct ImagePickerView: UIViewControllerRepresentable {
    let onImagePicked: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onImagePicked: onImagePicked)
    }

    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onImagePicked: (UIImage?) -> Void

        init(onImagePicked: @escaping (UIImage?) -> Void) {
            self.onImagePicked = onImagePicked
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let result = results.first else {
                onImagePicked(nil)
                return
            }
            result.itemProvider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
                DispatchQueue.main.async {
                    self?.onImagePicked(object as? UIImage)
                }
            }
        }
    }
}

// MARK: - v1.17 需求5 云端后台 WebView（App 内管理后台直接加载云端后台网页，免登录）

struct AdminWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let web = WKWebView(frame: .zero)
        web.navigationDelegate = context.coordinator
        // v1.19 补全 #11：必须设 uiDelegate，否则后台页面的 JS alert/confirm 弹窗在 WKWebView 里会阻塞主线程 → 页面卡死无法操作
        web.uiDelegate = context.coordinator
        web.load(URLRequest(url: url))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            // 加载失败静默；页面本身会显示网络错误
        }
        // v1.19 补全 #11：自动放行 JS 弹窗（alert/confirm/prompt），避免 WebView 卡死
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            completionHandler()
        }
        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            completionHandler(true)
        }
        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
            completionHandler(defaultText)
        }
    }
}

// MARK: - v2.21 在线更新（工作台徽章 + 更新详情页）

extension DashboardView {
    /// 当前版本号；云端有新版本时变橙色「↑ 2.21」胶囊，点开看更新说明
    fileprivate var versionBadge: some View {
        Group {
            if let a = updateCenter.available {
                Button {
                    showUpdateDetail = true
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 9))
                        Text(a.version)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
            } else {
                Text("v\(UpdateCenter.appVersion)")
                    .font(.system(size: 11))
                    .foregroundColor(.themeText3)
            }
        }
    }
}

struct UpdateDetailView: View {
    let update: UpdateCenter.Available

    @Environment(\.dismiss) private var dismiss
    @StateObject private var downloader = UpdateDownloader()
    @State private var showShareSheet = false

    private var sizeText: String {
        guard update.sizeBytes > 0 else { return "—" }
        return String(format: "%.1f MB", Double(update.sizeBytes) / 1_048_576)
    }

    private var primaryTitle: String {
        switch downloader.phase {
        case .idle: return "立即更新（下载安装包）"
        case .downloading: return "正在下载 \(Int(min(max(downloader.progress, 0), 1) * 100))%"
        case .verifying: return "正在校验安装包…"
        case .ready: return "保存 / 发送安装包"
        case .failed: return "重新下载"
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text("v\(update.version)")
                                .font(.system(size: 26, weight: .bold))
                                .foregroundColor(.themeText)
                            if update.build > 0 {
                                Text("b\(update.build)")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.themeText3)
                            }
                            Text("当前 v\(UpdateCenter.appVersion)")
                                .font(.system(size: 12))
                                .foregroundColor(.themeText3)
                        }
                        HStack(spacing: 10) {
                            if !update.releasedAt.isEmpty { Text(update.releasedAt) }
                            Text(sizeText)
                        }
                        .font(.system(size: 12))
                        .foregroundColor(.themeText2)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("更新内容")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.themeText)
                        if update.notes.isEmpty {
                            Text("本次更新的说明还没填，后台补充后这里会显示。")
                                .font(.system(size: 13))
                                .foregroundColor(.themeText3)
                        } else {
                            ForEach(update.notes, id: \.self) { line in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "circle.fill")
                                        .font(.system(size: 5))
                                        .foregroundColor(.themeAccent)
                                        .padding(.top, 6)
                                    Text(line)
                                        .font(.system(size: 14))
                                        .foregroundColor(.themeText)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.themePanel)
                    .cornerRadius(14)
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.themeBorder, lineWidth: 1))

                    if case .downloading = downloader.phase {
                        ProgressView(value: min(max(downloader.progress, 0), 1))
                            .tint(AppTheme.primary)
                    }
                    if case let .failed(msg) = downloader.phase {
                        Text(msg)
                            .font(.system(size: 12))
                            .foregroundColor(.themeRed)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if case .ready = downloader.phase, let url = downloader.localURL {
                        Text("已下载：\(url.lastPathComponent)")
                            .font(.system(size: 12))
                            .foregroundColor(.themeAccentDark)
                    }

                    Text("iOS 不允许 App 直接安装 IPA。下载完成后用你的签名工具（轻松签 / 爱思助手等）打开这个文件重签安装；下载好的包在「文件 App → 公寓管家 → Updates」里也能找到。")
                        .font(.system(size: 12))
                        .foregroundColor(.themeText3)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(spacing: 10) {
                        Button {
                            if case .ready = downloader.phase {
                                showShareSheet = true
                            } else {
                                downloader.start(update)
                            }
                        } label: {
                            HStack(spacing: 8) {
                                if downloader.isBusy {
                                    ProgressView().controlSize(.small).tint(.white)
                                }
                                Text(primaryTitle)
                                    .font(.system(size: 16, weight: .semibold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(AppTheme.primary)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                        }
                        .buttonStyle(.plain)
                        .disabled(downloader.isBusy)

                        if !update.installPageURL.isEmpty {
                            Button {
                                if let url = URL(string: update.installPageURL),
                                   let scheme = url.scheme?.lowercased(),
                                   scheme == "http" || scheme == "https" {
                                    UIApplication.shared.open(url)
                                }
                            } label: {
                                Text("去安装页（第三方签名平台）")
                                    .font(.system(size: 15, weight: .medium))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(Color.themeAccentWeak)
                                    .foregroundColor(.themeAccentDark)
                                    .cornerRadius(12)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(20)
            }
            .background(AppTheme.background)
            .navigationTitle("发现新版本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("稍后") { dismiss() }
                }
            }
            .sheet(isPresented: $showShareSheet) {
                if let url = downloader.localURL {
                    ShareSheet(activityItems: [url])
                }
            }
        }
    }
}
