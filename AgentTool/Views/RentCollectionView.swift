import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct RentCollectionView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Property> { !$0.isDeleted }, sort: \Property.roomNumber) private var properties: [Property]
    @State private var showingAddProperty = false
    @State private var editingProperty: Property?
    @State private var selectedProperty: Property?
    @State private var searchText = ""
    @State private var selectedDueDay: Int? = nil
    @State private var showUtility = false
    @State private var exportURL: ExportURL?
    @State private var showRefreshTip = false
    @State private var refreshID = UUID()
    @State private var highlightedCardID: UUID?
    @State private var propertyToDelete: Property?
    @State private var terminatingProperty: Property?
    @State private var showDeleteConfirm = false
    @State private var selectedStatus = 0
    @State private var propertyToRestore: Property?
    @State private var showRestoreConfirm = false

    // 只显示当前页面已登记的交租日期
    private var registeredDueDays: [Int] {
        Array(Set(properties.filter { $0.isTerminated == (selectedStatus == 1) }.map { $0.rentDueDay })).sorted()
    }

    // 预计算排序信息，避免排序闭包内嵌遍历
    private struct PropertySortInfo {
        let property: Property
        let isPaid: Bool
        let sortDays: Int
    }

    private var filteredProperties: [Property] {
        let currentMonth = Calendar.current.component(.month, from: Date())
        let currentYear = Calendar.current.component(.year, from: Date())
        let currentDay = Calendar.current.component(.day, from: Date())

        // 第一步：过滤
        let filtered = properties.filter { prop in
            let statusMatch = prop.isTerminated == (selectedStatus == 1)
            let dayMatch = selectedDueDay == nil || prop.rentDueDay == selectedDueDay
            let searchMatch = searchText.isEmpty ||
                prop.roomNumber.localizedCaseInsensitiveContains(searchText) ||
                prop.landlord.localizedCaseInsensitiveContains(searchText) ||
                prop.unitType.localizedCaseInsensitiveContains(searchText) ||
                prop.propertyType.localizedCaseInsensitiveContains(searchText) ||
                prop.notes.localizedCaseInsensitiveContains(searchText)
            return statusMatch && dayMatch && searchMatch
        }

        // 第二步：预计算排序信息（单次遍历）
        let sortInfos: [PropertySortInfo] = filtered.map { prop in
            let isPaid = prop.isPaidForCard
            let isOverdue = !isPaid && prop.rentDueDay < currentDay
            let sortDays: Int
            if isPaid {
                sortDays = 999 // 已收租的排最后
            } else if isOverdue {
                sortDays = -(currentDay - prop.rentDueDay) // 逾期越久，sortDays越小，越靠前
            } else {
                sortDays = prop.rentDueDay - currentDay // 未逾期，离交租日越近越靠前
            }
            return PropertySortInfo(property: prop, isPaid: isPaid, sortDays: sortDays)
        }

        // 第三步：排序（使用预计算的信息，不再内嵌遍历）
        return sortInfos.sorted { a, b in
            if a.isPaid != b.isPaid { return !a.isPaid && b.isPaid }
            if a.sortDays != b.sortDays { return a.sortDays < b.sortDays }
            return a.property.roomNumber < b.property.roomNumber
        }.map { $0.property }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 搜索 + 筛选栏
                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.themeText3)
                        TextField("搜索房号、房东、户型…", text: $searchText)
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

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            FilterChip(title: "全部", isSelected: selectedDueDay == nil) {
                                selectedDueDay = nil
                            }
                            ForEach(registeredDueDays, id: \.self) { day in
                                FilterChip(title: "\(day)号", isSelected: selectedDueDay == day) {
                                    selectedDueDay = (selectedDueDay == day) ? nil : day
                                }
                            }
                        }
                    }

                    Picker("租赁状态", selection: $selectedStatus) {
                        Text(selectedStatus == 0 ? "在租-\(filteredProperties.count)" : "在租").tag(0)
                        Text(selectedStatus == 1 ? "退租-\(filteredProperties.count)" : "退租").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: selectedStatus) { _, _ in selectedDueDay = nil }

                }
                .padding(.horizontal)
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
                    ForEach(filteredProperties) { prop in
                        Group {
                            if prop.isTerminated {
                                TerminatedPropertyRow(property: prop)
                            } else {
                                PropertyRentRow(property: prop)
                            }
                        }
                            .contentShape(Rectangle())
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(highlightedCardID == prop.id ? Color.themeAccent : Color.clear, lineWidth: 2)
                                    .animation(.easeInOut(duration: 0.2), value: highlightedCardID)
                            )
                            .onTapGesture {
                                highlightedCardID = prop.id
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                    selectedProperty = prop
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    propertyToDelete = prop
                                    showDeleteConfirm = true
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                                .tint(.red)
                                Button {
                                    if prop.isTerminated { propertyToRestore = prop; showRestoreConfirm = true }
                                    else { terminatingProperty = prop }
                                } label: { Label(prop.isTerminated ? "还原" : "退租", systemImage: prop.isTerminated ? "arrow.uturn.backward" : "rectangle.portrait.and.arrow.right") }
                                .tint(.themeBlue)
                            }
                            .listRowBackground(Color.themeBg)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                .id(refreshID)
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .refreshable {
                    refreshRentList()
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
                .overlay {
                    if filteredProperties.isEmpty {
                        ContentUnavailableView("暂无房源", systemImage: "house", description: Text("点击右上角 + 添加房源"))
                    }
                }
            }
            .background(Color.themeBg)
            .navigationTitle("收租管理")
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
                    HStack(spacing: 12) {
                        Button { showUtility = true } label: {
                            Image(systemName: "bolt.fill").foregroundColor(.themeAccent)
                        }
                        Button { showingAddProperty = true } label: {
                            Image(systemName: "plus.circle.fill").foregroundColor(.themeAccent)
                        }
                    }
                }
            }
            .sheet(isPresented: $showingAddProperty, onDismiss: refreshRentList) {
                AddPropertyView()
            }
            .sheet(item: $editingProperty, onDismiss: refreshRentList) { prop in
                AddPropertyView(property: prop)
            }
            .sheet(item: $selectedProperty) { prop in PropertyDetailView(property: prop) }
            .sheet(item:$terminatingProperty,onDismiss:refreshRentList){TerminationFormView(property:$0)}
            .sheet(isPresented: $showUtility) { NavigationStack { UtilityView(onWriteSuccess: { refreshRentList() }) } }
            .sheet(item: $exportURL) { url in
                ShareSheet(activityItems: [url.url])
            }
            .alert("删除到回收站", isPresented: $showDeleteConfirm) {
                Button("取消", role: .cancel) { propertyToDelete = nil }
                Button("确定删除", role: .destructive) {
                    if let prop = propertyToDelete {
                        prop.isDeleted = true; prop.deletedAt = Date()
                        refreshRentList()
                    }
                    propertyToDelete = nil
                }
            } message: {
                Text("确定删除这条收租记录吗？删除后可在回收站还原。")
            }
            .alert("还原到在租？", isPresented: $showRestoreConfirm) {
                Button("取消", role: .cancel) { propertyToRestore = nil }
                Button("确认还原") {
                    if let prop = propertyToRestore {
                        prop.isTerminated = false
                        prop.terminationDate = nil
                        prop.terminationReason = ""
                        prop.depositRefundStatus = ""
                        prop.roomDamageStatus = ""
                        prop.utilitySettlementStatus = ""
                        prop.terminationPerson = ""
                        prop.terminationPhone = ""
                        try? modelContext.save()
                        refreshRentList()
                    }
                    propertyToRestore = nil
                }
            } message: {
                Text("退租信息将清空，房源卡片和表单会恢复为在租状态。")
            }
        }
    }

    private func deleteProperty(at offsets: IndexSet) {
        for index in offsets { filteredProperties[index].isDeleted = true; filteredProperties[index].deletedAt = Date() }
        refreshRentList()
    }

    private func refreshRentList() {
        try? modelContext.save()
        refreshID = UUID()
    }

    // MARK: - 导出图片
    @MainActor
    private func exportToImage() {
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "yyyy年M月d日 HH:mm"
        let dateStr = df.string(from: Date())
        let currentMonth = Calendar.current.component(.month, from: Date())
        let currentYear = Calendar.current.component(.year, from: Date())
        let rows = filteredProperties.map { prop -> [String] in
            let paid = prop.monthlyRentRecords.contains { $0.year == currentYear && $0.month == currentMonth && $0.isPaid }
            return [prop.roomNumber, prop.landlord, prop.unitType,
                    "¥\(Int(prop.rent))", "\(prop.rentDueDay)号",
                    prop.propertyType, paid ? "已收" : "未收"]
        }
        let view = ExportTableView(
            title: "收租记录", dateStr: dateStr,
            headers: ["房号","房东","户型","月租","交租日","类型","本月状态"],
            rows: rows
        )
        let renderer = ImageRenderer(content: view.frame(width: 700))
        renderer.scale = 2.0
        if let image = renderer.uiImage {
            let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("收租记录-\(Int(Date().timeIntervalSince1970)).png")
            if let data = image.pngData() {
                try? data.write(to: fileURL)
                exportURL = ExportURL(url: fileURL)
            }
        }
    }

    // MARK: - 导出Excel(.xls)
    private func exportToExcel() {
        let headers = ["房号","房东","户型","月租金","交租日","房源类型","备注","预存金额","本月应收","本月状态","收租明细"]
        let rows = filteredProperties.map { prop -> [String] in
            let cal = Calendar.current
            let y = cal.component(.year, from: Date())
            let m = cal.component(.month, from: Date())
            let current = prop.monthlyRentRecords.first { $0.year == y && $0.month == m }
            let amount = current?.amount ?? (prop.rent + prop.prepayment)
            let status = current?.isPaid == true ? "已收" : "未收"
            let records = prop.monthlyRentRecords.sorted { ($0.year, $0.month) < ($1.year, $1.month) }
            let detail = records.map { "\($0.year)年\($0.month)月:\($0.isPaid ? "已收" : "未收")¥\(Int($0.amount))" }.joined(separator: "；")
            return [prop.roomNumber, prop.landlord, prop.unitType, "\(Int(prop.rent))", "\(prop.rentDueDay)", prop.propertyType, prop.notes, "\(Int(prop.prepayment))", "\(Int(amount))", status, detail]
        }
        let html = makeExcelHTML(title: "收租记录", headers: headers, rows: rows)
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("收租记录-\(Int(Date().timeIntervalSince1970)).xls")
        try? html.write(to: fileURL, atomically: true, encoding: .utf8)
        exportURL = ExportURL(url: fileURL)
    }

    private func exportTemplate() {
        let headers = ["房号","房东","户型","月租金","交租日","房源类型","备注","预存金额","本月应收","本月状态","收租明细"]
        let rows = [["1-101","张三","单间上层","1000","1","管理","示例","300","1300","未收",""]]
        let html = makeExcelHTML(title: "收租记录", headers: headers, rows: rows)
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("收租记录-模板.xls")
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

        for cols in rows {
            guard cols.count >= 5 else { continue }
            let prop = Property(
                roomNumber: cols[0], landlord: cols[1], unitType: cols[2],
                rent: Double(cols[3]) ?? 0, rentDueDay: Int(cols[4]) ?? 1,
                propertyType: cols.count > 5 ? cols[5] : "管理",
                notes: cols.count > 6 ? cols[6] : ""
            )
            modelContext.insert(prop)
        }
    }
}

