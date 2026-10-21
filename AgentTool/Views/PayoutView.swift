import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct PayoutView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<PayoutRecord> { !$0.isDeleted }, sort: \PayoutRecord.roomNumber) private var payouts: [PayoutRecord]
    @State private var showingAddPayout = false
    @State private var editingPayout: PayoutRecord?
    @State private var selectedPayout: PayoutRecord?
    @State private var highlightedCardID: UUID?
    @State private var payoutToDelete: PayoutRecord?
    @State private var showDeleteConfirm = false
    @State private var exportURL: ExportURL?
    @State private var showingRestore = false
    @State private var searchText = ""
    @State private var showRefreshTip = false
    @State private var refreshVersion = 0

    // 计算下次付租信息
    // 根据付款方式获取每期对应的月份（用于关联monthlyPayouts，与详情页一致）
    private func periodMonth(for payout: PayoutRecord, index: Int) -> Int {
        switch payout.paymentMethod {
        case "季付": return (index + 1) * 3
        case "半年付": return (index + 1) * 6
        case "年付": return 12
        default: return index + 1
        }
    }

    private func nextPayoutInfo(for payout: PayoutRecord) -> (month: Int, day: Int, amount: Double, isOverdue: Bool, daysDiff: Int) {
        let calendar = Calendar.current
        let now = Date()

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
                // 金额：优先用记录中的金额（如果>0），否则用默认的月租×期数月数
                let defaultAmount = (payout.monthlyRent ?? 0) * Double(periodMonths)
                let amount = (record?.amount ?? 0) > 0 ? record!.amount : defaultAmount

                // 计算付款日期（用于判断逾期和天数差）
                var dateComps = DateComponents()
                dateComps.year = calendar.component(.year, from: startDate) + (startMonth + i * periodMonths - 1) / 12
                dateComps.month = displayMonth
                dateComps.day = startDay
                let payDate = calendar.date(from: dateComps) ?? startDate

                // 使用日历准确计算天数差
                let isOverdue = payDate < now
                let rawDays = calendar.dateComponents([.day], from: now, to: payDate).day ?? 0
                let daysDiff = abs(rawDays)

                return (displayMonth, startDay, amount, isOverdue, daysDiff)
            }
        }
        return (0, 0, 0, false, 999)
    }

    // 预计算排序信息
    private struct PayoutSortInfo {
        let payout: PayoutRecord
        let isOverdue: Bool
        let sortDays: Int
    }

    private var filteredPayouts: [PayoutRecord] {
        let filtered: [PayoutRecord]
        if searchText.isEmpty {
            filtered = payouts
        } else {
            filtered = payouts.filter { payout in
                payout.roomNumber.localizedCaseInsensitiveContains(searchText) ||
                payout.manager.localizedCaseInsensitiveContains(searchText) ||
                payout.unitType.localizedCaseInsensitiveContains(searchText) ||
                payout.paymentMethod.localizedCaseInsensitiveContains(searchText) ||
                payout.notes.localizedCaseInsensitiveContains(searchText)
            }
        }

        // 预计算排序信息（单次遍历）
        let sortInfos: [PayoutSortInfo] = filtered.map { payout in
            let info = nextPayoutInfo(for: payout)
            let sortDays: Int
            if info.isOverdue {
                sortDays = -info.daysDiff // 逾期越久，sortDays越小，越靠前
            } else {
                sortDays = info.daysDiff // 未逾期，越临近越靠前
            }
            return PayoutSortInfo(payout: payout, isOverdue: info.isOverdue, sortDays: sortDays)
        }

        // 排序（使用预计算的信息）
        return sortInfos.sorted { a, b in
            if a.isOverdue != b.isOverdue { return a.isOverdue && !b.isOverdue }
            return a.sortDays < b.sortDays
        }.map { $0.payout }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 搜索框
                VStack {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.themeText3)
                        TextField("搜索房号、管理人、户型…", text: $searchText)
                            .textFieldStyle(.plain)
                            .foregroundColor(.themeText)
                        if !searchText.isEmpty {
                            Button { searchText = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.themeText3)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.themePanel)
                    .cornerRadius(10)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.themeBorder, lineWidth: 1))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.themeBg)

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
                List {
                    ForEach(filteredPayouts) { payout in
                    PayoutRow(payout: payout)
                        .id("\(payout.id)-\(refreshVersion)")
                        .contentShape(Rectangle())
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(highlightedCardID == payout.id ? Color.themeAccent : Color.clear, lineWidth: 2)
                                .animation(.easeInOut(duration: 0.2), value: highlightedCardID)
                        )
                        .onTapGesture {
                            highlightedCardID = payout.id
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                selectedPayout = payout
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                payoutToDelete = payout
                                showDeleteConfirm = true
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                            .tint(.red)
                            Button {
                                editingPayout = payout
                            } label: {
                                Label("修改", systemImage: "pencil")
                            }
                            .tint(.themeBlue)
                        }
                        .listRowBackground(Color.themeBg)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .refreshable {
                refreshPayoutCards()
            }
            .background(Color.themeBg)
            .overlay {
                if filteredPayouts.isEmpty {
                    ContentUnavailableView("暂无打租记录", systemImage: "arrow.up.circle", description: Text("点击右上角 + 添加包租打租记录"))
                }
            }
        .navigationTitle("包租管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Menu {
                    Button { exportToImage() } label: {
                        Label("导出图片", systemImage: "photo")
                    }
                    Button { exportToExcel() } label: {
                        Label("导出Excel", systemImage: "tablecells")
                    }
                    Button { exportTemplate() } label: {
                        Label("导出Excel模板", systemImage: "doc.text")
                    }
                    Button { showingRestore = true } label: {
                        Label("恢复数据", systemImage: "square.and.arrow.down")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").foregroundColor(.themeAccent)
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showingAddPayout = true } label: {
                    Image(systemName: "plus.circle.fill").foregroundColor(.themeAccent)
                }
            }
        }
        .sheet(isPresented: $showingAddPayout, onDismiss: refreshPayoutCards) { AddPayoutView() }
        .sheet(item: $editingPayout, onDismiss: refreshPayoutCards) { payout in AddPayoutView(payout: payout) }
        .sheet(item: $selectedPayout, onDismiss: refreshPayoutCards) { payout in
            PayoutDetailView(payout: payout, onSave: refreshPayoutCards)
        }
        .sheet(item: $exportURL) { url in ShareSheet(activityItems: [url.url]) }
        .sheet(isPresented: $showingRestore) {
            RestoreBackupView(type: .payouts) { success in
                showingRestore = false
            }
        }
        .alert("删除到回收站", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) { payoutToDelete = nil }
            Button("确定删除", role: .destructive) {
                if let payout = payoutToDelete {
                    payout.isDeleted = true; payout.deletedAt = Date()
                }
                try? modelContext.save()
                payoutToDelete = nil
            }
        } message: {
            Text("确定删除这条包租记录吗？删除后可在回收站还原。")
        }
        }
    }

    private func refreshPayoutCards() {
        try? modelContext.save()
        refreshVersion += 1
        withAnimation {
            showRefreshTip = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            withAnimation {
                showRefreshTip = false
            }
        }
    }

    private func deletePayout(at offsets: IndexSet) {
        for index in offsets { payouts[index].isDeleted = true; payouts[index].deletedAt = Date() }
        try? modelContext.save()
    }

    @MainActor
    private func exportToImage() {
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "yyyy年M月d日 HH:mm"
        let dateStr = df.string(from: Date())
        let rows = payouts.map { p -> [String] in
            let monthlyPayout = p.annualRent / 12
            return [p.roomNumber, p.manager, p.unitType, "¥\(Int(p.annualRent))",
                    "¥\(Int(monthlyPayout))", "\(p.rentFreeDays)天", p.paymentMethod]
        }
        let view = ExportTableView(
            title: "包租记录", dateStr: dateStr,
            headers: ["房号","管理人","户型","年租金","月打租","免租期","支付方式"],
            rows: rows
        )
        let renderer = ImageRenderer(content: view.frame(width: 700))
        renderer.scale = 2.0
        if let image = renderer.uiImage {
            let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("包租记录-\(Int(Date().timeIntervalSince1970)).png")
            if let data = image.pngData() {
                try? data.write(to: fileURL)
                exportURL = ExportURL(url: fileURL)
            }
        }
    }

    private func exportToExcel() {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let headers = ["房号","管理人","户型","起租日","到期日","年租金","免租期","支付方式","备注"]
        let rows = payouts.map { [
            $0.roomNumber, $0.manager, $0.unitType,
            df.string(from: $0.leaseStartDate), df.string(from: $0.leaseEndDate),
            "\(Int($0.annualRent))", "\($0.rentFreeDays)", $0.paymentMethod, $0.notes
        ]}
        let html = makeExcelHTML(title: "包租记录", headers: headers, rows: rows)
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("包租记录-\(Int(Date().timeIntervalSince1970)).xls")
        try? html.write(to: fileURL, atomically: true, encoding: .utf8)
        exportURL = ExportURL(url: fileURL)
    }

    private func exportTemplate() {
        let headers = ["房号","管理人","户型","起租日","到期日","年租金","免租期","支付方式","备注"]
        let rows = [["1-101","李四","单间上层","2026-01-01","2027-12-31","12000","15","月付","示例"]]
        let html = makeExcelHTML(title: "包租记录", headers: headers, rows: rows)
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("包租记录-模板.xls")
        try? html.write(to: fileURL, atomically: true, encoding: .utf8)
        exportURL = ExportURL(url: fileURL)
    }

    private func importFromFile(url: URL) {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        var content: String?
        if var data = try? Data(contentsOf: url) {
            if data.count >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF {
                data = data.subdata(in: 3..<data.count)
            }
            content = String(data: data, encoding: .utf8)
            if content == nil {
                let gbk = CFStringEncodings.GB_18030_2000.rawValue
                let encoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(gbk))
                content = String(data: data, encoding: String.Encoding(rawValue: encoding))
            }
        }
        guard let text = content else { return }

        var rows: [[String]] = []
        if text.contains("<tr") {
            let trPattern = try? NSRegularExpression(pattern: "<tr[^>]*>(.*?)</tr>", options: [.dotMatchesLineSeparators, .caseInsensitive])
            let tdPattern = try? NSRegularExpression(pattern: "<t[dh][^>]*>(.*?)</t[dh]>", options: [.dotMatchesLineSeparators, .caseInsensitive])
            if let trMatches = trPattern?.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                for trMatch in trMatches {
                    if let trRange = Range(trMatch.range(at: 1), in: text) {
                        let trContent = String(text[trRange])
                        var row: [String] = []
                        if let tdMatches = tdPattern?.matches(in: trContent, range: NSRange(trContent.startIndex..., in: trContent)) {
                            for tdMatch in tdMatches {
                                if let tdRange = Range(tdMatch.range(at: 1), in: trContent) {
                                    var cell = String(trContent[tdRange])
                                    cell = cell.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                                    cell = cell.trimmingCharacters(in: .whitespacesAndNewlines)
                                    row.append(cell)
                                }
                            }
                        }
                        if !row.isEmpty { rows.append(row) }
                    }
                }
            }
            if !rows.isEmpty { rows.removeFirst() }
        } else {
            let lines = text.components(separatedBy: .newlines).dropFirst()
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                rows.append(trimmed.components(separatedBy: ","))
            }
        }

        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        for cols in rows {
            guard cols.count >= 6 else { continue }
            let p = PayoutRecord(
                roomNumber: cols[0], manager: cols[1], unitType: cols[2],
                leaseStartDate: df.date(from: cols[3]) ?? Date(),
                leaseEndDate: df.date(from: cols[4]) ?? Date(),
                rentFreeDays: cols.count > 6 ? Int(cols[6]) ?? 0 : 0,
                annualRent: Double(cols[5]) ?? 0,
                paymentMethod: cols.count > 7 ? cols[7] : "月付",
                notes: cols.count > 8 ? cols[8] : ""
            )
            modelContext.insert(p)
        }
    }
}

