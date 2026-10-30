import SwiftUI
import SwiftData
import UIKit

/// v1.99：单月收租金额统计（工作台快捷操作「收租统计」入口）
/// 选房列表展示 房号/房东/交租日/当月水电结算标记；多选后按模板生成文案，一键复制
struct RentStatView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Property> { !$0.isDeleted }, sort: \Property.roomNumber) private var properties: [Property]

    @State private var selectedYear: Int
    @State private var selectedMonth: Int
    @State private var selectedIDs: Set<UUID> = []
    @State private var toast: String?

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

    private var sortedProperties: [Property] {
        properties.sorted { $0.roomNumber < $1.roomNumber }
    }

    private var selectedProperties: [Property] {
        sortedProperties.filter { selectedIDs.contains($0.id) }
    }

    private var allSelected: Bool {
        !sortedProperties.isEmpty && selectedIDs.count == sortedProperties.count
    }

    // MARK: - 判定与文案

    /// 当月是否有水电结算（月度结算按月份匹配；季度结算按所属季度匹配）
    private func hasUtility(_ p: Property) -> Bool {
        p.utilitySettlementRecords.contains { r in
            guard r.year == selectedYear else { return false }
            if r.frequency == "monthly" { return r.period == selectedMonth }
            return r.period == Int(ceil(Double(selectedMonth) / 3.0))
        }
    }

    /// 房号上下层后缀（户型含「上层」→上、「下层」→下，否则无）
    private func layerSuffix(_ p: Property) -> String {
        let t = p.unitType
        if t.contains("上层") { return "上" }
        if t.contains("下层") { return "下" }
        if t.contains("上") { return "上" }
        if t.contains("下") { return "下" }
        return ""
    }

    private func fmt(_ v: Double) -> String {
        if v == v.rounded() { return String(Int(v)) }
        return String(format: "%.2f", v)
    }

    /// 生成统计文案（模板：X月份租金合计 / 每户一行 / 合计）
    private func statText() -> String {
        let chosen = selectedProperties
        guard !chosen.isEmpty else { return "请先勾选要统计的房间" }
        var lines: [String] = ["\(selectedMonth)月份租金合计"]
        var parts: [String] = []
        var total: Double = 0
        for p in chosen {
            let suffix = layerSuffix(p)
            let name = suffix.isEmpty ? "\(p.roomNumber)房" : "\(p.roomNumber)\(suffix)"
            let pre = p.prepayment
            let amount = p.rent + pre
            total += amount
            parts.append(fmt(amount))
            if pre <= 0 {
                lines.append("\(name)租金\(fmt(p.rent))元。")
            } else if hasUtility(p) {
                lines.append("\(name)租金+预存\(fmt(pre))元（含水电结算）。")
            } else {
                lines.append("\(name)租金+预存\(fmt(pre))元。")
            }
        }
        lines.append("合计：\(parts.joined(separator: "+"))=\(fmt(total))元")
        return lines.joined(separator: "\n")
    }

    private var totalAmount: Double {
        selectedProperties.reduce(0) { $0 + $1.rent + $1.prepayment }
    }

    // MARK: - UI

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 年月选择 + 全选
                HStack(spacing: 12) {
                    Picker("", selection: $selectedYear) {
                        ForEach(years, id: \.self) { Text("\($0)年").tag($0) }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 90)
                    Picker("", selection: $selectedMonth) {
                        ForEach(1...12, id: \.self) { Text("\($0)月").tag($0) }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 80)
                    Spacer()
                    Button(allSelected ? "取消全选" : "全选") {
                        selectedIDs = allSelected ? [] : Set(sortedProperties.map { $0.id })
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.themeAccent)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                Divider()

                // 选房列表：房号 + 房东 + 交租日 + 当月水电结算标记
                List {
                    ForEach(sortedProperties) { p in
                        row(p)
                            .contentShape(Rectangle())
                            .onTapGesture { toggle(p.id) }
                    }
                }
                .listStyle(.plain)

                Divider()
                // 底部：文案预览 + 一键复制
                VStack(spacing: 8) {
                    HStack {
                        Text("已选 \(selectedProperties.count) 户 · 合计 ¥\(fmt(totalAmount))")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.themeText2)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    TextEditor(text: .constant(statText()))
                        .font(.system(size: 13))
                        .foregroundColor(.themeText)
                        .frame(height: 128)
                        .padding(6)
                        .background(Color.themePanel)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, 16)
                        .disabled(true)
                    Button {
                        let text = statText()
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
    }

    private func row(_ p: Property) -> some View {
        let selected = selectedIDs.contains(p.id)
        let util = hasUtility(p)
        return HStack(spacing: 10) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20))
                .foregroundColor(selected ? .themeAccent : Color(.systemGray3))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(p.roomNumber)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.themeText)
                    if util {
                        Text("含水电")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.orange.opacity(0.15))
                            .foregroundColor(.orange)
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
            Text("¥\(fmt(p.rent))")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.themeText)
        }
        .padding(.vertical, 4)
    }
}