struct PropertyRentRow: View {
    let property: Property
    private var currentMonth: Int { Calendar.current.component(.month, from: Date()) }
    private var currentYear: Int { Calendar.current.component(.year, from: Date()) }

    private var paidMonthsCount: Int {
        property.monthlyRentRecords.filter { $0.isPaid }.count
    }

    private var totalUtility: Double {
        property.utilitySettlementRecords.reduce(0) { $0 + $1.electricAmount + $1.waterAmount }
    }

    private var leaseYears: String {
        guard !property.leaseStart.isEmpty, !property.leaseEnd.isEmpty else { return "" }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy.M.d"
        guard let start = fmt.date(from: property.leaseStart),
              let end = fmt.date(from: property.leaseEnd) else { return "" }
        let months = Calendar.current.dateComponents([.month], from: start, to: end).month ?? 0
        if months >= 12 {
            let years = Double(months) / 12.0
            return years.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(years))年" : String(format: "%.1f年", years)
        }
        return "\(months)个月"
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                // 第一行：交租日 + 房号（重点突出，字体放大）
                HStack(spacing: 8) {
                    Text("\(property.rentDueDay)号")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.themeRed)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Color(hex: "FDF0F0"))
                        .cornerRadius(.infinity)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Text(property.roomNumber)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.themeText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Color(hex: "F0F0F0"))
                        .cornerRadius(.infinity)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                }
                // 第二行：租金 + 预存 + 房东
                HStack(spacing: 6) {
                    Text(verbatim: "租/\(Int(property.rent))")
                        .font(.system(size: 12))
                        .foregroundColor(.themeText2)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color(hex: "FFF3E0"))
                        .cornerRadius(.infinity)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    if property.prepayment > 0 {
                        Text(verbatim: "预/\(Int(property.prepayment))")
                            .font(.system(size: 12))
                            .foregroundColor(.themeText2)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color(hex: "E8F5E9"))
                            .cornerRadius(.infinity)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    if !property.landlord.isEmpty {
                        Text(property.landlord)
                            .font(.system(size: 12))
                            .foregroundColor(.themeText2)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color(hex: "E8F0FE"))
                            .cornerRadius(.infinity)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    Spacer(minLength: 0)
                }
                // 第三行：租期（不变）
                HStack(spacing: 6) {
                    Text(property.leaseStart.isEmpty ? "未出租" : "\(property.leaseStart)至\(property.leaseEnd)")
                        .font(.system(size: 12))
                        .foregroundColor(property.leaseStart.isEmpty ? .themeAmber : .themeText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color(hex: "F0F0F0"))
                        .cornerRadius(.infinity)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    if !property.leaseDuration.isEmpty {
                        Text(property.leaseDuration)
                            .font(.system(size: 12))
                            .foregroundColor(.themeText)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color(hex: "E8F5E9"))
                            .cornerRadius(.infinity)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 右侧：已收月数 + 累计水电 + 收租状态（重点突出，加粗放大）
            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 0) {
                    Text("已收")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.themeText2)
                    Text("\(paidMonthsCount)")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.themeAccentDark)
                    Text("个月")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.themeText2)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color(hex: "E8F5E9"))
                .cornerRadius(.infinity)
                HStack(spacing: 0) {
                    Text("累计水电:")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.themeText2)
                    Text(verbatim: "\(Int(totalUtility))")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.themeAccentDark)
                    Text("元")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.themeText2)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color(hex: "FFF3E0"))
                .cornerRadius(.infinity)
                let paid = property.isPaidForCard
                HStack(spacing: 4) {
                    Image(systemName: paid ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(paid ? .themeAccent : .themeText3)
                        .font(.system(size: 18))
                    Text(paid ? "已收" : "待收")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(paid ? .themeAccentDark : .themeAmber)
                }
            }
            .frame(width: 115, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
        .padding(14)
        .background(Color.themePanel)
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.themeBorder, lineWidth: 1))
    }
}