struct PayoutRow: View {
    let payout: PayoutRecord

    // 合法期数月份集合（过滤历史快捷付租可能写入的错月记录，保证已付统计准确）
    private var validMonths: Set<Int> {
        Set((0..<periodCount).map { periodMonth(for: $0) })
    }

    private var paidCount: Int {
        payout.monthlyPayouts.filter { $0.isPaid && validMonths.contains($0.month) }.count
    }

    private var paidAmount: Double {
        payout.monthlyPayouts.filter { $0.isPaid && validMonths.contains($0.month) }.reduce(0) { $0 + $1.amount }
    }

    private var paidUtility: Double {
        payout.monthlyUtilityRecords.filter { $0.isSettled }.reduce(0) { $0 + $1.waterAmount + $1.electricAmount }
    }

    // 根据付款方式计算付款期数
    private var periodCount: Int {
        switch payout.paymentMethod {
        case "季付": return 4
        case "半年付": return 2
        case "年付": return 1
        default: return 12
        }
    }

    // 根据付款方式获取每期对应的月份
    private func periodMonth(for index: Int) -> Int {
        switch payout.paymentMethod {
        case "季付": return (index + 1) * 3
        case "半年付": return (index + 1) * 6
        case "年付": return 12
        default: return index + 1
        }
    }

