import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct DealsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<DealRecord> { !$0.isDeleted }, sort: \DealRecord.date, order: .reverse) private var deals: [DealRecord]
    @Query(filter: #Predicate<MiscIncome> { !$0.isDeleted }, sort: \MiscIncome.date, order: .reverse) private var incomes: [MiscIncome]
    @Query(filter: #Predicate<MiscExpense> { !$0.isDeleted }, sort: \MiscExpense.date, order: .reverse) private var expenses: [MiscExpense]
    @State private var showingAddDeal = false
    @State private var selectedTab = 0
    @State private var searchText = ""
    @State private var selectedYear: Int? = nil
    @State private var selectedMonth: Int? = nil
    @State private var editingDeal: DealRecord?
    @State private var viewingDeal: DealRecord?
    @State private var highlightedCardID: UUID?
    @State private var dealToDelete: DealRecord?
    @State private var incomeToDelete: MiscIncome?
    @State private var expenseToDelete: MiscExpense?
    @State private var showDeleteConfirm = false
    @AppStorage("hide_deal_amount") private var hideDealAmount = false
    @AppStorage("hide_income_amount") private var hideIncomeAmount = false
    @AppStorage("hide_expense_amount") private var hideExpenseAmount = false
    @State private var editingIncome: MiscIncome?
    @State private var editingExpense: MiscExpense?
    @State private var showImportExport = false
    @State private var exportURL: ExportURL?

    private let availableYears = [2024, 2025, 2026, 2027, 2028, 2029, 2030, 2031, 2032, 2033, 2034, 2035]

    private var currentHideState: Bool {
        if selectedTab == 0 { return hideDealAmount }
        if selectedTab == 1 { return hideIncomeAmount }
        return hideExpenseAmount
    }

    private var filteredDeals: [DealRecord] {
        deals.filter { deal in
            let cal = Calendar.current
            let yearMatch = selectedYear == nil || cal.component(.year, from: deal.date) == selectedYear
            let monthMatch = selectedMonth == nil || cal.component(.month, from: deal.date) == selectedMonth
            let searchMatch = searchText.isEmpty ||
                deal.roomNumber.localizedCaseInsensitiveContains(searchText) ||
                deal.landlord.localizedCaseInsensitiveContains(searchText) ||
                deal.unitType.localizedCaseInsensitiveContains(searchText) ||
                deal.manager.localizedCaseInsensitiveContains(searchText) ||
                deal.source.localizedCaseInsensitiveContains(searchText) ||
                deal.notes.localizedCaseInsensitiveContains(searchText)
            return yearMatch && monthMatch && searchMatch
        }
    }

    private var filteredIncomes: [MiscIncome] {
        incomes.filter { inc in
            let cal = Calendar.current
            let yearMatch = selectedYear == nil || cal.component(.year, from: inc.date) == selectedYear
            let monthMatch = selectedMonth == nil || cal.component(.month, from: inc.date) == selectedMonth
            let searchMatch = searchText.isEmpty ||
                inc.item.localizedCaseInsensitiveContains(searchText) ||
                inc.notes.localizedCaseInsensitiveContains(searchText)
            return yearMatch && monthMatch && searchMatch
        }
    }

    private var filteredExpenses: [MiscExpense] {
        expenses.filter { exp in
            let cal = Calendar.current
            let yearMatch = selectedYear == nil || cal.component(.year, from: exp.date) == selectedYear
            let monthMatch = selectedMonth == nil || cal.component(.month, from: exp.date) == selectedMonth
            let searchMatch = searchText.isEmpty ||
                exp.item.localizedCaseInsensitiveContains(searchText) ||
                exp.notes.localizedCaseInsensitiveContains(searchText)
            return yearMatch && monthMatch && searchMatch
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 搜索 + 筛选栏
                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.themeText3)
                        TextField("搜索房号、房东、户型、备注…", text: $searchText)
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

                    HStack(spacing: 8) {
                        WheelYearMonthPicker(year: $selectedYear, month: $selectedMonth)

                        Spacer()

                        // 眼睛图标：隐藏/显示金额
                        Button {
                            if selectedTab == 0 {
                                hideDealAmount.toggle()
                            } else if selectedTab == 1 {
                                hideIncomeAmount.toggle()
                            } else {
                                hideExpenseAmount.toggle()
                            }
                        } label: {
                            Image(systemName: currentHideState ? "eye.slash.fill" : "eye.fill")
                                .foregroundColor(.themeText3)
                                .frame(width: 24, height: 24)
                        }

                        if selectedYear != nil || selectedMonth != nil {
                            Button {
                                selectedYear = nil
                                selectedMonth = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.themeText3)
                            }
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(Color.themeBg)

                Picker("分类", selection: $selectedTab) {
                    Text(selectedTab == 0 ? "成交记录-\(filteredDeals.count)" : "成交记录").tag(0)
                    Text(selectedTab == 1 ? "杂项收入-\(filteredIncomes.count)" : "杂项收入").tag(1)
                    Text(selectedTab == 2 ? "杂项支出-\(filteredExpenses.count)" : "杂项支出").tag(2)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)
                .background(Color.themeBg)

                if selectedTab == 0 {
                    dealList
                } else if selectedTab == 1 {
                    incomeList
                } else {
                    expenseList
                }
            }
            .background(Color.themeBg)
            .navigationTitle("成交管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        Button {
                            exportToImage()
                        } label: {
                            Label("导出图片", systemImage: "photo")
                        }
                        Button {
                            exportToExcel()
                        } label: {
                            Label("导出Excel", systemImage: "tablecells")
                        }
                        Button {
                            exportTemplate()
                        } label: {
                            Label("导出Excel模板", systemImage: "doc.text")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundColor(.themeAccent)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showingAddDeal = true } label: {
                        Image(systemName: "plus.circle.fill").foregroundColor(.themeAccent)
                    }
                }
            }
            .sheet(isPresented: $showingAddDeal) {
                if selectedTab == 0 {
                    AddDealView()
                } else if selectedTab == 1 {
                    AddMiscView(type: .income)
                } else {
                    AddMiscView(type: .expense)
                }
            }
            .sheet(item: $viewingDeal) { deal in
                DealDetailView(deal: deal) {
                    editingDeal = deal
                }
            }
            .sheet(item: $editingDeal) { deal in
                EditDealView(deal: deal)
            }
            .sheet(item: $editingIncome) { inc in
                EditMiscView(item: .income(inc))
            }
            .sheet(item: $editingExpense) { exp in
                EditMiscView(item: .expense(exp))
            }
            .sheet(item: $exportURL) { export in
                ShareSheet(activityItems: [export.url])
            }
            .alert("删除到回收站", isPresented: $showDeleteConfirm) {
                Button("取消", role: .cancel) {
                    dealToDelete = nil
                    incomeToDelete = nil
                    expenseToDelete = nil
                }
                Button("确定删除", role: .destructive) {
                    if let deal = dealToDelete { deal.isDeleted = true; deal.deletedAt = Date() }
                    if let income = incomeToDelete { income.isDeleted = true; income.deletedAt = Date() }
                    if let expense = expenseToDelete { expense.isDeleted = true; expense.deletedAt = Date() }
                    try? modelContext.save()
                    dealToDelete = nil
                    incomeToDelete = nil
                    expenseToDelete = nil
                }
            } message: {
                if dealToDelete != nil {
                    Text("确定删除这条成交记录吗？删除后可在回收站还原。")
                } else if incomeToDelete != nil {
                    Text("确定删除这条杂项收入吗？删除后可在回收站还原。")
                } else if expenseToDelete != nil {
                    Text("确定删除这条杂项支出吗？删除后可在回收站还原。")
                } else {
                    Text("")
                }
            }
        }
    }

    // MARK: - 导出图片
    @MainActor
    private func exportToImage() {
        let title = selectedTab == 0 ? "成交记录" : (selectedTab == 1 ? "杂项收入" : "杂项支出")
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "yyyy年M月d日 HH:mm"
        let dateStr = df.string(from: Date())

        let view = ExportTableView(
            title: title,
            dateStr: dateStr,
            headers: selectedTab == 0 ? ["日期","房号","房东","户型","租金","中介费","备注"] : ["日期","项目","金额","备注"],
            rows: selectedTab == 0 ? filteredDeals.map { [
                DateFormatter.localizedString(from: $0.date, dateStyle: .short, timeStyle: .none),
                $0.roomNumber, $0.landlord, $0.unitType,
                "¥\(Int($0.rent))", "¥\(Int($0.totalFee))", $0.notes
            ]} : (selectedTab == 1 ? filteredIncomes.map { [
                DateFormatter.localizedString(from: $0.date, dateStyle: .short, timeStyle: .none),
                $0.item, "¥\(Int($0.amount))", $0.notes
            ]} : filteredExpenses.map { [
                DateFormatter.localizedString(from: $0.date, dateStyle: .short, timeStyle: .none),
                $0.item, "¥\(Int($0.amount))", $0.notes
            ]})
        )

        let renderer = ImageRenderer(content: view.frame(width: 700))
        renderer.scale = 2.0
        if let image = renderer.uiImage {
            let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(title)-\(Int(Date().timeIntervalSince1970)).png")
            if let data = image.pngData() {
                try? data.write(to: fileURL)
                exportURL = ExportURL(url: fileURL)
            }
        }
    }

    // MARK: - 导出Excel(.xls)
    private func exportToExcel() {
        let title = selectedTab == 0 ? "成交记录" : (selectedTab == 1 ? "杂项收入" : "杂项支出")
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        var headers: [String] = []
        var rows: [[String]] = []
        if selectedTab == 0 {
            headers = ["成交日期","房号","房东","户型","起租期","到期日","租期","月租金","押金","预存","交租日","房东中介费","租客中介费","管理人","客源","备注"]
            for deal in filteredDeals {
                rows.append([df.string(from: deal.date), deal.roomNumber, deal.landlord, deal.unitType,
                             df.string(from: deal.leaseStart), df.string(from: deal.leaseEnd), deal.leaseDuration,
                             "\(Int(deal.rent))", "\(Int(deal.deposit))", "\(Int(deal.prepayment))",
                             deal.rentDueDay.map { "\($0)" } ?? "",
                             "\(Int(deal.agentFeeLandlord))", "\(Int(deal.agentFeeTenant))",
                             deal.manager, deal.source, deal.notes])
            }
        } else if selectedTab == 1 {
            headers = ["日期","项目","金额","备注"]
            for inc in filteredIncomes {
                rows.append([df.string(from: inc.date), inc.item, "\(Int(inc.amount))", inc.notes])
            }
        } else {
            headers = ["日期","项目","金额","备注"]
            for exp in filteredExpenses {
                rows.append([df.string(from: exp.date), exp.item, "\(Int(exp.amount))", exp.notes])
            }
        }
        let html = makeExcelHTML(title: title, headers: headers, rows: rows)
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(title)-\(Int(Date().timeIntervalSince1970)).xls")
        try? html.write(to: fileURL, atomically: true, encoding: .utf8)
        exportURL = ExportURL(url: fileURL)
    }

    // MARK: - 导出Excel模板(.xls)
    private func exportTemplate() {
        let title = selectedTab == 0 ? "成交记录" : (selectedTab == 1 ? "杂项收入" : "杂项支出")
        var headers: [String] = []
        var rows: [[String]] = []
        if selectedTab == 0 {
            headers = ["成交日期","房号","房东","户型","起租期","到期日","租期","月租金","押金","预存","交租日","房东中介费","租客中介费","管理人","客源","备注"]
            rows = [["2026-01-15","1-101","张三","单间上层","2026-01-15","2027-01-14","一年","1000","1000","500","1","500","500","李四","58同城","示例数据"]]
        } else if selectedTab == 1 {
            headers = ["日期","项目","金额","备注"]
            rows = [["2026-01-15","保洁费","200","示例"]]
        } else {
            headers = ["日期","项目","金额","备注"]
            rows = [["2026-01-15","维修费","300","示例"]]
        }
        let html = makeExcelHTML(title: title, headers: headers, rows: rows)
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(title)-模板.xls")
        try? html.write(to: fileURL, atomically: true, encoding: .utf8)
        exportURL = ExportURL(url: fileURL)
    }

    // MARK: - 导入文件(支持CSV和HTML格式的.xls)
    private func importFromFile(url: URL) {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

        // 读取文件内容，支持UTF-8和GBK
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

        // 解析数据行：支持CSV和HTML表格
        var rows: [[String]] = []
        if text.contains("<tr") {
            // HTML格式
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
            // 跳过表头
            if !rows.isEmpty { rows.removeFirst() }
        } else {
            // CSV格式
            let lines = text.components(separatedBy: .newlines).dropFirst()
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                rows.append(trimmed.components(separatedBy: ","))
            }
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        var count = 0
        for cols in rows {
            guard cols.count >= 3 else { continue }
            if selectedTab == 0 && cols.count >= 16 {
                let date = dateFormatter.date(from: cols[0]) ?? Date()
                let deal = DealRecord(
                    date: date, roomNumber: cols[1], landlord: cols[2],
                    unitType: cols[3], leaseStart: dateFormatter.date(from: cols[4]) ?? date,
                    leaseEnd: dateFormatter.date(from: cols[5]) ?? date,
                    leaseDuration: cols[6], rent: Double(cols[7]) ?? 0,
                    deposit: Double(cols[8]) ?? 0, prepayment: Double(cols[9]) ?? 0,
                    rentDueDay: Int(cols[10]),
                    agentFeeLandlord: Double(cols[11]) ?? 0,
                    agentFeeTenant: Double(cols[12]) ?? 0,
                    totalFee: (Double(cols[11]) ?? 0) + (Double(cols[12]) ?? 0),
                    manager: cols[13], source: cols[14], notes: cols[15]
                )
                modelContext.insert(deal)
                count += 1
            } else if selectedTab == 1 {
                let date = dateFormatter.date(from: cols[0]) ?? Date()
                modelContext.insert(MiscIncome(date: date, item: cols[1], amount: Double(cols[2]) ?? 0, notes: cols.count > 3 ? cols[3] : ""))
                count += 1
            } else if selectedTab == 2 {
                let date = dateFormatter.date(from: cols[0]) ?? Date()
                modelContext.insert(MiscExpense(date: date, item: cols[1], amount: Double(cols[2]) ?? 0, notes: cols.count > 3 ? cols[3] : ""))
                count += 1
            }
        }
    }

    private var dealList: some View {
        List {
            ForEach(filteredDeals) { deal in
                DealRow(deal: deal, hideAmount: hideDealAmount)
                    .contentShape(Rectangle())
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(highlightedCardID == deal.id ? Color.themeAccent : Color.clear, lineWidth: 2)
                            .animation(.easeInOut(duration: 0.2), value: highlightedCardID)
                    )
                    .onTapGesture {
                        highlightedCardID = deal.id
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            viewingDeal = deal
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            dealToDelete = deal
                            showDeleteConfirm = true
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                        .tint(.red)
                        Button {
                            editingDeal = deal
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
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.themeBg)
        .overlay {
            if filteredDeals.isEmpty {
                ContentUnavailableView("暂无成交记录", systemImage: "doc.text", description: Text("点击右上角 + 添加成交记录"))
            }
        }
    }

    private var incomeList: some View {
        List {
            ForEach(filteredIncomes) { inc in
                MiscRow(title: inc.item, subtitle: inc.notes, amount: inc.amount, date: inc.date, isIncome: true, hideAmount: hideIncomeAmount)
                    .contentShape(Rectangle())
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(highlightedCardID == inc.id ? Color.themeAccent : Color.clear, lineWidth: 2)
                            .animation(.easeInOut(duration: 0.2), value: highlightedCardID)
                    )
                    .onTapGesture {
                        highlightedCardID = inc.id
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            editingIncome = inc
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            incomeToDelete = inc
                            showDeleteConfirm = true
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                        .tint(.red)
                        Button {
                            editingIncome = inc
                        } label: {
                            Label("修改", systemImage: "pencil")
                        }
                        .tint(.themeBlue)
                    }
                    .listRowBackground(Color.themeBg)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.themeBg)
        .overlay {
            if filteredIncomes.isEmpty {
                ContentUnavailableView("暂无杂项收入", systemImage: "plus.circle", description: Text("点击右上角 + 添加收入"))
            }
        }
    }

    private var expenseList: some View {
        List {
            ForEach(filteredExpenses) { exp in
                MiscRow(title: exp.item, subtitle: exp.notes, amount: exp.amount, date: exp.date, isIncome: false, hideAmount: hideExpenseAmount)
                    .contentShape(Rectangle())
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(highlightedCardID == exp.id ? Color.themeAccent : Color.clear, lineWidth: 2)
                            .animation(.easeInOut(duration: 0.2), value: highlightedCardID)
                    )
                    .onTapGesture {
                        highlightedCardID = exp.id
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            editingExpense = exp
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            expenseToDelete = exp
                            showDeleteConfirm = true
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                        .tint(.red)
                        Button {
                            editingExpense = exp
                        } label: {
                            Label("修改", systemImage: "pencil")
                        }
                        .tint(.themeBlue)
                    }
                    .listRowBackground(Color.themeBg)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.themeBg)
        .overlay {
            if filteredExpenses.isEmpty {
                ContentUnavailableView("暂无支出记录", systemImage: "arrow.up.circle", description: Text("点击右上角 + 添加支出"))
            }
        }
    }

    private func deleteDeal(at offsets: IndexSet) {
        for index in offsets { filteredDeals[index].isDeleted = true; filteredDeals[index].deletedAt = Date() }
        try? modelContext.save()
        BackupLogStore.log(category: "成交", action: "删除成交记录", result: "成功", detail: "删除 \(offsets.count) 条（移入回收站）")
    }
    private func deleteIncome(at offsets: IndexSet) {
        for index in offsets { filteredIncomes[index].isDeleted = true; filteredIncomes[index].deletedAt = Date() }
        try? modelContext.save()
        BackupLogStore.log(category: "成交", action: "删除收入记录", result: "成功", detail: "删除 \(offsets.count) 条（移入回收站）")
    }
    private func deleteExpense(at offsets: IndexSet) {
        for index in offsets { filteredExpenses[index].isDeleted = true; filteredExpenses[index].deletedAt = Date() }
        try? modelContext.save()
        BackupLogStore.log(category: "成交", action: "删除支出记录", result: "成功", detail: "删除 \(offsets.count) 条（移入回收站）")
    }
}

// MARK: - 筛选标签
struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? .white : .themeText2)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(isSelected ? Color.themeAccent : Color.themePanel)
                .cornerRadius(14)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(isSelected ? Color.clear : Color.themeBorder, lineWidth: 1)
                )
        }
    }
}