// MARK: - 退租房源卡片
struct TerminatedPropertyRow: View {
    let property: Property
    private var dateText: String {
        guard let date = property.terminationDate else { return "未填日期" }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy.M.d"
        return formatter.string(from: date)
    }
    private var paidMonthsCount: Int { property.monthlyRentRecords.filter(\.isPaid).count }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    capsule(property.roomNumber, background: "F0F0F0", color: .themeText, bold: true)
                    capsule(property.terminationReason.isEmpty ? "已退租" : property.terminationReason, background: "F3E5F5")
                    Spacer(minLength: 0)
                }
                HStack(spacing: 6) {
                    capsule("租/\(Int(property.rent))", background: "FFF3E0")
                    if !property.landlord.isEmpty { capsule(property.landlord, background: "E8F0FE") }
                    Spacer(minLength: 0)
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 8) {
                capsule("已收\(paidMonthsCount)个月", background: "E8F5E9", color: .themeAccentDark, bold: true)
                capsule("\(dateText)退租", background: "FDF0F0", color: .themeRed, bold: true)
            }
        }
        .padding(14).background(Color.themePanel).cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.themeBorder, lineWidth: 1))
    }

    private func capsule(_ text: String, background: String, color: Color = .themeText2, bold: Bool = false) -> some View {
        Text(text).font(.system(size: bold ? 13 : 12, weight: bold ? .bold : .regular)).foregroundColor(color)
            .padding(.horizontal, 10).padding(.vertical, 4).background(Color(hex: background)).cornerRadius(.infinity)
            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - 退租登记
struct TerminationFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let property: Property
    var onSaved: (() -> Void)? = nil
    @State private var date: Date
    @State private var reason: String
    @State private var deposit: String
    @State private var damage: String
    @State private var utility: String
    @State private var person: String
    @State private var phone: String

    init(property: Property, onSaved: (() -> Void)? = nil) {
        self.property = property
        self.onSaved = onSaved
        _date = State(initialValue: property.terminationDate ?? Date())
        _reason = State(initialValue: property.terminationReason)
        _deposit = State(initialValue: property.depositRefundStatus)
        _damage = State(initialValue: property.roomDamageStatus)
        _utility = State(initialValue: property.utilitySettlementStatus)
        _person = State(initialValue: property.terminationPerson)
        _phone = State(initialValue: property.terminationPhone)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("退租信息（均可不填）") {
                    WheelDateField(label: "退租时间", date: $date)
                    TextField("退租原因", text: $reason)
                    TextField("押金退还情况", text: $deposit)
                    TextField("房间损坏情况", text: $damage)
                    TextField("水电结算情况", text: $utility)
                    TextField("退租人", text: $person)
                    TextField("退租人联系电话", text: $phone).keyboardType(.phonePad)
                }
            }
            .navigationTitle("退租登记")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        property.terminationDate = date
                        property.terminationReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
                        property.depositRefundStatus = deposit.trimmingCharacters(in: .whitespacesAndNewlines)
                        property.roomDamageStatus = damage.trimmingCharacters(in: .whitespacesAndNewlines)
                        property.utilitySettlementStatus = utility.trimmingCharacters(in: .whitespacesAndNewlines)
                        property.terminationPerson = person.trimmingCharacters(in: .whitespacesAndNewlines)
                        property.terminationPhone = phone.trimmingCharacters(in: .whitespacesAndNewlines)
                        property.isTerminated = true
                        try? modelContext.save()
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { onSaved?() }
                    }
                }
            }
        }
    }
}

// MARK: - 房源详情（收租/水电）
struct PropertyDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let property: Property
    @State private var currentMonth = Calendar.current.component(.month, from: Date())
    @State private var shareImage: UIImage?
    @State private var showShareSheet = false
    @State private var showTerminationForm = false
    @State private var showRestoreTenancyConfirm = false
    @State private var showUtilitySheet = false
    @State private var showEditProperty = false
    @State private var showRentPlanEditor=false
    @State private var showUtilityPlanEditor=false
    @State private var selectedBillRecord: RentMonthRecord?
    @State private var showBillMonths=false
    @State private var billImage:UIImage?
    @State private var showBillShare=false
    @State private var showExtraChoice=false
    @State private var extraFormToken: ExtraFormToken?
    @State private var extraItems:[BillExtraItem]=[]
    @State private var extraName=""
    @State private var extraAmount=""
    @State private var pendingBill:RentMonthRecord?
    @State private var previewBill=false
    @State private var previewFull=false
    @State private var dataRefreshID = UUID()
    @State private var cachedUtilityRecords: [UtilitySettlementRecord] = []

    private func rebuildUtilityCache() {
        let calendar = Calendar.current
        var seen = Set<String>()
        cachedUtilityRecords = property.utilitySettlementRecords.sorted { utilityDate($0) < utilityDate($1) }.filter { record in
            let date = utilityDate(record)
            let key = "\(calendar.component(.year, from: date))-\(calendar.component(.month, from: date))-\(calendar.component(.day, from: date))"
            return seen.insert(key).inserted
        }
    }
    private func utilityDate(_ record: UtilitySettlementRecord) -> Date {
        if let date = record.dueDate { return date }
        var components = DateComponents(); components.year = record.year; components.month = record.frequency == "monthly" ? record.period : min(record.period * 3, 12); components.day = property.rentDueDay
        return Calendar.current.date(from: components) ?? .distantFuture
    }
    private let months = ["1月","2月","3月","4月","5月","6月","7月","8月","9月","10月","11月","12月"]
    private let quarters = ["1季度","2季度","3季度","4季度"]

    private func generateShareImage() {
        // 使用UIWindow + UIHostingController确保视图正确渲染
        let targetSize = CGSize(width: 350, height: 900)
        let window = UIWindow(frame: CGRect(origin: .zero, size: targetSize))
        let hostingVC = UIHostingController(rootView: ShareDetailRenderView(property: property))
        hostingVC.view.frame = CGRect(origin: .zero, size: targetSize)
        hostingVC.view.backgroundColor = .white
        window.rootViewController = hostingVC
        window.makeKeyAndVisible()
        window.layoutIfNeeded()

        // 延迟一帧确保渲染完成
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let renderer = UIGraphicsImageRenderer(size: targetSize)
            let image = renderer.image { _ in
                hostingVC.view.drawHierarchy(in: CGRect(origin: .zero, size: targetSize), afterScreenUpdates: true)
            }
            window.isHidden = true
            shareImage = image
            showShareSheet = true
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if property.isTerminated {
                    Section("退租信息") {
                        LabeledContent("退租时间", value: property.terminationDate.map { $0.formatted(date: .numeric, time: .omitted) } ?? "未填写")
                        LabeledContent("退租原因", value: property.terminationReason.isEmpty ? "未填写" : property.terminationReason)
                        LabeledContent("押金退还", value: property.depositRefundStatus.isEmpty ? "未填写" : property.depositRefundStatus)
                        LabeledContent("房间损坏", value: property.roomDamageStatus.isEmpty ? "未填写" : property.roomDamageStatus)
                        LabeledContent("水电结算", value: property.utilitySettlementStatus.isEmpty ? "未填写" : property.utilitySettlementStatus)
                        LabeledContent("退租人", value: property.terminationPerson.isEmpty ? "未填写" : property.terminationPerson)
                        LabeledContent("联系电话", value: property.terminationPhone.isEmpty ? "未填写" : property.terminationPhone)
                    }
                }
                Section("房源信息") {
                    LabeledContent("房号", value: property.roomNumber)
                    LabeledContent("房东", value: property.landlord)
                    LabeledContent("户型", value: property.unitType)
                    LabeledContent("房源类型", value: property.propertyType)
                    LabeledContent("租金", value: "¥\(Int(property.rent))/月")
                    LabeledContent("押金", value: "¥\(Int(property.deposit))")
                    LabeledContent("预存", value: "¥\(Int(property.prepayment))")
                    LabeledContent("起止期", value: property.leaseStart.isEmpty ? "未出租" : "\(property.leaseStart) 至 \(property.leaseEnd)")
                    if !property.leaseDuration.isEmpty { LabeledContent("租期", value: property.leaseDuration) }
                    LabeledContent("交租日", value: "每月\(property.rentDueDay)号")
                    if !property.notes.isEmpty { LabeledContent("备注", value: property.notes) }
                }

                Section {
                    let sortedRecords = property.monthlyRentRecords.sorted {
                        if $0.year != $1.year { return $0.year < $1.year }
                        return $0.month < $1.month
                    }
                    ForEach(sortedRecords, id: \.id) { record in MonthRentRow(property: property, year: record.year, month: record.month, label: "\(record.year)年\(record.month)月\(property.rentDueDay)日") }
                } header:{HStack{Text("月度收租（打勾后金额锁定）");Spacer();Button{showRentPlanEditor=true}label:{Image(systemName:"pencil")}}}
                .id(dataRefreshID)

                Section {
                    if property.utilitySettlementRecords.isEmpty { Text("暂无结算计划，请编辑房源后保存生成").foregroundColor(.themeText3) }
                    ForEach(cachedUtilityRecords) { r in UtilityPlanRow(property:property, record:r, dueDay:property.rentDueDay, onDataChanged: { dataRefreshID = UUID() }) }
                } header:{HStack{Text("水电结算（金额可输入，取消结算需确认）");Spacer();Button{showUtilityPlanEditor=true}label:{Image(systemName:"pencil")}}}
                Section("水电底数") {
                    LabeledContent("水表底数", value: "\(property.waterMeterBase)")
                    LabeledContent("电表底数", value: "\(property.electricMeterBase)")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.themeBg)
            .labeledContentStyle(DetailLabeledContentStyle())
            .onAppear { rebuildUtilityCache() }
            .onChange(of: property.utilitySettlementRecords.count) { _, _ in rebuildUtilityCache() }
            .navigationTitle(property.roomNumber)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    HStack { Menu { Button("分享完整表单"){generateShareImage()}; Button("分享收租账单"){showBillMonths=true} } label:{Image(systemName:"ellipsis.circle").foregroundColor(.themeAccent)}; Button { showUtilitySheet=true } label:{Image(systemName:"bolt.fill").foregroundColor(.themeAmber)} }
                }
                ToolbarItem(placement: .confirmationAction) { Button("编辑") { if property.isTerminated { showTerminationForm = true } else { showEditProperty = true } }.foregroundColor(.themeAccent) }
            }
                        .sheet(isPresented: $showShareSheet) { if let image = shareImage { ActivityView(activityItems: [image]) } }
            .sheet(isPresented:$showUtilitySheet){UtilityView(presetProperty:property, onWriteSuccess:{ dataRefreshID = UUID() })}
            .confirmationDialog("选择账单月份",isPresented:$showBillMonths,titleVisibility:.visible){ForEach(property.monthlyRentRecords.sorted{$0.year==$1.year ? $0.month<$1.month:$0.year<$1.year},id:\.id){r in Button("\(r.year)年\(r.month)月"){pendingBill=r;extraItems=[];extraName="";extraAmount="";showExtraChoice=true}};Button("取消",role:.cancel){}}
            .confirmationDialog("是否添加附加费用",isPresented:$showExtraChoice,titleVisibility:.visible){Button("有"){extraFormToken=ExtraFormToken()};Button("无"){if let r=pendingBill{makeBill(r)}};Button("取消",role:.cancel){}}
            .sheet(item:$extraFormToken){_ in BillExtraForm(items:$extraItems,name:$extraName,amount:$extraAmount){extraFormToken=nil;DispatchQueue.main.asyncAfter(deadline:.now()+0.2){if let r=pendingBill{makeBill(r)}}}}
                        .sheet(isPresented:$showBillShare){if let billImage{ActivityView(activityItems:[billImage])}}
            .sheet(isPresented:$showEditProperty){AddPropertyView(property:property)}
            .sheet(isPresented:$showRentPlanEditor){RentPlanEditorView(property:property)}
            .sheet(isPresented:$showUtilityPlanEditor){UtilityPlanEditorView(property:property)}
            .sheet(isPresented: $showTerminationForm) {
                TerminationFormView(property: property) {
                    if property.isTerminated { dismiss() }
                }
            }
            .alert("还原到在租？", isPresented: $showRestoreTenancyConfirm) {
                Button("取消", role: .cancel) { }
                Button("确认还原") {
                    property.isTerminated = false
                    property.terminationDate = nil
                    property.terminationReason = ""
                    property.depositRefundStatus = ""
                    property.roomDamageStatus = ""
                    property.utilitySettlementStatus = ""
                    property.terminationPerson = ""
                    property.terminationPhone = ""
                    try? modelContext.save()
                    dismiss()
                }
            } message: {
                Text("退租信息将清空，房源卡片和表单会恢复为在租状态。")
            }
        }
    }
    private func makeBill(_ rent:RentMonthRecord){let utility=property.utilitySettlementRecords.first{rec in guard let d=rec.dueDate else{return false};return Calendar.current.component(.year,from:d)==rent.year && Calendar.current.component(.month,from:d)==rent.month};let view=RentBillShareView(property:property,rent:rent,utility:utility,extras:extraItems);let renderer=ImageRenderer(content:view.frame(width:360).background(Color.white));renderer.scale=3;if let image=renderer.uiImage{billImage=image;extraItems=[];DispatchQueue.main.asyncAfter(deadline:.now()+0.2){showBillShare=true}}}
    private func updateRentAmount(for record: UtilitySettlementRecord) {
        guard let d = record.dueDate else { return }
        let cal = Calendar.current
        if let rent = property.monthlyRentRecords.first(where:{ $0.year==cal.component(.year,from:d) && $0.month==cal.component(.month,from:d) }) { rent.amount = property.rent + property.prepayment - record.balance }
        try? modelContext.save()
    }
}

