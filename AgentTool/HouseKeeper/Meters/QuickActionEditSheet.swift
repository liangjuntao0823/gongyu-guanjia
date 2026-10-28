//
//  QuickActionEditSheet.swift
//  公寓管家 · 工作台快捷操作自定义排序（v1.84）
//  支持：拖拽重排工作台/更多两个区域、互相移入移出、实时保存（不重蹈水印开关不同步）
//

import SwiftUI

/// 快捷操作元数据（全部可用动作，DashboardView 渲染与编辑页共用同一份）
struct QuickActionMeta: Identifiable {
    let id: String
    let label: String
    let icon: String
    let color: Color
}

enum QuickActionRegistry {
    /// 全部 10 个动作的固定定义（顺序即默认展示顺序参考）
    static let all: [QuickActionMeta] = [
        QuickActionMeta(id: "deal",     label: "新增成交", icon: "plus.circle.fill",        color: .themeAccent),
        QuickActionMeta(id: "income",   label: "新增收入", icon: "dollarsign.circle.fill",  color: Color(hex: "CD5C5C")),
        QuickActionMeta(id: "expense",  label: "新增支出", icon: "dollarsign.circle.fill",  color: Color(hex: "2E8B57")),
        QuickActionMeta(id: "rent",     label: "新增收租", icon: "creditcard.fill",         color: .themeBlue),
        QuickActionMeta(id: "todo",     label: "新增待办", icon: "checklist",               color: .themeAccentDark),
        QuickActionMeta(id: "meter",    label: "电表管理", icon: "bolt.batteryblock.fill",  color: .themeBlue),
        QuickActionMeta(id: "admin",    label: "后台管理", icon: "gauge",                   color: .themeBlue),
        QuickActionMeta(id: "payout",   label: "新增包租", icon: "arrow.up.circle.fill",    color: Color(hex: "6B3FA0")),
        QuickActionMeta(id: "utility",  label: "水电结算", icon: "drop.circle.fill",        color: .themeBlue),
        QuickActionMeta(id: "house",    label: "新增房源", icon: "building.2.fill",         color: .themeAccentDark)
    ]

    /// v1.84 默认布局：第一行 成交/收入/支出/收租；第二行 待办/电表管理/后台管理/更多；更多收纳 包租/水电结算/新增房源
    static let defaultDashboard: [String] = ["deal", "income", "expense", "rent", "todo", "meter", "admin"]
    static let defaultMore: [String] = ["payout", "utility", "house"]

    static func meta(_ id: String) -> QuickActionMeta? {
        all.first { $0.id == id }
    }
}

/// 编辑排序弹窗：两区 + 拖拽重排 + 移入移出，任何变化立即写回存储
struct QuickActionEditSheet: View {
    @Binding var dashOrder: String
    @Binding var moreOrder: String
    @Environment(\.dismiss) private var dismiss
    @State private var toast: String?

    private var dashIDs: [String] {
        let parsed = parse(dashOrder)
        return parsed.isEmpty ? QuickActionRegistry.defaultDashboard : parsed
    }
    private var moreIDs: [String] {
        let parsed = parse(moreOrder)
        return parsed.isEmpty ? QuickActionRegistry.defaultMore : parsed
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(dashIDs, id: \.self) { id in
                        row(meta: QuickActionRegistry.meta(id))
                    }
                    .onMove { from, to in
                        var arr = dashIDs
                        arr.move(fromOffsets: from, toOffset: to)
                        writeDash(arr)
                    }
                    .onDelete { indexSet in
                        // 删除 = 移到「更多」（工作台每满 7 个，多出的自动收纳）
                        var dash = dashIDs
                        var more = moreIDs
                        for idx in indexSet.sorted(by: >) where idx < dash.count {
                            more.insert(dash.remove(at: idx), at: 0)
                        }
                        writeDash(dash)
                        writeMore(more)
                        showToast("已收纳到「更多」")
                    }
                } header: {
                    Text("工作台（最多 7 项，第 8 位固定为「更多」）")
                } footer: {
                    Text("拖动排序；左滑或点减号把某项收进「更多」")
                }

                Section {
                    ForEach(moreIDs, id: \.self) { id in
                        row(meta: QuickActionRegistry.meta(id))
                    }
                    .onMove { from, to in
                        var arr = moreIDs
                        arr.move(fromOffsets: from, toOffset: to)
                        writeMore(arr)
                    }
                    .onDelete { indexSet in
                        // 删除 = 移回工作台（工作台已满 7 项则提示）
                        guard dashIDs.count < 7 else {
                            showToast("工作台已满（7 项），请先收纳一项")
                            return
                        }
                        var dash = dashIDs
                        var more = moreIDs
                        for idx in indexSet.sorted(by: >) where idx < more.count {
                            dash.append(more.remove(at: idx))
                        }
                        writeDash(dash)
                        writeMore(more)
                        showToast("已放到工作台")
                    }
                } header: {
                    Text("更多（收纳区）")
                } footer: {
                    Text("拖动排序；左滑或点减号把某项移回工作台。改动即时保存。")
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("排序快捷操作")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .overlay(alignment: .bottom) {
                if let t = toast {
                    Text(t)
                        .font(.system(size: 13))
                        .foregroundColor(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.8))
                        .clipShape(Capsule())
                        .padding(.bottom, 20)
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                                withAnimation { self.toast = nil }
                            }
                        }
                }
            }
        }
    }

    private func row(meta: QuickActionMeta?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: meta?.icon ?? "questionmark.circle")
                .font(.system(size: 15))
                .foregroundColor(.white)
                .frame(width: 30, height: 30)
                .background(meta?.color ?? .gray)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(meta?.label ?? "未知")
                .font(.system(size: 15, weight: .medium))
            Spacer()
        }
    }

    private func parse(_ json: String) -> [String] {
        guard !json.isEmpty,
              let data = json.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        // 过滤掉已不存在的动作 id，保证渲染只出真实动作
        return arr.filter { QuickActionRegistry.meta($0) != nil }
    }
    private func encode(_ ids: [String]) -> String {
        guard let data = try? JSONEncoder().encode(ids) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    private func writeDash(_ ids: [String]) {
        dashOrder = encode(ids)
    }
    private func writeMore(_ ids: [String]) {
        moreOrder = encode(ids)
    }
    private func showToast(_ msg: String) {
        toast = msg
    }
}