    // 下次打租信息（根据起租月日计算付款日期）
    private var nextPayout: (month: Int, day: Int, amount: Double)? {
        let calendar = Calendar.current
        let startMonth = calendar.component(.month, from: payout.leaseStartDate)
        let startDay = calendar.component(.day, from: payout.leaseStartDate)
        let periodMonths = 12 / periodCount

        for i in 0..<periodCount {
            let month = periodMonth(for: i)
            // 计算该期的付款月份：起租月 + i*periodMonths
            var payMonth = startMonth + i * periodMonths
            if payMonth > 12 { payMonth = payMonth % 12 }
            if payMonth == 0 { payMonth = 12 }

            if let record = payout.monthlyPayouts.first(where: { $0.month == month }), !record.isPaid {
                return (payMonth, startDay, record.amount)
            } else if payout.monthlyPayouts.first(where: { $0.month == month }) == nil {
                // 没有记录说明还未付，计算默认金额
                let defaultAmount = calculatePeriodAmount(for: i)
                return (payMonth, startDay, defaultAmount)
            }
        }
        return nil
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

    // 根据免租期计算每期金额
    private func calculatePeriodAmount(for index: Int) -> Double {
        let amounts = allPeriodAmounts
        if index < amounts.count {
            return amounts[index]
        }
        let monthlyRent = (payout.monthlyRent ?? 0) > 0 ? (payout.monthlyRent ?? 0) : payout.annualRent / 12.0
        return monthlyRent * Double(12 / periodCount)
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                // 第一行：下次打租金额（重点突出，加粗放大）
                if let next = nextPayout {
                    HStack(spacing: 0) {
                        Text("下次\(next.month)月\(next.day)号应付：")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                        Text(verbatim: "\(Int(next.amount))")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                        Text("元")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Color.themeAccentDark)
                    .cornerRadius(.infinity)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                }
                // 第二行：付款日 + 年租
                HStack(spacing: 6) {
                    Text("\(payout.rentDueDay)号")
                        .font(.system(size: 12))
                        .foregroundColor(.themeText2)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color(hex: "FDF0F0"))
                        .cornerRadius(.infinity)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Text(verbatim: "年租\(Int(allPeriodAmounts.reduce(0, +)))")
                        .font(.system(size: 12))
                        .foregroundColor(.themeText2)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color(hex: "FFF3E0"))
                        .cornerRadius(.infinity)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                }
                // 第三行：房号 + 户型 + 付款方式（统一大小，加粗放大）
                HStack(spacing: 6) {
                    Text(payout.roomNumber)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.themeText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Color(hex: "F0F0F0"))
                        .cornerRadius(.infinity)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    if !payout.unitType.isEmpty {
                        Text(payout.unitType)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.themeText)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Color(hex: "E3F2FD"))
                            .cornerRadius(.infinity)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    if !payout.paymentMethod.isEmpty {
                        Text(payout.paymentMethod)
                            .font(.system(size: 16, weight: .bold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Color(hex: "F0E8FE"))
                            .foregroundColor(Color(hex: "6B3FA0"))
                            .cornerRadius(.infinity)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    Spacer(minLength: 0)
                }
                // 第四行：备注
                if !payout.notes.isEmpty {
                    Text(payout.notes)
                        .font(.system(size: 11))
                        .foregroundColor(.themeText2)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(Color(hex: "F3E5F5"))
                        .cornerRadius(.infinity)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer()

            // 右侧：已付次数 + 已付金额 + 已付水电费
            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 0) {
                    Text("已付")
                        .font(.system(size: 11))
                        .foregroundColor(.white)
                    Text("\(paidCount)")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                    Text("次租金")
                        .font(.system(size: 11))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.themeAccent)
                .cornerRadius(.infinity)

                HStack(spacing: 0) {
                    Text("已付")
                        .font(.system(size: 11))
                        .foregroundColor(.white)
                    Text(verbatim: "\(Int(paidAmount))")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                    Text("元")
                        .font(.system(size: 11))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color(hex: "6B3FA0"))
                .cornerRadius(.infinity)

                HStack(spacing: 0) {
                    Text("已付水电")
                        .font(.system(size: 11))
                        .foregroundColor(.white)
                    Text(verbatim: "\(Int(paidUtility))")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                    Text("元")
                        .font(.system(size: 11))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.themeAmber)
                .cornerRadius(.infinity)
            }
        }
        .padding(14)
        .background(Color.themePanel)
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.themeBorder, lineWidth: 1))
    }
}