// MARK: - 月度收租行（可编辑金额+可取消打勾）
struct MonthRentRow: View {
    let property: Property
    let year: Int
    let month: Int
    let label: String
    @Environment(\.modelContext) private var modelContext
    @State private var amountText: String
    @State private var isPaid: Bool
    @State private var showUncheckConfirm = false

    init(property: Property, year: Int, month: Int, label: String) {
        self.property = property
        self.year = year
        self.month = month
        self.label = label
        let record = property.monthlyRentRecords.first { $0.year == year && $0.month == month }
        let amt = record?.amount ?? (property.rent + property.prepayment)
        _amountText = State(initialValue: amt > 0 ? String(Int(amt)) : "")
        _isPaid = State(initialValue: record?.isPaid ?? false)
    }

    var body: some View {
        HStack {
            Text(label).foregroundColor(.themeText).frame(width: 135, alignment: .leading).lineLimit(1).minimumScaleFactor(0.6)
            Spacer()
            TextField("金额", text: $amountText)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .foregroundColor(.themeText)
                .frame(width: 90)
                .disabled(isPaid)
                .opacity(isPaid ? 0.55 : 1)
                .onChange(of: amountText) { _, newValue in
                    updateRecord()
                }
            Text("元").foregroundColor(.themeText3)
            Button {
                if isPaid {
                    showUncheckConfirm = true
                } else {
                    isPaid = true
                    updateRecord()
                }
            } label: {
                Image(systemName: isPaid ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isPaid ? .themeAccent : .themeText3)
                    .font(.system(size: 22))
            }
            .buttonStyle(.plain)
        }
        .alert("确认取消已收？", isPresented: $showUncheckConfirm) {
            Button("取消", role: .cancel) { }
            Button("确认取消") {
                isPaid = false
                updateRecord()
            }
        } message: {
            Text("该月已标记为已收，取消后将恢复为未收状态。")
        }
    }

    private func updateRecord() {
        let amount = Double(amountText) ?? 0
        if let index = property.monthlyRentRecords.firstIndex(where: { $0.year == year && $0.month == month }) {
            property.monthlyRentRecords[index].amount = amount
            property.monthlyRentRecords[index].isPaid = isPaid
            property.monthlyRentRecords[index].paidDate = isPaid ? Date() : nil
        } else {
            let record = RentMonthRecord(year: year, month: month, amount: amount, isPaid: isPaid)
            record.paidDate = isPaid ? Date() : nil
            property.monthlyRentRecords.append(record)
        }
        try? modelContext.save()
    }
}

// MARK: - 季度水电行（可输入金额+可取消打勾）
struct QuarterUtilityRow: View {
    let property: Property
    let quarter: Int
    let label: String
    @State private var electricText: String
    @State private var waterText: String
    @State private var isSettled: Bool
    @State private var showUnsettleConfirm = false

    init(property: Property, quarter: Int, label: String) {
        self.property = property
        self.quarter = quarter
        self.label = label
        let record = property.quarterlyUtilityRecords.first { $0.quarter == quarter }
        _electricText = State(initialValue: (record?.electricAmount ?? 0) > 0 ? String(Int(record?.electricAmount ?? 0)) : "")
        _waterText = State(initialValue: (record?.waterAmount ?? 0) > 0 ? String(Int(record?.waterAmount ?? 0)) : "")
        _isSettled = State(initialValue: record?.isSettled ?? false)
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(label).foregroundColor(.themeText).font(.system(size: 14, weight: .medium))
                Spacer()
                Button {
                    if isSettled {
                        showUnsettleConfirm = true
                    } else {
                        isSettled = true
                        updateRecord()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isSettled ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(isSettled ? .themeAccent : .themeText3)
                        Text(isSettled ? "已结算" : "未结算")
                            .font(.system(size: 12))
                            .foregroundColor(isSettled ? .themeAccentDark : .themeText3)
                    }
                }
                .buttonStyle(.plain)
            }
            HStack {
                Text("电费").font(.system(size: 12)).foregroundColor(.themeText2)
                TextField("输入电费", text: $electricText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .foregroundColor(.themeText)
                    .disabled(isSettled)
                    .opacity(isSettled ? 0.55 : 1)
                    .onChange(of: electricText) { _, _ in updateRecord() }
                Text("元").font(.system(size: 12)).foregroundColor(.themeText3)
            }
            HStack {
                Text("水费").font(.system(size: 12)).foregroundColor(.themeText2)
                TextField("输入水费", text: $waterText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .foregroundColor(.themeText)
                    .disabled(isSettled)
                    .opacity(isSettled ? 0.55 : 1)
                    .onChange(of: waterText) { _, _ in updateRecord() }
                Text("元").font(.system(size: 12)).foregroundColor(.themeText3)
            }
        }
        .padding(.vertical, 4)
        .alert("确认改为未结算？", isPresented: $showUnsettleConfirm) {
            Button("取消", role: .cancel) { }
            Button("确认") {
                isSettled = false
                updateRecord()
            }
        } message: {
            Text("该周期已结算，改为未结算后将恢复为未结算状态。")
        }
    }