// MARK: - 行组件
struct DealRow: View {
    let deal: DealRecord
    var hideAmount: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                // 第一行：房号+户型（重点突出，加粗放大）
                HStack(spacing: 8) {
                    Text(deal.roomNumber)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.themeText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Color(hex: "F0F0F0"))
                        .cornerRadius(.infinity)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    if !deal.unitType.isEmpty {
                        Text(deal.unitType)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.themeText)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Color(hex: "E8F0FE"))
                            .cornerRadius(.infinity)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    Spacer(minLength: 0)
                }
                // 第二行：月租+押金
                HStack(spacing: 6) {
                    if deal.rent > 0 {
                        Text(verbatim: "月租¥\(Int(deal.rent))/月")
                            .font(.system(size: 12))
                            .foregroundColor(.themeText2)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color(hex: "FFF3E0"))
                            .cornerRadius(.infinity)
                    }
                    if deal.deposit > 0 {
                        Text(verbatim: "押金¥\(Int(deal.deposit))")
                            .font(.system(size: 12))
                            .foregroundColor(.themeText2)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color(hex: "FFF3E0"))
                            .cornerRadius(.infinity)
                    }
                }
                // 第三行：备注（始终显示）
                Text("备注：\(deal.notes.isEmpty ? "无" : deal.notes)")
                    .font(.system(size: 12))
                    .foregroundColor(.themeText2)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color(hex: "F3E5F5"))
                    .cornerRadius(.infinity)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 72)
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                Text(verbatim: hideAmount ? "**" : "+¥\(Int(deal.totalFee))")
                    .foregroundColor(.themeRed)
                    .font(.system(size: 16, weight: .bold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Color(hex: "FDECEC"))
                    .cornerRadius(.infinity)
                Text(deal.date, style: .date)
                    .font(.system(size: 11))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(Color.themeAccent)
                    .cornerRadius(.infinity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.themePanel)
        .cornerRadius(12)
    }
}

