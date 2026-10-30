import SwiftUI
import SwiftData
import UIKit

/// v1.99：单月收租金额统计（工作台快捷操作「收租统计」入口）
/// 选房列表展示 房号/房东/交租日/当月水电结算标记；多选后按模板生成文案，一键复制
struct RentStatView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Property> { !$0.isDeleted && !$0.isTerminated }, sort: \Property.roomNumber) private var properties: [Property]

    @State private var selectedYear: Int
    @State private var selectedMonth: Int
    @State private var selectedIDs: Set<UUID> = []
    @State private var toast: String?
    @State private var filterLandlord: String?      // nil=全部房东
    @State private var filterPaid: Int = 0          // 0=全部 1=已收 2=未收
    @State private var previewText = ""             // 文案预览缓存（只在选中/筛选/年月变化时重算，避免每次 body 重建 TextEditor）

    init() {
        let now = Date()
        let y = Calendar.current.component(.year, from: now)
        let m = Calendar.current.component(.month, from: now)
        _selectedYear = State(initialValue: y)
        _selectedMonth = State(initialValue: m)
    }

    private var years: [Int] {
        let y = Calendar.current.component(.year, from: Date())
        return [y - 1, y]
    }

    /// 行级元数据（按房 ID 一次性构建，供排序/筛选/行/文案共用，避免每行重复查记录集合）
    private struct RowMeta {
        var paid: Bool?      // 所选月份收租状态
        var amount: Double   // 所选月份实际金额（收租计划优先）
        var utility: String? // 当月结算标注
    }

    private var rowMeta: [UUID: RowMeta] {
        var d: [UUID: RowMeta] = [:]
        d.reserveCapacity(properties.count)
        for p in properties {
            let rec = p.monthlyRentRecords.first { $0.year == selectedYear && $0.month == selectedMonth }
            d[p.id] = RowMeta(paid: rec?.isPaid,
                              amount: rec?.amount ?? (p.rent + p.prepayment),
                              utility: utilityText(p))
        }
        return d
    }

    private var sortedProperties: [Property] {
        let meta = rowMeta
        // 已收租的排在上面，未收的排下面，各自按房号排序
        return properties.sorted {
            let a = meta[$0.id]?.paid == true
            let b = meta[$1.id]?.paid == true
            if a != b { return a }
            return $0.roomNumber < $1.roomNumber
        }
    }

    /// 可选房东列表（按房号排序去重）
    private var landlordNames: [String] {
        var names = Set<String>()
        for p in sortedProperties where !p.landlord.isEmpty { names.insert(p.landlord) }
        return names.sorted()
    }

    /// 应用筛选后的列表：房东 + 已收/未收；保持"已收排上、未收排下"的相对顺序（rowMeta 只构建一次）
    private var filteredProperties: [Property] {
        let meta = rowMeta
        let filtered = properties.filter { p in
            let okLandlord = filterLandlord == nil || p.landlord == filterLandlord
            let paid = meta[p.id]?.paid == true
            let okPaid: Bool
            switch filterPaid {
            case 1: okPaid = paid
            case 2: okPaid = !paid
            default: okPaid = true
            }
            return okLandlord && okPaid
        }
        return filtered.sorted {
            let a = meta[$0.id]?.paid == true
            let b = meta[$1.id]?.paid == true
            if a != b { return a }
            return $0.roomNumber < $1.roomNumber
        }
    }

    private var selectedProperties: [Property] {
        filteredProperties.filter { selectedIDs.contains($0.id) }
    }

    private var allSelected: Bool {
        !filteredProperties.isEmpty && selectedIDs.count == filteredProperties.count
    }

    // MARK: - 判定与文案

    /// 当月账单结算标注：与收租板块生成账单口径一致（dueDate 落在所选年/月的结算记录），
    /// 按结算内容细分：只算水费→含水费结算；只算电费→含电费结算；都有→含水电结算；无结算记录→nil
    private func utilityText(_ p: Property) -> String? {
        let cal = Calendar.current
        guard let rec = p.utilitySettlementRecords.first(where: { rec in
            guard let d = rec.dueDate else { return false }
            return cal.component(.year, from: d) == selectedYear && cal.component(.month, from: d) == selectedMonth
        }) else { return nil }
        let e = rec.electricAmount > 0
        let w = rec.waterAmount > 0
        if e && w { return "含水电结算" }
        if e { return "含电费结算" }
        if w { return "含水费结算" }
        return nil
    }

    /// 房号上下层后缀判定：
    /// ① 房号本身带「上/下」后缀（如 1-2246下）→ 直接按完整房号展示，不再追加「房」；
    /// ② 否则看户型（含「上层/下层/上/下」）→ 附加后缀；都没有 → 房号后加「房」。
    private func layerSuffix(_ p: Property) -> String {
        let r = p.roomNumber
        if r.hasSuffix("上") || r.hasSuffix("下") { return "" }
        let t = p.unitType
        if t.contains("上层") { return "上" }
        if t.contains("下层") { return "下" }
        if t.contains("上") { return "上" }
        if t.contains("下") { return "下" }
        return ""
    }

    /// 文案中的房间显示名（模板：xx房 / xx上 / xx下）
    private func displayName(_ p: Property) -> String {
        let r = p.roomNumber
        if r.hasSuffix("上") || r.hasSuffix("下") { return r }
        let s = layerSuffix(p)
        return s.isEmpty ? "\(r)房" : "\(r)\(s)"
    }

    private func fmt(_ v: Double) -> String {
        if v == v.rounded() { return String(Int(v)) }
        return String(format: "%.2f", v)
    }

    /// 生成统计文案（模板：X月份租金合计 / 每户一行「房号 X月份租金[+预存]金额」/ 合计），按传入 meta 一次构建
    private func statText(meta: [UUID: RowMeta] = [:]) -> String {
        let chosen = selectedProperties
        guard !chosen.isEmpty else { return "请先勾选要统计的房间" }
        var lines: [String] = ["\(selectedMonth)月份租金合计"]
        var parts: [String] = []
        var total: Double = 0
        for p in chosen {
            let name = displayName(p)
            let pre = p.prepayment
            let amount = meta[p.id]?.amount ?? (p.rent + p.prepayment)
            total += amount
            parts.append(fmt(amount))
            let ut = meta[p.id]?.utility
            if pre <= 0 {
                if let ut {
                    lines.append("\(name) \(selectedMonth)月份租金\(fmt(amount))元（\(ut)）。")
                } else {
                    lines.append("\(name) \(selectedMonth)月份租金\(fmt(amount))元。")
                }
            } else if let ut {
                lines.append("\(name) \(selectedMonth)月份租金+预存\(fmt(amount))元（\(ut)）。")
            } else {
                lines.append("\(name) \(selectedMonth)月份租金+预存\(fmt(amount))元。")
            }
        }
        lines.append("合计：\(parts.joined(separator: "+"))=\(fmt(total))元")
        return lines.joined(separator: "\n")
    }

    /// 重建文案预览缓存（选中/筛选/年月变化时调用）
    private func refreshPreview() {
        previewText = statText(meta: rowMeta)
    }

    private var totalAmount: Double {
        let meta = rowMeta
        return selectedProperties.reduce(0) { $0 + (meta[$1.id]?.amount ?? ($1.rent + $1.prepayment)) }
    }

    // MARK: - UI

    var body: some View {
        let meta = rowMeta   // 一次构建行元数据，供列表/合计/筛选共用
        NavigationStack {
            VStack(spacing: 0) {
                // 筛选一排：年份/月份/房东/已收未收（紧凑布局防换行）
                HStack(spacing: 8) {
                    Picker("", selection: $selectedYear) {
                        ForEach(years, id: \.self) { Text("\($0)年").tag($0) }
                    }
                    .pickerStyle(.menu)
                    .font(.system(size: 15))
                    .frame(width: 86)
                    .lineLimit(1)
                    Picker("", selection: $selectedMonth) {
                        ForEach(1...12, id: \.self) { Text("\($0)月").tag($0) }
                    }
                    .pickerStyle(.menu)
                    .font(.system(size: 15))
                    .frame(width: 66)
                    .lineLimit(1)
                    Picker("", selection: $filterLandlord) {
                        Text("全部房东").tag(String?.none)
                        ForEach(landlordNames, id: \.self) { name in
                            Text(name).tag(String?.some(name))
                        }
                    }
                    .pickerStyle(.menu)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Picker("", selection: $filterPaid) {
                        Text("全部").tag(0)
                        Text("已收").tag(1)
                        Text("未收").tag(2)
                    }
                    .pickerStyle(.menu)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .frame(width: 78)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .onChange(of: selectedYear) { _, _ in refreshPreview() }
                .onChange(of: selectedMonth) { _, _ in refreshPreview() }
                .onChange(of: filterLandlord) { _, _ in refreshPreview() }
                .onChange(of: filterPaid) { _, _ in refreshPreview() }
                Divider()

                // 选房列表：房号 + 房东 + 交租日 + 当月水电结算标记
                List {
                    ForEach(filteredProperties) { p in
                        row(p, meta: meta)
                            .contentShape(Rectangle())
                            .onTapGesture { toggle(p.id) }
                    }
                }
                .listStyle(.plain)

                Divider()
                // 底部：已选合计 + 全选 + 文案预览 + 一键复制
                VStack(spacing: 8) {
                    HStack {
                        Text("已选 \(selectedProperties.count) 户 · 合计 ¥\(fmt(totalAmount))")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.themeText2)
                        Spacer()
                        Button(allSelected ? "取消全选" : "全选") {
                            selectedIDs = allSelected ? [] : Set(filteredProperties.map { $0.id })
                            refreshPreview()
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.themeAccent)
                    }
                    .padding(.horizontal, 16)
                    TextEditor(text: .constant(previewText))
                        .font(.system(size: 13))
                        .foregroundColor(.themeText)
                        .frame(height: 128)
                        .padding(6)
                        .background(Color.themePanel)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, 16)
                        .disabled(true)
                    Button {
                        let text = previewText
                        guard !text.hasPrefix("请先勾选") else { return }
                        UIPasteboard.general.string = text
                        toast = "文案已复制"
                    } label: {
                        Text("一键复制文案")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(selectedProperties.isEmpty ? Color.themeAccent.opacity(0.35) : Color.themeAccent)
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .disabled(selectedProperties.isEmpty)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                }
                .padding(.top, 8)
            }
            .background(Color.themeBg)
            .navigationTitle("单月收租统计")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { refreshPreview() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.themeText2)
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if let toast {
                    Text(toast)
                        .font(.system(size: 13))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Color.black.opacity(0.75))
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                        .padding(.bottom, 8)
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                withAnimation { self.toast = nil }
                            }
                        }
                }
            }
        }
    }

    private func toggle(_ id: UUID) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) }
        else { selectedIDs.insert(id) }
        refreshPreview()
    }

    private func row(_ p: Property, meta: [UUID: RowMeta]) -> some View {
        let selected = selectedIDs.contains(p.id)
        let ut = meta[p.id]?.utility
        let paid = meta[p.id]?.paid == true
        return HStack(spacing: 10) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20))
                .foregroundColor(selected ? .themeAccent : Color(.systemGray3))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(p.roomNumber)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.themeText)
                    if paid {
                        Text("已收")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.green.opacity(0.15))
                            .foregroundColor(.green)
                            .cornerRadius(4)
                    } else {
                        Text("未收")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.orange.opacity(0.15))
                            .foregroundColor(.orange)
                            .cornerRadius(4)
                    }
                    if let ut {
                        Text(ut)
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.red.opacity(0.12))
                            .foregroundColor(.red)
                            .cornerRadius(4)
                    }
                    if p.prepayment > 0 {
                        Text("预存\(fmt(p.prepayment))")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.themeBlue.opacity(0.12))
                            .foregroundColor(.themeBlue)
                            .cornerRadius(4)
                    }
                }
                Text("房东：\(p.landlord) · 每月\(p.rentDueDay)号交租")
                    .font(.system(size: 12))
                    .foregroundColor(.themeText2)
            }
            Spacer()
            Text("¥\(fmt(meta[p.id]?.amount ?? (p.rent + p.prepayment)))")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.themeText)
        }
        .padding(.vertical, 4)
    }
}