    private func updateRecord() {
        let electric = Double(electricText) ?? 0
        let water = Double(waterText) ?? 0
        if let index = property.quarterlyUtilityRecords.firstIndex(where: { $0.quarter == quarter }) {
            property.quarterlyUtilityRecords[index].electricAmount = electric
            property.quarterlyUtilityRecords[index].waterAmount = water
            property.quarterlyUtilityRecords[index].isSettled = isSettled
        } else {
            property.quarterlyUtilityRecords.append(
                UtilityQuarterRecord(quarter: quarter, electricAmount: electric, waterAmount: water, isSettled: isSettled)
            )
        }
    }
}

// MARK: - 租期解析：根据租期字符串返回月数
func parseLeaseDurationToMonths(_ duration: String) -> Int {
    let trimmed = duration.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return 12 }
    if trimmed == "1年" || trimmed == "一年" { return 12 }
    if trimmed == "半年" { return 6 }
    if trimmed == "月租房" || trimmed == "月租" { return 12 }
    // 解析"X个月"或"X月"
    if let range = trimmed.range(of: #"\d+"#, options: .regularExpression) {
        if let num = Int(trimmed[range]) {
            return num
        }
    }
    return 12 // 默认12个月
}

// MARK: - 新增房源
struct AddPropertyView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    private let editingProperty: Property?

    @State private var roomNumber: String
    @State private var landlord: String
    @State private var unitType: String
    @State private var rentText: String
    @State private var depositText: String
    @State private var prepaymentText: String
    @State private var leaseStartDate: Date
    @State private var leaseEndDate: Date
    @State private var leaseDuration: String
    @State private var firstRentYear: Int // 首次交租年
    @State private var firstRentMonth: Int // 首次交租月
    @State private var rentDueDay: Int
    @State private var waterMeterText: String
    @State private var electricMeterText: String
    @State private var propertyType: String
    @State private var utilityFrequency: String
    @State private var notes: String

    private let unitTypes = ["单间上层","单间下层","独立厨房上层","独立厨房下层","复式","复式独立厨房","中空复式","平层","双钥匙一套","三房"]
    private let types = ["管理","包租","托管"]

    init(prefill: PropertyDraft) {
        editingProperty=nil
        _roomNumber=State(initialValue:prefill.roomNumber);_landlord=State(initialValue:prefill.landlord);_unitType=State(initialValue:prefill.unitType);_rentText=State(initialValue:String(Int(prefill.rent)));_depositText=State(initialValue:String(Int(prefill.deposit)));_prepaymentText=State(initialValue:String(Int(prefill.prepayment)));_leaseStartDate=State(initialValue:prefill.leaseStart);_leaseEndDate=State(initialValue:prefill.leaseEnd);_leaseDuration=State(initialValue:prefill.leaseDuration);_firstRentYear=State(initialValue:Calendar.current.component(.year,from:prefill.leaseStart));_firstRentMonth=State(initialValue:Calendar.current.component(.month,from:prefill.leaseStart));_rentDueDay=State(initialValue:prefill.rentDueDay);_waterMeterText=State(initialValue:"");_electricMeterText=State(initialValue:"");_propertyType=State(initialValue:"管理");_utilityFrequency=State(initialValue:"quarterly");_notes=State(initialValue:prefill.notes)
    }

    init(property: Property? = nil) {
        editingProperty = property
        let df = DateFormatter()
        df.dateFormat = "yyyy.M.d"
        _roomNumber = State(initialValue: property?.roomNumber ?? "")
        _landlord = State(initialValue: property?.landlord ?? "")
        _unitType = State(initialValue: property?.unitType ?? "")
        _rentText = State(initialValue: property.map { $0.rent > 0 ? String(Int($0.rent)) : "" } ?? "")
        _depositText = State(initialValue: property.map { $0.deposit > 0 ? String(Int($0.deposit)) : "" } ?? "")
        _prepaymentText = State(initialValue: property.map { $0.prepayment > 0 ? String(Int($0.prepayment)) : "" } ?? "")
        _leaseStartDate = State(initialValue: property.flatMap { df.date(from: $0.leaseStart) } ?? Date())
        _leaseEndDate = State(initialValue: property.flatMap { df.date(from: $0.leaseEnd) } ?? Date())
        _leaseDuration = State(initialValue: property?.leaseDuration ?? "")
        // 首次交租年月：编辑时从收租计划第一个月获取，新增时默认当前年月
        if let prop = property, let first = prop.monthlyRentRecords.sorted(by: { $0.year == $1.year ? $0.month < $1.month : $0.year < $1.year }).first {
            _firstRentYear = State(initialValue: first.year)
            _firstRentMonth = State(initialValue: first.month)
        } else {
            _firstRentYear = State(initialValue: Calendar.current.component(.year, from: Date()))
            _firstRentMonth = State(initialValue: Calendar.current.component(.month, from: Date()))
        }
        _rentDueDay = State(initialValue: property?.rentDueDay ?? 1)
        _waterMeterText = State(initialValue: property.map { $0.waterMeterBase > 0 ? String($0.waterMeterBase) : "" } ?? "")
        _electricMeterText = State(initialValue: property.map { $0.electricMeterBase > 0 ? String($0.electricMeterBase) : "" } ?? "")
        _propertyType = State(initialValue: property?.propertyType ?? "管理")
        _utilityFrequency = State(initialValue: property?.utilitySettlementFrequency ?? "quarterly")
        _notes = State(initialValue: property?.notes ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextRow(label: "房号", text: $roomNumber, allowSpaces: false)
                    TextRow(label: "房东", text: $landlord)
                    Picker("户型", selection: $unitType) { Text("请选择").tag(""); ForEach(unitTypes, id: \.self) { Text($0).tag($0) } }
                    Picker("房源类型", selection: $propertyType) { ForEach(types, id: \.self) { Text($0).tag($0) } }
                }
                Section("租赁信息") {
                    WheelDateField(label: "起租日", date: $leaseStartDate)
                    WheelDateField(label: "到期日", date: $leaseEndDate)
                    TextRow(label: "租期", text: $leaseDuration)
                    WheelYearMonthField(label: "首次交租年月", year: $firstRentYear, month: $firstRentMonth)
                    Picker("交租日", selection: $rentDueDay) {
                        ForEach(1...31, id: \.self) { day in Text("每月\(day)号").tag(day) }
                    }
                }
                Section("金额") {
                    AmountField(label: "月租金", text: $rentText)
                    AmountField(label: "押金", text: $depositText)
                    AmountField(label: "预存", text: $prepaymentText)
                }
                Section("水电结算周期") { Picker("周期", selection:$utilityFrequency){Text("按月").tag("monthly");Text("按季").tag("quarterly")}.pickerStyle(.segmented) }
                Section("水电底数（整数）") {
                    HStack { Text("水表底数"); Spacer(); TextField("请输入", text:$waterMeterText).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width:120) }
                    HStack { Text("电表底数"); Spacer(); TextField("请输入", text:$electricMeterText).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width:120) }
                }
                Section("备注") { TextField("备注", text: $notes, axis: .vertical) }
            }
            .scrollContentBackground(.hidden)
            .background(Color.themeBg)
            .navigationTitle(editingProperty == nil ? "新增收租" : "编辑收租")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let df = DateFormatter()
                        df.dateFormat = "yyyy.M.d"
                        let calendar = Calendar.current
                        let firstYear = firstRentYear
                        let firstMonth = firstRentMonth
                        let normalizedStart = calendar.date(from: calendar.dateComponents([.year, .month], from: leaseStartDate)) ?? leaseStartDate
                        let normalizedEnd = calendar.date(from: calendar.dateComponents([.year, .month], from: leaseEndDate)) ?? leaseEndDate
                        // 到期日按租期终点处理：同月为 1 个月，整年起止为 12 个月，避免多生成第 13 条。
                        let monthDifference = calendar.dateComponents([.month], from: normalizedStart, to: normalizedEnd).month ?? 0
                        let leaseRangeMonths = max(1, monthDifference)
                        let months = max(leaseRangeMonths, parseLeaseDurationToMonths(leaseDuration))
                        let defaultAmount = (Double(rentText) ?? 0) + (Double(prepaymentText) ?? 0)

                        // 生成收租计划
                        func generateRentRecords() -> [RentMonthRecord] {
                            var records: [RentMonthRecord] = []
                            for i in 0..<months {
                                var year = firstYear
                                var month = firstMonth + i
                                while month > 12 {
                                    month -= 12
                                    year += 1
                                }
                                let record = RentMonthRecord(year: year, month: month, amount: defaultAmount, isPaid: false)
                                records.append(record)
                            }
                            return records
                        }

                        if let prop = editingProperty {
                            let scheduleChanged = prop.leaseStart != df.string(from: leaseStartDate) || prop.leaseEnd != df.string(from: leaseEndDate) || prop.rentDueDay != rentDueDay || prop.utilitySettlementFrequency != utilityFrequency
                            prop.roomNumber = roomNumber
                            prop.landlord = landlord
                            prop.unitType = unitType
                            prop.rent = Double(rentText) ?? 0
                            prop.deposit = Double(depositText) ?? 0
                            prop.prepayment = Double(prepaymentText) ?? 0
                            prop.leaseStart = df.string(from: leaseStartDate)
                            prop.leaseEnd = df.string(from: leaseEndDate)
                            prop.leaseDuration = leaseDuration
                            prop.rentDueDay = rentDueDay
                            prop.waterMeterBase = Int(waterMeterText) ?? 0
                            prop.electricMeterBase = Int(electricMeterText) ?? 0
                            prop.propertyType = propertyType
                            let frequencyChanged = scheduleChanged
                            prop.utilitySettlementFrequency = utilityFrequency
                            prop.notes = notes

                            if scheduleChanged {
                                let oldPaidRecords = prop.monthlyRentRecords.filter { $0.isPaid }
                                let newRecords = generateRentRecords()
                                for newRec in newRecords {
                                    if let old = oldPaidRecords.first(where: { $0.year == newRec.year && $0.month == newRec.month }) { newRec.isPaid=true;newRec.amount=old.amount;newRec.paidDate=old.paidDate }
                                }
                                for oldRec in prop.monthlyRentRecords { modelContext.delete(oldRec) }
                                prop.monthlyRentRecords = newRecords
                                ensureUtilityPlan(prop: prop, months: months, firstYear:firstYear, firstMonth:firstMonth, force: true)
                            }
                            updateRentPlanAmounts(prop)
                        } else {
                            let prop = Property(roomNumber: roomNumber, landlord: landlord, unitType: unitType,
                                rent: Double(rentText) ?? 0, deposit: Double(depositText) ?? 0,
                                prepayment: Double(prepaymentText) ?? 0, leaseStart: df.string(from: leaseStartDate),
                                leaseEnd: df.string(from: leaseEndDate), leaseDuration: leaseDuration, rentDueDay: rentDueDay,
                                waterMeterBase: Int(waterMeterText) ?? 0, electricMeterBase: Int(electricMeterText) ?? 0,
                                propertyType: propertyType, notes: notes)
                            modelContext.insert(prop)
                            let rentRecords = generateRentRecords()
                            for record in rentRecords { modelContext.insert(record) }
                            prop.monthlyRentRecords = rentRecords
                            prop.utilitySettlementFrequency = utilityFrequency
                            ensureUtilityPlan(prop: prop, months: months, firstYear:firstYear, firstMonth:firstMonth, force: true)
                            updateRentPlanAmounts(prop)
                        }
                        try? modelContext.save()
                        dismiss()
                    }
                    .disabled(roomNumber.isEmpty)
                    .foregroundColor(.themeAccent)
                }
            }
        }
    }
    private func updateRentPlanAmounts(_ prop:Property){let cal=Calendar.current;for rent in prop.monthlyRentRecords{let balance=prop.utilitySettlementRecords.filter{rec in guard let d=rec.dueDate else{return false};return cal.component(.year,from:d)==rent.year && cal.component(.month,from:d)==rent.month}.sorted{($0.settledAt ?? .distantPast)>($1.settledAt ?? .distantPast)}.first?.balance ?? 0;if !rent.isPaid{rent.amount=prop.rent+prop.prepayment-balance}}}
    private func ensureUtilityPlan(prop: Property, months:Int, firstYear:Int, firstMonth:Int, force:Bool) {
        if !force && !prop.utilitySettlementRecords.isEmpty { return }
        let oldRecords = prop.utilitySettlementRecords
        if !force { return }
        prop.utilitySettlementRecords.removeAll()
        let calendar=Calendar.current;var start=DateComponents();start.year=firstYear;start.month=firstMonth;start.day=min(prop.rentDueDay,28);let startDate=calendar.date(from:start) ?? Date();let endFormatter=DateFormatter();endFormatter.dateFormat="yyyy.M.d";let endDate=endFormatter.date(from:prop.leaseEnd) ?? startDate
        let step=utilityFrequency == "monthly" ? 1:3;var date=calendar.date(byAdding:.month,value:step,to:startDate) ?? endDate;var keys=Set<String>()
        while date < endDate { let y=calendar.component(.year,from:date),m=calendar.component(.month,from:date),period=utilityFrequency=="monthly" ? m:((m-1)/3+1),key={let f=DateFormatter();f.dateFormat="yyyyMMdd";return f.string(from:date)}();if keys.insert(key).inserted{let old=oldRecords.first{ $0.dueDate.map{Calendar.current.isDate($0,inSameDayAs:date)} ?? false };let r=UtilitySettlementRecord(year:y,period:period,frequency:utilityFrequency,electricAmount:old?.electricAmount ?? 0,waterAmount:old?.waterAmount ?? 0,balance:old?.balance ?? 0,isSettled:old?.isSettled ?? false,statement:old?.statement ?? "",settledAt:old?.settledAt,dueDate:date);modelContext.insert(r);prop.utilitySettlementRecords.append(r)};date=calendar.date(byAdding:.month,value:step,to:date) ?? endDate }
        for old in oldRecords where !prop.utilitySettlementRecords.contains(where:{$0.id==old.id}) { modelContext.delete(old) }
        let y=calendar.component(.year,from:endDate),m=calendar.component(.month,from:endDate),period=utilityFrequency=="monthly" ? m:((m-1)/3+1),key={let f=DateFormatter();f.dateFormat="yyyyMMdd";return f.string(from:endDate)}();if keys.insert(key).inserted{let old=oldRecords.first{ $0.dueDate.map{Calendar.current.isDate($0,inSameDayAs:endDate)} ?? false };let r=UtilitySettlementRecord(year:y,period:period,frequency:utilityFrequency,electricAmount:old?.electricAmount ?? 0,waterAmount:old?.waterAmount ?? 0,balance:old?.balance ?? 0,isSettled:old?.isSettled ?? false,statement:old?.statement ?? "",settledAt:old?.settledAt,dueDate:endDate);modelContext.insert(r);prop.utilitySettlementRecords.append(r)}
    }
}

