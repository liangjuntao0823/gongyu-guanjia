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
    /// 自定义图片名（Assets 里的 imageset）；nil 时使用 SF Symbol
    let imageName: String?

    init(id: String, label: String, icon: String, color: Color, imageName: String? = nil) {
        self.id = id
        self.label = label
        self.icon = icon
        self.color = color
        self.imageName = imageName
    }
}

enum QuickActionRegistry {
    /// 全部 12 个动作的固定定义（顺序即默认展示顺序参考）
    static let all: [QuickActionMeta] = [
        QuickActionMeta(id: "deal",     label: "新增成交", icon: "plus.circle.fill",        color: .themeAccent),
        QuickActionMeta(id: "income",   label: "新增收入", icon: "dollarsign.circle.fill",  color: Color(hex: "CD5C5C")),
        QuickActionMeta(id: "expense",  label: "新增支出", icon: "dollarsign.circle.fill",  color: Color(hex: "2E8B57")),
        QuickActionMeta(id: "rent",     label: "新增收租", icon: "creditcard.fill",         color: .themeBlue),
        QuickActionMeta(id: "todo",     label: "新增待办", icon: "checklist",               color: .themeAccentDark),
        QuickActionMeta(id: "meter",    label: "电表管理", icon: "bolt.batteryblock.fill",  color: .themeBlue),
        QuickActionMeta(id: "ajk",      label: "安居客",   icon: "building.2.fill",         color: .themeBlue, imageName: "AjkIcon"),
        QuickActionMeta(id: "ai",       label: "AI 助手",  icon: "sparkles",               color: .themeAccentDark, imageName: "DoubaoIcon"),
        QuickActionMeta(id: "admin",    label: "后台管理", icon: "gauge",                   color: .themeBlue),
        QuickActionMeta(id: "payout",   label: "新增包租", icon: "arrow.up.circle.fill",    color: Color(hex: "6B3FA0")),
        QuickActionMeta(id: "utility",  label: "水电结算", icon: "drop.circle.fill",        color: .themeBlue),
        QuickActionMeta(id: "house",    label: "新增房源", icon: "building.2.fill",         color: .themeAccentDark)
    ]

    /// 默认布局：工作台 7 个动作 + 第 8 位固定「更多」；更多收纳 后台管理/包租/水电结算/新增房源（安居客/AI 助手按需由用户排序）
    static let defaultDashboard: [String] = ["deal", "income", "expense", "rent", "todo", "meter", "ajk"]
    static let defaultMore: [String] = ["ai", "admin", "payout", "utility", "house"]

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

    private enum Zone { case dash, more }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(dashIDs, id: \.self) { id in
                        row(meta: QuickActionRegistry.meta(id), zone: .dash)
                    }
                    .onMove { from, to in
                        var arr = dashIDs
                        arr.move(fromOffsets: from, toOffset: to)
                        writeDash(arr)
                    }
                } header: {
                    Text("工作台（最多 7 项，第 8 位固定为「更多」）")
                } footer: {
                    Text("点减号把某项收进「更多」；拖动排序")
                }

                Section {
                    ForEach(moreIDs, id: \.self) { id in
                        row(meta: QuickActionRegistry.meta(id), zone: .more)
                    }
                    .onMove { from, to in
                        var arr = moreIDs
                        arr.move(fromOffsets: from, toOffset: to)
                        writeMore(arr)
                    }
                } header: {
                    Text("更多（收纳区）")
                } footer: {
                    Text("点加号把某项移回工作台；拖动排序。改动即时保存。")
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

    private func row(meta: QuickActionMeta?, zone: Zone) -> some View {
        HStack(spacing: 10) {
            // 上区减号（收进更多）/ 下区加号（移回工作台），直接点击操作，不需要左滑
            Button {
                moveBetweenZones(meta: meta, zone: zone)
            } label: {
                Image(systemName: zone == .dash ? "minus.circle.fill" : "plus.circle.fill")
                    .font(.system(size: 19))
                    .foregroundColor(zone == .dash ? Color(hex: "E74C3C") : Color(hex: "2E8B57"))
            }
            .buttonStyle(.plain)
            if let img = meta?.imageName {
                Image(img)
                    .resizable()
                    .frame(width: 30, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: meta?.icon ?? "questionmark.circle")
                    .font(.system(size: 15))
                    .foregroundColor(.white)
                    .frame(width: 30, height: 30)
                    .background(meta?.color ?? .gray)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Text(meta?.label ?? "未知")
                .font(.system(size: 15, weight: .medium))
            Spacer()
        }
    }

    /// 上区点减号 → 收进「更多」；下区点加号 → 移回工作台（工作台满 7 项则提示）
    private func moveBetweenZones(meta: QuickActionMeta?, zone: Zone) {
        guard let id = meta?.id else { return }
        var dash = dashIDs
        var more = moreIDs
        if zone == .dash {
            // 收进「更多」
            dash.removeAll { $0 == id }
            if !more.contains(id) { more.insert(id, at: 0) }
            writeDash(dash)
            writeMore(more)
            showToast("已收纳到「更多」")
        } else {
            // 移回工作台
            guard dash.count < 7 else {
                showToast("工作台已满（7 项），请先收纳一项")
                return
            }
            more.removeAll { $0 == id }
            if !dash.contains(id) { dash.append(id) }
            writeDash(dash)
            writeMore(more)
            showToast("已放到工作台")
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