// MARK: - 打租详情
struct PayoutDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let payout: PayoutRecord
    let onSave: () -> Void
    private let months = ["1月","2月","3月","4月","5月","6月","7月","8月","9月","10月","11月","12月"]

    init(payout: PayoutRecord, onSave: @escaping () -> Void = {}) {
        self.payout = payout
        self.onSave = onSave
    }
    @State private var showEditPayout = false
    @State private var utilityRecords: [UtilityRecordEdit] = []
    @State private var editingRecordID: UUID?
    @State private var tempEditDate = Date()
    @State private var showDateWheel = false

    private var dateFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy年M月d日"
        return f
    }

    struct UtilityRecordEdit: Identifiable {
        let id = UUID()
        var date: Date
        var waterText: String
        var electricText: String
        var isSettled: Bool
    }

    private func loadUtilityRecords() {
        utilityRecords = payout.monthlyUtilityRecords.map { record in
            UtilityRecordEdit(
                date: record.date,
                waterText: record.waterAmount > 0 ? String(Int(record.waterAmount)) : "",
                electricText: record.electricAmount > 0 ? String(Int(record.electricAmount)) : "",
                isSettled: record.isSettled
            )
        }
        while utilityRecords.count < 2 {
            utilityRecords.append(UtilityRecordEdit(date: Date(), waterText: "", electricText: "", isSettled: false))
        }
    }

    private func saveChanges() {
        let oldUtilityRecords = payout.monthlyUtilityRecords
        let newUtilityRecords = utilityRecords.map { edit in
            PayoutUtilityRecord(
                date: edit.date,
                waterAmount: Double(edit.waterText) ?? 0,
                electricAmount: Double(edit.electricText) ?? 0,
                isSettled: edit.isSettled
            )
        }
        newUtilityRecords.forEach { modelContext.insert($0) }
        payout.monthlyUtilityRecords = newUtilityRecords
        oldUtilityRecords.forEach { modelContext.delete($0) }
        try? modelContext.save()
        onSave()
    }

    // 根据付款方式计算付款期数
    private var periodCount: Int {
        switch payout.paymentMethod {
        case "季付": return 4
        case "半年付": return 2
        case "年付": return 1
        default: return 12
        }
    }

    // 根据付款方式计算每期金额（默认，不考虑免租期）
    private var periodAmount: Double {
        periodCount > 0 ? payout.annualRent / Double(periodCount) : 0
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

    // 根据免租期计算每期金额
    private func calculatePeriodAmount(for index: Int) -> Double {
        let amounts = allPeriodAmounts
        if index < amounts.count {
            return amounts[index]
        }
        return periodAmount
    }

    // 根据付款方式获取每期对应的月份（用于关联monthlyPayouts）
    private func periodMonth(for index: Int) -> Int {
        switch payout.paymentMethod {
        case "季付": return (index + 1) * 3
        case "半年付": return (index + 1) * 6
        case "年付": return 12
        default: return index + 1
        }
    }

    // 根据付款方式获取每期标签（根据起租日期计算实际付款日期）
    private func periodLabel(for index: Int) -> String {
        let calendar = Calendar.current
        let startMonth = calendar.component(.month, from: payout.leaseStartDate)
        let startDay = calendar.component(.day, from: payout.leaseStartDate)
        let periodMonths = 12 / periodCount

        var payMonth = startMonth + index * periodMonths
        if payMonth > 12 { payMonth = ((payMonth - 1) % 12) + 1 }

        switch payout.paymentMethod {
        case "季付": return "第\(index + 1)季 \(payMonth)月\(startDay)日"
        case "半年付": return (index == 0 ? "上半年" : "下半年") + " \(payMonth)月\(startDay)日"
        case "年付": return "全年 \(payMonth)月\(startDay)日"
        default: return "\(payMonth)月\(startDay)日"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    LabeledContent("房号", value: payout.roomNumber)
                    LabeledContent("管理", value: payout.manager)
                    LabeledContent("户型", value: payout.unitType)
                    LabeledContent("月租金", value: "¥\(Int((payout.monthlyRent ?? 0) > 0 ? (payout.monthlyRent ?? 0) : payout.annualRent / 12))")
                    LabeledContent("押金", value: "¥\(Int(payout.deposit))")
                    LabeledContent("付款方式", value: payout.paymentMethod)
                    LabeledContent("交租日", value: "每月\(payout.rentDueDay)号")
                    LabeledContent("免租期", value: payout.rentFreeDays > 0 ? "\(payout.rentFreeDays)天" : "无")
                    LabeledContent("起租期", value: dateFormatter.string(from: payout.leaseStartDate))
                    LabeledContent("到期日", value: dateFormatter.string(from: payout.leaseEndDate))
                    if !payout.leaseDuration.isEmpty { LabeledContent("租期", value: payout.leaseDuration) }
                    LabeledContent("年总租金", value: "¥\(Int(allPeriodAmounts.reduce(0, +)))")
                    if !payout.notes.isEmpty { LabeledContent("备注", value: payout.notes) }
                }

                Section("打租计划（\(payout.paymentMethod)，共\(periodCount)期）") {
                    ForEach(0..<periodCount, id: \.self) { idx in
                        let month = periodMonth(for: idx)
                        let amount = calculatePeriodAmount(for: idx)
                        MonthPayoutRow(payout: payout, month: month, label: periodLabel(for: idx), defaultAmount: amount)
                    }
                }

                Section("水电结算（动态登记，大房东收时登记，右滑删除）") {
                    ForEach($utilityRecords) { $record in
                        HStack(spacing: 8) {
                            Button {
                                editingRecordID = record.id
                                tempEditDate = record.date
                                showDateWheel = true
                            } label: {
                                Text(dateFormatter.string(from: record.date))
                                    .font(.system(size: 13))
                                    .foregroundColor(.themeText)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.6)
                                    .frame(width: 105, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            TextField("水", text: $record.waterText)
                                .keyboardType(.numberPad)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                            TextField("电", text: $record.electricText)
                                .keyboardType(.numberPad)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                            Button {
                                record.isSettled.toggle()
                            } label: {
                                Image(systemName: record.isSettled ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(record.isSettled ? .themeAccent : .themeText3)
                                    .font(.system(size: 22))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 4)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                if let index = utilityRecords.firstIndex(where: { $0.id == record.id }) {
                                    utilityRecords.remove(at: index)
                                }
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                    Button {
                        utilityRecords.append(UtilityRecordEdit(date: Date(), waterText: "", electricText: "", isSettled: false))
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                                .foregroundColor(.themeAccent)
                            Text("添加一行")
                                .foregroundColor(.themeAccent)
                        }
                    }
                    .buttonStyle(.plain)
                }

                Section("水电底数") {
                    LabeledContent("水表底数", value: "\(payout.waterMeterBase)")
                    LabeledContent("电表底数", value: "\(payout.electricMeterBase)")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.themeBg)
            .labeledContentStyle(DetailLabeledContentStyle())
            .navigationTitle(payout.roomNumber)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") {
                        saveChanges()
                        dismiss()
                    }
                    .foregroundColor(.themeText2)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("编辑") {
                        showEditPayout = true
                    }
                    .foregroundColor(.themeAccent)
                }
            }
            .sheet(isPresented: $showEditPayout, onDismiss: {
                saveChanges()
                loadUtilityRecords()
                onSave()
            }) {
                AddPayoutView(payout: payout)
            }
            .onAppear { loadUtilityRecords() }
            .onDisappear { saveChanges() }
            .sheet(isPresented: $showDateWheel) {
                NavigationStack {
                    VStack {
                        DatePicker("", selection: $tempEditDate, displayedComponents: .date)
                            .datePickerStyle(.wheel)
                            .labelsHidden()
                            .environment(\.locale, Locale(identifier: "zh_CN"))
                            .padding()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.themeBg)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("取消") { showDateWheel = false }
                                .foregroundColor(.themeText2)
                        }
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("完成") {
                                if let id = editingRecordID, let idx = utilityRecords.firstIndex(where: { $0.id == id }) {
                                    utilityRecords[idx].date = tempEditDate
                                }
                                showDateWheel = false
                            }
                            .foregroundColor(.themeAccent)
                            .fontWeight(.semibold)
                        }
                    }
                }
                .presentationDetents([.height(360)])
                .presentationDragIndicator(.visible)
            }
        }
    }
}