struct MiscRow: View {
    let title: String
    let subtitle: String
    let amount: Double
    let date: Date
    let isIncome: Bool
    var hideAmount: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            // 左边圆形图标 - 收入红色，支出绿色
            ZStack {
                Circle()
                    .fill(isIncome ? Color(hex: "E05555") : Color(hex: "0FA48B"))
                    .frame(width: 48, height: 48)
                Text(isIncome ? "收" : "支")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.themeText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color(hex: "F0F0F0"))
                    .cornerRadius(.infinity)
                if !subtitle.isEmpty {
                    Text("备注：\(subtitle)")
                        .font(.system(size: 12))
                        .foregroundColor(.themeText2)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color(hex: "F3E5F5"))
                        .cornerRadius(.infinity)
                        .lineLimit(1)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                Text(verbatim: hideAmount ? "**" : "\(isIncome ? "+" : "-")¥\(Int(amount))")
                    .foregroundColor(isIncome ? .themeRed : .themeAccentDark)
                    .font(.system(size: 16, weight: .bold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(isIncome ? Color(hex: "FDECEC") : Color(hex: "E2F4EF"))
                    .cornerRadius(.infinity)
                Text(date, style: .date)
                    .font(.system(size: 11))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(Color.themeAccent)
                    .cornerRadius(.infinity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.themePanel)
        .cornerRadius(12)
    }
}

// MARK: - 金额输入字段（不预留0）
struct AmountField: View {
    let label: String
    @Binding var text: String