// MARK: - 分享用渲染视图（剔除敏感信息，美观排版）
struct ShareDetailRenderView: View {
    let property: Property

    private var paidMonthsCount: Int {
        property.monthlyRentRecords.filter { $0.isPaid }.count
    }

    private var totalUtility: Double {
        property.utilitySettlementRecords.reduce(0) { $0 + $1.electricAmount + $1.waterAmount }
    }

    private var totalRentCollected: Double {
        property.monthlyRentRecords.filter { $0.isPaid }.reduce(0) { $0 + ($1.amount > 0 ? $1.amount : property.rent) }
    }

    private var pendingRent: Double {
        property.monthlyRentRecords.filter { !$0.isPaid }.reduce(0) { $0 + ($1.amount > 0 ? $1.amount : property.rent) }
    }

    private var shareTime: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        return fmt.string(from: Date())
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部栏
            HStack {
                Text("系统记录，仅供参考")
                    .font(.system(size: 11))
                    .foregroundColor(.themeText3)
                Spacer()
                Text(shareTime)
                    .font(.system(size: 11))
                    .foregroundColor(.themeText3)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(hex: "F5F5F5"))

            if property.isTerminated {
                VStack(alignment: .leading, spacing: 5) {
                    Text("退租信息").font(.system(size: 15, weight: .bold)).foregroundColor(.themeRed)
                    shareTerminationLine("退租时间", property.terminationDate.map { $0.formatted(date: .numeric, time: .omitted) } ?? "未填写")
                    shareTerminationLine("退租原因", property.terminationReason)
                    shareTerminationLine("押金退还", property.depositRefundStatus)
                    shareTerminationLine("房间损坏", property.roomDamageStatus)
                    shareTerminationLine("水电结算", property.utilitySettlementStatus)
                    shareTerminationLine("退租人", property.terminationPerson)
                    shareTerminationLine("联系电话", property.terminationPhone)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(hex: "FDF0F0"))
                .cornerRadius(10)
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }

            // 房号标题
            HStack {
                Text(property.roomNumber)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.themeText)
                Spacer()
                Text(property.propertyType)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.themeAccent)
                    .cornerRadius(8)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            // 房源信息卡片
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    capsuleTag(text: property.unitType.isEmpty ? "未填写" : property.unitType, color: Color(hex: "E3F2FD"), textColor: .themeText)
                    capsuleTag(text: "¥\(Int(property.rent))/月", color: Color(hex: "FFF3E0"), textColor: .themeText)
                    capsuleTag(text: "押金¥\(Int(property.deposit))", color: Color(hex: "FFF3E0"), textColor: .themeText)
                }
                HStack(spacing: 8) {
                    capsuleTag(text: property.leaseStart.isEmpty ? "未出租" : "\(property.leaseStart)至\(property.leaseEnd)", color: Color(hex: "F0F0F0"), textColor: .themeText)
                    capsuleTag(text: "每月\(property.rentDueDay)号", color: Color(hex: "FDF0F0"), textColor: .themeText)
                    if property.prepayment > 0 {
                        capsuleTag(text: "预存¥\(Int(property.prepayment))", color: Color(hex: "E8F5E9"), textColor: .themeText)
                    }
                }
                HStack(spacing: 8) {
                    capsuleTag(text: "房东：\(property.landlord)", color: Color(hex: "EDE7F6"), textColor: .themeText)
                    if !property.leaseDuration.isEmpty {
                        capsuleTag(text: "租期：\(property.leaseDuration)", color: Color(hex: "EDE7F6"), textColor: .themeText)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)

            // 统计卡片 - 4个数据
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    statCard(value: "\(paidMonthsCount)", unit: "个月", label: "已收租金", color: Color(hex: "F0F7F4"), valueColor: .themeAccentDark)
                    statCard(value: "¥\(Int(totalRentCollected))", unit: "", label: "已收金额", color: Color(hex: "F0F7F4"), valueColor: .themeAccentDark)
                }
                HStack(spacing: 10) {
                    statCard(value: "¥\(Int(pendingRent))", unit: "", label: "待收租金", color: Color(hex: "FFF3E0"), valueColor: .themeAmber)
                    statCard(value: "¥\(Int(totalUtility))", unit: "", label: "累计水电", color: Color(hex: "FFF8E1"), valueColor: .themeAmber)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)

            // 月度收租记录
            VStack(alignment: .leading, spacing: 10) {
                let sortedRecords = property.monthlyRentRecords.sorted {
                    if $0.year != $1.year { return $0.year < $1.year }
                    return $0.month < $1.month
                }
                HStack {
                    Text("月度收租记录")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.themeText)
                    Spacer()
                Text("已收\(paidMonthsCount)/\(sortedRecords.count)")
                    .font(.system(size: 12))
                    .foregroundColor(.themeText3)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(sortedRecords, id: \.id) { record in
                    let isPaid = record.isPaid
                    VStack(spacing: 2) {
                        Text("\(record.year % 100).\(record.month)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(isPaid ? .themeAccentDark : .themeText3)
                        Image(systemName: isPaid ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(isPaid ? .themeAccent : .themeText3)
                            .font(.system(size: 13))
                        if isPaid, record.amount > 0 {
                            Text(verbatim: "¥\(Int(record.amount))")
                                .font(.system(size: 9))
                                .foregroundColor(.themeAccentDark)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(isPaid ? Color(hex: "F0F7F4") : Color(hex: "F8F8F8"))
                    .cornerRadius(8)
                }
            }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)

            // 底部备注
            if !property.notes.isEmpty {
                HStack {
                    Text("备注：\(property.notes)")
                        .font(.system(size: 11))
                        .foregroundColor(.themeText3)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
        .background(Color.themePanel)
        .frame(width: 350)
    }

    private func shareTerminationLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\(label)：").foregroundColor(.themeText2)
            Text(value.isEmpty ? "未填写" : value).foregroundColor(.themeText)
        }
        .font(.system(size: 11))
    }

    private func statCard(value: String, unit: String, label: String, color: Color, valueColor: Color) -> some View {
        VStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: 2) {
                Text(value)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(valueColor)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 11))
                        .foregroundColor(valueColor)
                        .padding(.bottom, 2)
                }
            }
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.themeText3)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(color)
        .cornerRadius(12)
    }

    private func capsuleTag(text: String, color: Color, textColor: Color) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(textColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color)
            .cornerRadius(.infinity)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - UIActivityViewController包装
struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}


struct UtilityPlanRow: View {
    let property: Property
    let record: UtilitySettlementRecord
    let dueDay: Int
    var onDataChanged: () -> Void = {}
    @Environment(\.modelContext) private var modelContext
    @State private var electricText: String
    @State private var waterText: String
    @State private var balanceText: String
    @State private var statementText: String
    @State private var showUnsettleConfirm = false
    @State private var debounceWork: DispatchWorkItem?
    private static let titleFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy年M月d日"; return f }()

    init(property: Property, record: UtilitySettlementRecord, dueDay: Int, onDataChanged: @escaping () -> Void = {}) {
        self.property = property
        self.record = record
        self.dueDay = dueDay
        self.onDataChanged = onDataChanged
        _electricText = State(initialValue: record.electricAmount == 0 ? "" : String(Int(record.electricAmount)))
        _waterText = State(initialValue: record.waterAmount == 0 ? "" : String(Int(record.waterAmount)))
        _balanceText = State(initialValue: record.balance == 0 ? "" : String(Int(record.balance)))
        _statementText = State(initialValue: record.statement)
    }

    private var title: String {
        if let date = record.dueDate {
            return Self.titleFormatter.string(from: date)
        }
        let month = record.frequency == "monthly" ? record.period : min(record.period * 3, 12)
        return "\(record.year)年\(month)月\(dueDay)日"
    }

    private var hasData: Bool {
        !electricText.isEmpty || !waterText.isEmpty || !balanceText.isEmpty || !statementText.isEmpty
    }

    private var statementHeight: CGFloat {
        let lineCount = max(1, statementText.components(separatedBy: "\n").count)
        return max(70, CGFloat(lineCount) * 24)
    }