// MARK: - 月度打租行（可编辑金额+可取消打勾）
struct MonthPayoutRow: View {
    @Environment(\.modelContext) private var modelContext
    let payout: PayoutRecord
    let month: Int
    let label: String
    let defaultAmount: Double
    @State private var amountText: String
    @State private var isPaid: Bool

    init(payout: PayoutRecord, month: Int, label: String, defaultAmount: Double) {
        self.payout = payout
        self.month = month
        self.label = label
        self.defaultAmount = defaultAmount
        let record = payout.monthlyPayouts.first { $0.month == month }
        // 已付款的记录保持原金额，未付款的使用最新计算金额（免租期变动自动更新）
        let amt: Double
        if let record = record, record.isPaid {
            amt = record.amount
        } else {
            amt = defaultAmount
        }
        _amountText = State(initialValue: amt > 0 ? String(Int(amt)) : "")
        _isPaid = State(initialValue: record?.isPaid ?? false)
    }

    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.themeText)
                .frame(width: 110, alignment: .leading)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer()
            TextField("金额", text: $amountText)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .foregroundColor(.themeText)
                .frame(width: 90)
                .onChange(of: amountText) { _, _ in updateRecord() }
            Text("元").foregroundColor(.themeText3)
            Button {
                isPaid.toggle()
                updateRecord()
            } label: {
                Image(systemName: isPaid ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isPaid ? .themeAccent : .themeText3)
                    .font(.system(size: 22))
            }
            .buttonStyle(.plain)
        }
    }

    private func updateRecord() {
        let amount = Double(amountText) ?? 0
        if let index = payout.monthlyPayouts.firstIndex(where: { $0.month == month }) {
            payout.monthlyPayouts[index].amount = amount
            payout.monthlyPayouts[index].isPaid = isPaid
            payout.monthlyPayouts[index].paidDate = isPaid ? Date() : nil
        } else {
            let record = PayoutMonthRecord(month: month, amount: amount, isPaid: isPaid)
            record.paidDate = isPaid ? Date() : nil
            modelContext.insert(record)
            payout.monthlyPayouts.append(record)
        }
        try? modelContext.save()
    }
}