    var body: some View {
        HStack {
            Text(label).foregroundColor(.themeText)
            Spacer()
            TextField("请输入", text: $text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .foregroundColor(.themeText)
                .frame(width: 120)
        }
    }
}

struct PropertyDraft: Identifiable { let id=UUID(); let roomNumber:String;let landlord:String;let unitType:String;let rent:Double;let deposit:Double;let prepayment:Double;let leaseStart:Date;let leaseEnd:Date;let leaseDuration:String;let rentDueDay:Int;let notes:String }

// MARK: - 新增成交
struct AddDealView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var date = Date()
    @State private var roomNumber = ""
    @State private var landlord = ""
    @State private var unitType = ""
    @State private var leaseStart = Date()
    @State private var leaseEnd = Date()
    @State private var leaseDuration = ""
    @State private var rentText = ""
    @State private var depositText = ""
    @State private var prepaymentText = ""
    @State private var rentDueDay: Int? = nil
    @State private var agentFeeLandlordText = ""
    @State private var agentFeeTenantText = ""
    @State private var manager = ""
    @State private var source = ""
    @State private var notes = ""
    @State private var propertyDraft: PropertyDraft?

    private let unitTypes = ["单间上层", "单间下层", "独立厨房上层", "独立厨房下层", "复式", "复式独立厨房", "中空复式", "平层", "双钥匙一套", "三房"]