    var body: some View {
        VStack(spacing: 10) {
            Grid(horizontalSpacing: 12, verticalSpacing: 9) {
                GridRow {
                    Text(title).frame(maxWidth: .infinity, alignment: .leading)
                    HStack {
                        Spacer()
                        Button(action: toggle) {
                            HStack(spacing: 4) {
                                Image(systemName: record.isSettled ? "checkmark.circle.fill" : "circle")
                                Text(record.isSettled ? "已结算" : "未结算")
                            }
                            .foregroundColor(record.isSettled ? .themeAccentDark : .themeText3)
                        }
                    }
                }
                if record.isSettled || hasData {
                    GridRow { Text("电费").frame(maxWidth: .infinity, alignment: .leading); textAmount($electricText, "输入电费") }
                    GridRow { Text("水费").frame(maxWidth: .infinity, alignment: .leading); textAmount($waterText, "输入水费") }
                    GridRow { Text("结余").frame(maxWidth: .infinity, alignment: .leading); textAmount($balanceText, "输入结余") }
                }
            }
            .font(.system(size: 13))

            if (record.isSettled || hasData) && !statementText.isEmpty {
                TextEditor(text: $statementText)
                    .font(.system(size: 13))
                    .frame(minHeight: statementHeight)
                    .padding(7)
                    .background(Color.themeBg)
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.themeBorder))
                    .onChange(of: statementText) { _, _ in scheduleSync() }
                    .onLongPressGesture { UIPasteboard.general.string = statementText }
            }
        }
        .padding(.vertical, 5)
        .onChange(of: electricText) { _, _ in scheduleSync() }
        .onChange(of: waterText) { _, _ in scheduleSync() }
        .onChange(of: balanceText) { _, _ in scheduleSync() }
        .alert("确认改为未结算", isPresented: $showUnsettleConfirm) {
            Button("取消", role: .cancel) { }
            Button("确认", role: .destructive) { confirmUnsettle() }
        } message: {
            Text("该周期已结算，改为未结算将清空已录入的电费、水费、结余和结算单。确定要取消结算吗？")
        }
    }

    private func textAmount(_ value: Binding<String>, _ placeholder: String) -> some View {
        HStack {
            TextField(placeholder, text: value).keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing)
            if !value.wrappedValue.isEmpty { Text("元").foregroundColor(.themeText3) }
        }
    }

    private func toggle() {
        // 已结算改未结算时弹确认框，防止误触
        if record.isSettled {
            showUnsettleConfirm = true
            return
        }
        record.isSettled.toggle()
        save()
    }

    private func confirmUnsettle() {
        record.isSettled = false
        electricText = ""; waterText = ""; balanceText = ""; statementText = ""
        record.electricAmount = 0; record.waterAmount = 0; record.balance = 0; record.statement = ""; record.settledAt = nil
        save()
    }

    private func scheduleSync() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { combineSync() }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func combineSync() {
        record.electricAmount = Double(electricText) ?? 0
        record.waterAmount = Double(waterText) ?? 0
        record.balance = Double(balanceText) ?? 0
        record.statement = statementText
        save()
    }

    private func save() {
        if let d = record.dueDate {
            let cal = Calendar.current
            if let rent = property.monthlyRentRecords.first(where: { $0.year == cal.component(.year, from: d) && $0.month == cal.component(.month, from: d) }) {
                rent.amount = property.rent + property.prepayment - record.balance
            }
        }
        try? modelContext.save()
        onDataChanged()
    }
}

struct RentBillShareView: View {
    let property: Property
    let rent: RentMonthRecord
    let utility: UtilitySettlementRecord?
    let extras: [BillExtraItem]

    // 账单模板设置（设置页可修改，实时生效）
    @AppStorage("billFixedTip") private var billFixedTip = "账单由人工录入，系统生成，如金额有误请与我联系！"
    @AppStorage("billGreeting") private var billGreeting = "尊敬的租客，感谢您选择我司提供的租赁服务！"
    @AppStorage("billDuePrefix") private var billDuePrefix = "您"
    @AppStorage("billDueSuffix") private var billDueSuffix = "前需支付房租账单明细如下："
    @AppStorage("billLateFeeTip") private var billLateFeeTip = "（请务必按时交租，逾期交租将按照租房合同约定计算滞纳金：月租金5%/天×天数）"
    @AppStorage("billSign") private var billSign = "谢谢  祝 商祺"
    @AppStorage("billQRAlipayFile") private var billQRAlipayFile = ""
    @AppStorage("billQRWechatFile") private var billQRWechatFile = ""

    private var issueDateText:String { let f=DateFormatter();f.dateFormat="yyyy年M月d日H时m分";return "出账日期："+f.string(from:Date()) }
    private var dueText: String { "\(rent.year)年\(rent.month)月\(property.rentDueDay)号" }
    private var total: Double {
        property.rent + property.prepayment - (utility?.balance ?? 0) + extras.reduce(0) { $0 + $1.amount }
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: "F0F7F4"), Color(hex: "E8F2EF")], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 12) {
                VStack(spacing:3){Text(issueDateText).font(.system(size:15,weight:.bold)).foregroundColor(.black).lineLimit(1);Text(billFixedTip).font(.system(size:10,weight:.bold)).lineLimit(1).minimumScaleFactor(0.7)}.padding(.top,18)
                if let utility, !utility.statement.isEmpty {
                    bubble { Text(utility.statement).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true) }
                } else if let utility, utility.electricAmount != 0 || utility.waterAmount != 0 {
                    bubble {
                        VStack(alignment: .leading, spacing: 4) {
                            if utility.electricAmount != 0 { amountLine("电费", utility.electricAmount) }
                            if utility.waterAmount != 0 { amountLine("水费", utility.waterAmount) }
                        }
                    }
                }
                bubble {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(billGreeting).font(.system(size:13)).lineLimit(nil).fixedSize(horizontal:false,vertical:true)
                        Text("\(billDuePrefix)\(dueText)\(billDueSuffix)").font(.system(size:13,weight:.semibold)).lineLimit(nil).fixedSize(horizontal:false,vertical:true).padding(.vertical, 4)
                        amountLine("租金物业费", property.rent)
                        if property.prepayment != 0 { amountLine("水电预存", property.prepayment) }
                        if let utility, utility.balance != 0 { amountLine("预存结余", utility.balance) }
                        else if let utility, (utility.electricAmount != 0 || utility.waterAmount != 0) { amountLine("预存结余", 0) }
                        ForEach(extras) { amountLine($0.name, $0.amount) }
                        if property.prepayment != 0 || (utility?.balance ?? 0) != 0 || !extras.isEmpty {
                            Text(verbatim: "合计：\(Int(total))元").font(.system(size: 17, weight: .bold)).foregroundColor(Color(hex: "DC2626")).padding(.top, 5)
                        }
                        Text(billLateFeeTip)
                            .font(.system(size:13)).foregroundColor(.gray).lineLimit(nil).fixedSize(horizontal:false,vertical:true).padding(.top,5)
                        Text(billSign).padding(.top, 3)
                    }
                }
                HStack(spacing:8){billQRImage(billQRAlipayFile,"AlipayQR");billQRImage(billQRWechatFile,"WechatQR")}.frame(maxWidth:.infinity).cornerRadius(14).shadow(color:.black.opacity(0.1),radius:6)
            }
            .padding(14)
        }
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func bubble<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content().font(.system(size:13)).frame(maxWidth: .infinity, alignment: .leading).padding(14).background(Color.white).cornerRadius(16)
            .shadow(color: Color(hex: "099B6C").opacity(0.06), radius: 6)
    }

    private func amountLine(_ title: String, _ value: Double) -> some View {
        HStack { Text(title + "："); Text(verbatim: "\(Int(value))元").foregroundColor(Color(hex: "DC2626")).fontWeight(.semibold) }
    }

    // 收款码：优先读取用户在设置中更换的图片，未设置时回退到内置默认收款码
    private func billQRImage(_ file: String, _ fallback: String) -> some View {
        if let img = loadBillQR(file) { return AnyView(Image(uiImage: img).resizable().scaledToFit()) }
        return AnyView(Image(fallback).resizable().scaledToFit())
    }

    private func loadBillQR(_ file: String) -> UIImage? {
        guard !file.isEmpty else { return nil }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(file)
        return UIImage(contentsOfFile: url.path)
    }
}

struct ExtraFormToken: Identifiable { let id=UUID() }
struct BillExtraItem: Identifiable { let id=UUID(); var name:String; var amount:Double }
struct BillExtraForm: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var items:[BillExtraItem];@Binding var name:String;@Binding var amount:String;let done:()->Void
    var body:some View{NavigationStack{Form{Section("附加费用"){TextField("费用名目",text:$name);TextField("金额",text:$amount).keyboardType(.decimalPad);Button("添加一行"){if !name.isEmpty,let v=Double(amount){items.append(BillExtraItem(name:name,amount:v));name="";amount=""}}};if !items.isEmpty{Section("已添加"){ForEach(items){Text(verbatim: "\($0.name)：\(Int($0.amount))元")}.onDelete{items.remove(atOffsets:$0)}}}}.navigationTitle("附加费用").toolbar{ToolbarItem(placement:.cancellationAction){Button("取消"){dismiss()}};ToolbarItem(placement:.confirmationAction){Button("生成账单"){if !name.isEmpty,let v=Double(amount){items.append(BillExtraItem(name:name,amount:v))};done()}}}}}
}
struct ShareImagePreview: View {
    @Environment(\.dismiss) private var dismiss;let image:UIImage;let share:()->Void
    var body:some View{NavigationStack{ScrollView{Image(uiImage:image).resizable().scaledToFit().padding()}.navigationTitle("图片预览").toolbar{ToolbarItem(placement:.cancellationAction){Button("关闭"){dismiss()}};ToolbarItem(placement:.confirmationAction){Button("分享"){dismiss();DispatchQueue.main.asyncAfter(deadline:.now()+0.25){share()}}}}}}
}