// MARK: - 新增打租记录
struct AddPayoutView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    private let editingPayout: PayoutRecord?

    @State private var roomNumber: String
    @State private var manager: String
    @State private var unitType: String
    @State private var leaseStartDate: Date
    @State private var leaseEndDate: Date
    @State private var leaseDuration: String
    @State private var rentFreeDaysText: String
    @State private var annualRentText: String
    @State private var monthlyRentText: String
    @State private var depositText: String
    @State private var waterMeterText: String
    @State private var electricMeterText: String
    @State private var rentDueDay: Int
    @State private var paymentMethod: String
    @State private var notes: String

    private let unitTypes = ["单间上层","单间下层","独立厨房上层","独立厨房下层","复式","复式独立厨房","中空复式","平层","双钥匙一套","三房"]
    private let methods = ["月付","季付","半年付","年付"]

    init(payout: PayoutRecord? = nil) {
        editingPayout = payout
        _roomNumber = State(initialValue: payout?.roomNumber ?? "")
        _manager = State(initialValue: payout?.manager ?? "")
        _unitType = State(initialValue: payout?.unitType ?? "")
        _leaseStartDate = State(initialValue: payout?.leaseStartDate ?? Date())
        _leaseEndDate = State(initialValue: payout?.leaseEndDate ?? Date())
        _leaseDuration = State(initialValue: payout?.leaseDuration ?? "")
        _rentFreeDaysText = State(initialValue: payout.map { $0.rentFreeDays > 0 ? String($0.rentFreeDays) : "" } ?? "")
        _annualRentText = State(initialValue: payout.map { $0.annualRent > 0 ? String(Int($0.annualRent)) : "" } ?? "")
        _monthlyRentText = State(initialValue: payout.map { p in
            if let rent = p.monthlyRent, rent > 0 { return String(Int(rent)) }
            return p.annualRent > 0 ? String(Int(p.annualRent / 12)) : ""
        } ?? "")
        _depositText = State(initialValue: payout.map { $0.deposit > 0 ? String(Int($0.deposit)) : "" } ?? "")
        _waterMeterText = State(initialValue: payout.map { $0.waterMeterBase > 0 ? String($0.waterMeterBase) : "" } ?? "")
        _electricMeterText = State(initialValue: payout.map { $0.electricMeterBase > 0 ? String($0.electricMeterBase) : "" } ?? "")
        _rentDueDay = State(initialValue: payout?.rentDueDay ?? 1)
        _paymentMethod = State(initialValue: payout?.paymentMethod ?? "月付")
        _notes = State(initialValue: payout?.notes ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextRow(label: "房号", text: $roomNumber)
                    TextRow(label: "管理人", text: $manager)
                    Picker("户型", selection: $unitType) { Text("请选择").tag(""); ForEach(unitTypes, id: \.self) { Text($0).tag($0) } }
                }
                Section("租赁信息") {
                    WheelDateField(label: "起租期", date: $leaseStartDate)
                    WheelDateField(label: "到期日", date: $leaseEndDate)
                    TextRow(label: "租期", text: $leaseDuration)
                    TextRow(label: "免租期（天）", text: $rentFreeDaysText, keyboard: .numberPad)
                    Picker("付款方式", selection: $paymentMethod) { ForEach(methods, id: \.self) { Text($0).tag($0) } }
                }
                Section("金额") {
                    AmountField(label: "月租金", text: $monthlyRentText)
                        .onChange(of: monthlyRentText) { _, _ in
                            let monthly = Double(monthlyRentText) ?? 0
                            if monthly > 0 {
                                annualRentText = String(Int(monthly * 12))
                            }
                        }
                    AmountField(label: "押金", text: $depositText)
                    LabeledContent("交租日", value: "每月\(Calendar.current.component(.day, from: leaseStartDate))号（自动）")
                }
                Section("水电底数") {
                    TextRow(label: "水表底数", text: $waterMeterText, keyboard: .numberPad)
                    TextRow(label: "电表底数", text: $electricMeterText, keyboard: .numberPad)
                }
                Section("备注") { TextField("备注", text: $notes, axis: .vertical) }
            }
            .scrollContentBackground(.hidden)
            .background(Color.themeBg)
            .navigationTitle(editingPayout == nil ? "新增包租" : "编辑包租")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let autoDueDay = Calendar.current.component(.day, from: leaseStartDate)
                        if let p = editingPayout {
                            p.roomNumber = roomNumber
                            p.manager = manager
                            p.unitType = unitType
                            p.leaseStartDate = leaseStartDate
                            p.leaseEndDate = leaseEndDate
                            p.leaseDuration = leaseDuration
                            p.rentFreeDays = Int(rentFreeDaysText) ?? 0
                            p.monthlyRent = Double(monthlyRentText) ?? 0
                            p.annualRent = Double(annualRentText) ?? 0
                            p.deposit = Double(depositText) ?? 0
                            p.waterMeterBase = Int(waterMeterText) ?? 0
                            p.electricMeterBase = Int(electricMeterText) ?? 0
                            p.rentDueDay = autoDueDay
                            p.paymentMethod = paymentMethod
                            p.notes = notes
                        } else {
                            let payout = PayoutRecord(
                                roomNumber: roomNumber, manager: manager, unitType: unitType,
                                leaseStartDate: leaseStartDate, leaseEndDate: leaseEndDate,
                                leaseDuration: leaseDuration, rentFreeDays: Int(rentFreeDaysText) ?? 0,
                                monthlyRent: Double(monthlyRentText) ?? 0,
                                annualRent: Double(annualRentText) ?? 0,
                                deposit: Double(depositText) ?? 0,
                                waterMeterBase: Int(waterMeterText) ?? 0,
                                electricMeterBase: Int(electricMeterText) ?? 0,
                                rentDueDay: autoDueDay,
                                paymentMethod: paymentMethod, notes: notes)
                            modelContext.insert(payout)
                        }
                        dismiss()
                    }
                    .disabled(roomNumber.isEmpty)
                    .foregroundColor(.themeAccent)
                }
            }
        }
    }
}