    private var totalFee: Double {
        (Double(agentFeeLandlordText) ?? 0) + (Double(agentFeeTenantText) ?? 0)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    WheelDateField(label: "成交日期", date: $date)
                    TextRow(label: "房号", text: $roomNumber, allowSpaces: false)
                    TextRow(label: "房东", text: $landlord)
                    Picker("户型", selection: $unitType) {
                        Text("请选择").tag("")
                        ForEach(unitTypes, id: \.self) { Text($0).tag($0) }
                    }
                    WheelDateField(label: "起租期", date: $leaseStart)
                    WheelDateField(label: "到期日", date: $leaseEnd)
                    TextRow(label: "租期", text: $leaseDuration)
                    Picker("交租日期", selection: $rentDueDay) {
                        Text("未设置").tag(nil as Int?)
                        ForEach(1...31, id: \.self) { day in
                            Text("每月\(day)号").tag(day as Int?)
                        }
                    }
                }
                Section("金额") {
                    AmountField(label: "月租金", text: $rentText)
                    AmountField(label: "押金", text: $depositText)
                    AmountField(label: "预存", text: $prepaymentText)
                }
                Section("中介费") {
                    AmountField(label: "房东中介费", text: $agentFeeLandlordText)
                    AmountField(label: "租客中介费", text: $agentFeeTenantText)
                    HStack { Text("合计"); Spacer(); Text(verbatim: "¥\(Int(totalFee))").foregroundColor(.themeAccentDark).fontWeight(.medium) }
                }
                Section("其他") {
                    TextRow(label: "管理人", text: $manager)
                    TextRow(label: "客源", text: $source)
                    TextField("备注", text: $notes, axis: .vertical)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.themeBg)
            .navigationTitle("新增成交")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item:$propertyDraft,onDismiss:{dismiss()}){AddPropertyView(prefill:$0)}
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let deal = DealRecord(
                            date: date, roomNumber: roomNumber, landlord: landlord,
                            unitType: unitType, leaseStart: leaseStart, leaseEnd: leaseEnd,
                            leaseDuration: leaseDuration,
                            rent: Double(rentText) ?? 0, deposit: Double(depositText) ?? 0,
                            prepayment: Double(prepaymentText) ?? 0, rentDueDay: rentDueDay,
                            agentFeeLandlord: Double(agentFeeLandlordText) ?? 0,
                            agentFeeTenant: Double(agentFeeTenantText) ?? 0,
                            totalFee: totalFee, manager: manager, source: source, notes: notes)
                        modelContext.insert(deal)
                        try? modelContext.save()
                        BackupLogStore.log(category: "成交", action: "新增成交", result: "成功", detail: "房号 \(roomNumber) 成交，月租¥\(Int(Double(rentText) ?? 0))")
                        if let due=rentDueDay { propertyDraft=PropertyDraft(roomNumber:roomNumber,landlord:landlord,unitType:unitType,rent:Double(rentText) ?? 0,deposit:Double(depositText) ?? 0,prepayment:Double(prepaymentText) ?? 0,leaseStart:leaseStart,leaseEnd:leaseEnd,leaseDuration:leaseDuration,rentDueDay:due,notes:notes) } else { dismiss() }
                    }
                    .disabled(roomNumber.isEmpty)
                    .foregroundColor(.themeAccent)
                }
            }
        }
    }
}

// MARK: - 编辑成交
struct EditDealView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let deal: DealRecord

    @State private var date: Date
    @State private var roomNumber: String
    @State private var landlord: String
    @State private var unitType: String
    @State private var leaseStart: Date
    @State private var leaseEnd: Date
    @State private var leaseDuration: String
    @State private var rentText: String
    @State private var depositText: String
    @State private var prepaymentText: String
    @State private var rentDueDay: Int?
    @State private var agentFeeLandlordText: String
    @State private var agentFeeTenantText: String
    @State private var manager: String
    @State private var source: String
    @State private var notes: String

    private let unitTypes = ["单间上层", "单间下层", "独立厨房上层", "独立厨房下层", "复式", "复式独立厨房", "中空复式", "平层", "双钥匙一套", "三房"]

    init(deal: DealRecord) {
        self.deal = deal
        _date = State(initialValue: deal.date)
        _roomNumber = State(initialValue: deal.roomNumber)
        _landlord = State(initialValue: deal.landlord)
        _unitType = State(initialValue: deal.unitType)
        _leaseStart = State(initialValue: deal.leaseStart)
        _leaseEnd = State(initialValue: deal.leaseEnd)
        _leaseDuration = State(initialValue: deal.leaseDuration)
        _rentText = State(initialValue: deal.rent > 0 ? String(Int(deal.rent)) : "")
        _depositText = State(initialValue: deal.deposit > 0 ? String(Int(deal.deposit)) : "")
        _prepaymentText = State(initialValue: deal.prepayment > 0 ? String(Int(deal.prepayment)) : "")
        _rentDueDay = State(initialValue: deal.rentDueDay)
        _agentFeeLandlordText = State(initialValue: deal.agentFeeLandlord > 0 ? String(Int(deal.agentFeeLandlord)) : "")
        _agentFeeTenantText = State(initialValue: deal.agentFeeTenant > 0 ? String(Int(deal.agentFeeTenant)) : "")
        _manager = State(initialValue: deal.manager)
        _source = State(initialValue: deal.source)
        _notes = State(initialValue: deal.notes)
    }

    private var totalFee: Double {
        (Double(agentFeeLandlordText) ?? 0) + (Double(agentFeeTenantText) ?? 0)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    WheelDateField(label: "成交日期", date: $date)
                    TextRow(label: "房号", text: $roomNumber, allowSpaces: false)
                    TextRow(label: "房东", text: $landlord)
                    Picker("户型", selection: $unitType) {
                        Text("请选择").tag("")
                        ForEach(unitTypes, id: \.self) { Text($0).tag($0) }
                    }
                    WheelDateField(label: "起租期", date: $leaseStart)
                    WheelDateField(label: "到期日", date: $leaseEnd)
                    TextRow(label: "租期", text: $leaseDuration)
                    Picker("交租日期", selection: $rentDueDay) {
                        Text("未设置").tag(nil as Int?)
                        ForEach(1...31, id: \.self) { day in
                            Text("每月\(day)号").tag(day as Int?)
                        }
                    }
                }
                Section("金额") {
                    AmountField(label: "月租金", text: $rentText)
                    AmountField(label: "押金", text: $depositText)
                    AmountField(label: "预存", text: $prepaymentText)
                }
                Section("中介费") {
                    AmountField(label: "房东中介费", text: $agentFeeLandlordText)
                    AmountField(label: "租客中介费", text: $agentFeeTenantText)
                    HStack { Text("合计"); Spacer(); Text(verbatim: "¥\(Int(totalFee))").foregroundColor(.themeAccentDark).fontWeight(.medium) }
                }
                Section("其他") {
                    TextRow(label: "管理人", text: $manager)
                    TextRow(label: "客源", text: $source)
                    TextField("备注", text: $notes, axis: .vertical)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.themeBg)
            .navigationTitle("编辑成交")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        deal.date = date
                        deal.roomNumber = roomNumber
                        deal.landlord = landlord
                        deal.unitType = unitType
                        deal.leaseStart = leaseStart
                        deal.leaseEnd = leaseEnd
                        deal.leaseDuration = leaseDuration
                        deal.rent = Double(rentText) ?? 0
                        deal.deposit = Double(depositText) ?? 0
                        deal.prepayment = Double(prepaymentText) ?? 0
                        deal.rentDueDay = rentDueDay
                        deal.agentFeeLandlord = Double(agentFeeLandlordText) ?? 0
                        deal.agentFeeTenant = Double(agentFeeTenantText) ?? 0
                        deal.totalFee = totalFee
                        deal.manager = manager
                        deal.source = source
                        deal.notes = notes
                        dismiss()
                    }
                    .disabled(roomNumber.isEmpty)
                    .foregroundColor(.themeAccent)
                }
            }
        }
    }
}

// MARK: - 新增杂项
struct AddMiscView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let type: MiscType

    @State private var date = Date()
    @State private var item = ""
    @State private var amountText = ""
    @State private var notes = ""

    enum MiscType { case income, expense }

    var body: some View {
        NavigationStack {
            Form {
                Section("信息") {
                    WheelDateField(label: "日期", date: $date)
                    TextField("项目", text: $item)
                    AmountField(label: "金额", text: $amountText)
                    TextField("备注", text: $notes, axis: .vertical)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.themeBg)
            .navigationTitle(type == .income ? "新增收入" : "新增支出")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let amount = Double(amountText) ?? 0
                        if type == .income {
                            modelContext.insert(MiscIncome(date: date, item: item, amount: amount, notes: notes))
                            // v1.19 补全 #9：新增杂项收入写操作日志
                            BackupLogStore.log(category: "杂项", action: "新增收入", result: "成功", detail: "\(item) ¥\(Int(amount))")
                        } else {
                            modelContext.insert(MiscExpense(date: date, item: item, amount: amount, notes: notes))
                            // v1.19 补全 #9：新增杂项支出写操作日志
                            BackupLogStore.log(category: "杂项", action: "新增支出", result: "成功", detail: "\(item) ¥\(Int(amount))")
                        }
                        dismiss()
                    }
                    .disabled(item.isEmpty || amountText.isEmpty)
                    .foregroundColor(.themeAccent)
                }
            }
        }
    }
}

// MARK: - 编辑杂项
struct EditMiscView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let item: MiscItem

    @State private var date: Date
    @State private var title: String
    @State private var amountText: String
    @State private var notes: String

    enum MiscItem {
        case income(MiscIncome)
        case expense(MiscExpense)
    }

    init(item: MiscItem) {
        self.item = item
        switch item {
        case .income(let inc):
            _date = State(initialValue: inc.date)
            _title = State(initialValue: inc.item)
            _amountText = State(initialValue: inc.amount > 0 ? String(Int(inc.amount)) : "")
            _notes = State(initialValue: inc.notes)
        case .expense(let exp):
            _date = State(initialValue: exp.date)
            _title = State(initialValue: exp.item)
            _amountText = State(initialValue: exp.amount > 0 ? String(Int(exp.amount)) : "")
            _notes = State(initialValue: exp.notes)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("信息") {
                    WheelDateField(label: "日期", date: $date)
                    TextField("项目", text: $title)
                    AmountField(label: "金额", text: $amountText)
                    TextField("备注", text: $notes, axis: .vertical)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.themeBg)
            .navigationTitle("编辑记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let amount = Double(amountText) ?? 0
                        switch item {
                        case .income(let inc):
                            inc.date = date; inc.item = title; inc.amount = amount; inc.notes = notes
                        case .expense(let exp):
                            exp.date = date; exp.item = title; exp.amount = amount; exp.notes = notes
                        }
                        dismiss()
                    }
                    .disabled(title.isEmpty || amountText.isEmpty)
                    .foregroundColor(.themeAccent)
                }
            }
        }
    }
}

// MARK: - 导出URL包装
// MARK: - 导出用表格视图
struct ExportTableView: View {
    let title: String
    let dateStr: String
    let headers: [String]
    let rows: [[String]]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.black)
                .padding(.bottom, 4)
            Text("导出时间: \(dateStr)")
                .font(.system(size: 11))
                .foregroundColor(.gray)
                .padding(.bottom, 12)

            // 表头
            HStack(spacing: 0) {
                ForEach(headers.indices, id: \.self) { i in
                    Text(headers[i])
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 8)
                }
            }
            .background(Color(hex: "143B34"))

            // 数据行
            ForEach(rows.indices, id: \.self) { rowIdx in
                HStack(spacing: 0) {
                    ForEach(rows[rowIdx].indices, id: \.self) { colIdx in
                        Text(rows[rowIdx][colIdx])
                            .font(.system(size: 10))
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 6)
                            .lineLimit(1)
                    }
                }
                .background(rowIdx % 2 == 0 ? Color.themePanel : Color(hex: "E8E8E8"))
            }

            Text("共 \(rows.count) 条记录")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.black)
                .padding(.top, 10)
        }
        .padding(20)
        .background(Color.themePanel)
    }
}

struct ExportURL: Identifiable {
    let id = UUID()
    let url: URL
}

// MARK: - 成交只读详情
struct DealDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let deal: DealRecord
    var onEdit: () -> Void

    private var dateFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy年M月d日"
        return f
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    LabeledContent("成交日期", value: dateFormatter.string(from: deal.date))
                    LabeledContent("房号", value: deal.roomNumber)
                    LabeledContent("房东", value: deal.landlord.isEmpty ? "无" : deal.landlord)
                    LabeledContent("户型", value: deal.unitType.isEmpty ? "无" : deal.unitType)
                    LabeledContent("起租期", value: dateFormatter.string(from: deal.leaseStart))
                    LabeledContent("到期日", value: dateFormatter.string(from: deal.leaseEnd))
                    if !deal.leaseDuration.isEmpty { LabeledContent("租期", value: deal.leaseDuration) }
                    if let day = deal.rentDueDay { LabeledContent("交租日", value: "每月\(day)号") }
                }
                Section("金额") {
                    LabeledContent("月租金", value: "¥\(Int(deal.rent))")
                    LabeledContent("押金", value: "¥\(Int(deal.deposit))")
                    if deal.prepayment > 0 { LabeledContent("预存", value: "¥\(Int(deal.prepayment))") }
                }
                Section("中介费") {
                    LabeledContent("房东中介费", value: "¥\(Int(deal.agentFeeLandlord))")
                    LabeledContent("租客中介费", value: "¥\(Int(deal.agentFeeTenant))")
                    LabeledContent("合计", value: "¥\(Int(deal.totalFee))")
                }
                Section("其他") {
                    if !deal.manager.isEmpty { LabeledContent("管理人", value: deal.manager) }
                    if !deal.source.isEmpty { LabeledContent("来源", value: deal.source) }
                    if !deal.notes.isEmpty { LabeledContent("备注", value: deal.notes) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.themeBg)
            .labeledContentStyle(DetailLabeledContentStyle())
            .navigationTitle(deal.roomNumber)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() }.foregroundColor(.themeAccent) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("编辑") {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            onEdit()
                        }
                    }
                    .foregroundColor(.themeAccent)
                }
            }
        }
    }
}

// MARK: - 分享Sheet
struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
