//
//  MeterExportSheet.swift
//  公寓管家 · 批量导出充值记录
//  列表 = 官方绑定（自动拉取）∪ 本地清单；默认不勾选；全选按钮只增不减；
//  支持排序（户号/房号降序/电量低高/电量高低）与搜索；手动输入户号一行一个
//

import SwiftUI
import UIKit

struct MeterExportSheet: View {
    @EnvironmentObject private var store: MeterStore
    @Environment(\.dismiss) private var dismiss

    @State private var selected: Set<String> = []
    @State private var manual = ""
    @State private var exporting = false
    @State private var progressText = ""
    @State private var errorText: String?
    @State private var sharePath: MeterShareFile?

    @State private var bindings: [String]? = nil     // 官方绑定列表（拉取成功前为 nil）
    @State private var sortMode: MeterExportSortMode = .uidAsc
    @State private var keyword = ""
    @State private var showSearch = false

    enum MeterExportSortMode: String, CaseIterable, Identifiable {
        case uidAsc, roomDesc, balAsc, balDesc
        var id: String { rawValue }
        var label: String {
            switch self {
            case .uidAsc: return "户号升序"
            case .roomDesc: return "房号降序"
            case .balAsc: return "电量低→高"
            case .balDesc: return "电量高→低"
            }
        }
    }

    struct Candidate: Identifiable {
        var id: String { uid }
        let uid: String
        let room: String
        let bal: Double
    }

    /// 导出候选：官方绑定 ∪ 本地清单（去重），备注取本地编辑
    private var candidates: [Candidate] {
        var seen = Set<String>()
        var arr: [Candidate] = []
        if let bs = bindings {
            for uid in bs where seen.insert(uid).inserted {
                let m = store.meters.first { $0.uid == uid }
                arr.append(Candidate(uid: uid, room: m?.room ?? "", bal: m?.shengyu ?? 0))
            }
        } else {
            for m in store.meters where seen.insert(m.uid).inserted {
                arr.append(Candidate(uid: m.uid, room: m.room, bal: m.shengyu))
            }
        }
        // 本地清单中不在官方列表的补集（用户手动添加）
        for m in store.meters where seen.insert(m.uid).inserted {
            arr.append(Candidate(uid: m.uid, room: m.room, bal: m.shengyu))
        }
        return arr
    }

    private var sorted: [Candidate] {
        var arr = candidates
        switch sortMode {
        case .uidAsc: arr.sort { $0.uid < $1.uid }
        case .roomDesc: arr.sort {
            let a = $0.room.isEmpty ? $0.uid : $0.room
            let b = $1.room.isEmpty ? $1.uid : $1.room
            return a > b
        }
        case .balAsc: arr.sort { $0.bal < $1.bal }
        case .balDesc: arr.sort { $0.bal > $1.bal }
        }
        return arr
    }

    private var filtered: [Candidate] {
        let k = keyword.trimmingCharacters(in: .whitespaces)
        guard !k.isEmpty else { return sorted }
        return sorted.filter { $0.uid.contains(k) || $0.room.contains(k) }
    }

    private var allSelected: Bool {
        !filtered.isEmpty && filtered.allSatisfy { selected.contains($0.uid) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(Color.themeBorder).frame(width: 40, height: 4).padding(.top, 10)
            HStack {
                Text("导出充值记录")
                    .font(.system(size: 16, weight: .bold))
                Spacer()
                // 全选：只增不减（已全选时置灰，点击不会取消）
                Button {
                    selectAll()
                } label: {
                    Text("全选")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(allSelected ? .themeText3.opacity(0.5) : .themeAccentDark)
                }
                .disabled(allSelected)
            }
            .padding(.top, 12)
            .padding(.bottom, 8)

            // 工具行：排序 + 搜索
            HStack(spacing: 8) {
                Menu {
                    ForEach(MeterExportSortMode.allCases) { m in
                        Button {
                            sortMode = m
                        } label: {
                            if sortMode == m {
                                Label(m.label, systemImage: "checkmark")
                            } else {
                                Text(m.label)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 11, weight: .semibold))
                        Text(sortMode.label)
                            .font(.system(size: 13))
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(Color.white)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.themeBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)

                Button {
                    withAnimation { showSearch.toggle() }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 34, height: 32)
                        .background(Color.white)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(keyword.isEmpty ? Color.themeBorder : Color.themeAccentDark, lineWidth: 1))
                }
                .buttonStyle(.plain)

                if showSearch {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12))
                            .foregroundColor(.themeText3)
                        TextField("搜索户号或房号", text: $keyword)
                            .font(.system(size: 14))
                            .autocorrectionDisabled()
                        if !keyword.isEmpty {
                            Button {
                                keyword = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 13))
                                    .foregroundColor(.themeText3)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.themeBorder.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .transition(.opacity)
                }

                Spacer()
                Text("已选 \(selected.count)")
                    .font(.system(size: 12))
                    .foregroundColor(.themeText3)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("选择电表（默认不选，官方绑定已自动同步）")
                        .font(.system(size: 13))
                        .foregroundColor(.themeText3)
                    if filtered.isEmpty {
                        VStack(spacing: 6) {
                            if bindings == nil {
                                ProgressView("正在同步官方绑定…")
                                    .font(.system(size: 12))
                            } else {
                                Text(keyword.isEmpty ? "暂无电表，可在下方手动输入户号" : "没有匹配的电表")
                                    .font(.system(size: 12))
                                    .foregroundColor(.themeText3)
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity)
                        .background(Color.themeBorder.opacity(0.25))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(filtered) { item in
                                Button {
                                    toggle(item.uid)
                                } label: {
                                    HStack(spacing: 9) {
                                        Image(systemName: selected.contains(item.uid) ? "checkmark.square.fill" : "square")
                                            .font(.system(size: 18))
                                            .foregroundColor(selected.contains(item.uid) ? .themeAccentDark : .themeText3)
                                        Text(item.uid)
                                            .font(.system(size: 14, weight: .semibold))
                                        Spacer()
                                        Text(item.room.isEmpty ? "未备注" : item.room)
                                            .font(.system(size: 12))
                                            .foregroundColor(item.room.isEmpty ? .themeText3.opacity(0.6) : .themeText3)
                                    }
                                    .padding(.vertical, 10)
                                    .padding(.horizontal, 6)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                Divider().padding(.leading, 6)
                            }
                        }
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.themeBorder, lineWidth: 1))
                    }

                    Text("手动输入户号（可选，一行一个）")
                        .font(.system(size: 13))
                        .foregroundColor(.themeText3)
                        .padding(.top, 6)
                    TextEditor(text: $manual)
                        .frame(height: 72)
                        .font(.system(size: 15))
                        .padding(8)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.themeBorder, lineWidth: 1))

                    if exporting {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(progressText)
                                .font(.system(size: 12))
                                .foregroundColor(.themeText3)
                        }
                        .padding(.vertical, 6)
                    }
                }
            }

            Button {
                Task { await doExport() }
            } label: {
                HStack(spacing: 6) {
                    if exporting {
                        ProgressView().tint(.white)
                    }
                    Text(exporting ? "正在导出…" : "导出 CSV")
                        .font(.system(size: 15, weight: .bold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(exporting ? Color.themeAccentDark.opacity(0.6) : Color.themeAccentDark)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(exporting)
            .padding(.top, 10)
            .padding(.bottom, 8)
        }
        .padding(.horizontal, 16)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear {
            // 默认不勾选；同步官方绑定列表（失败静默回退本地清单）
            if bindings == nil {
                Task {
                    do {
                        bindings = try await currentProvider().fetchBindings(store: store)
                    } catch {
                        bindings = []
                    }
                }
            }
        }
        .alert("提示", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("好", role: .cancel) { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
        .sheet(item: $sharePath) { file in
            MeterShareSheet(items: [URL(fileURLWithPath: file.path)])
        }
    }

    private func selectAll() {
        // 全选只增不减：仅把未选中的加入
        for item in filtered where !selected.contains(item.uid) {
            selected.insert(item.uid)
        }
    }
    private func toggle(_ uid: String) {
        if selected.contains(uid) { selected.remove(uid) } else { selected.insert(uid) }
    }

    private func currentProvider() -> MeterQuerying {
        switch store.settings.provider {
        case .webView: return MeterWebViewProvider.shared
        default: return MeterQueryService.shared
        }
    }

    private func doExport() async {
        var uids = selected.sorted()
        let manualUids = manual.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        for u in manualUids where !uids.contains(u) { uids.append(u) }
        guard !uids.isEmpty else {
            errorText = "请至少选择一台电表或输入一个户号"
            return
        }
        exporting = true
        defer { exporting = false }

        var rows: [[String]] = [["房号", "电表用户号", "订单号", "充值金额", "充值时间", "状态"]]
        for (i, uid) in uids.enumerated() {
            let room = store.meters.first { $0.uid == uid }?.room ?? ""
            progressText = "正在拉取 \(i + 1)/\(uids.count) · \(uid)"
            do {
                let records = try await currentProvider().payRecords(store: store, uid: uid)
                if records.isEmpty {
                    rows.append([room, uid, "（无充值记录）", "", "", ""])
                } else {
                    for r in records {
                        rows.append([room, uid, r.paymentOrder, r.paymentPayMoney, r.paymentPayDate, r.paid ? "成功" : "未支付"])
                    }
                }
            } catch {
                rows.append([room, uid, "（拉取失败：\(error.localizedDescription)）", "", "", ""])
            }
        }

        let csv = rows.map { row in
            row.map { cell in
                let c = cell.replacingOccurrences(of: "\"", with: "\"\"")
                return c.contains(",") || c.contains("\"") ? "\"\(c)\"" : c
            }.joined(separator: ",")
        }.joined(separator: "\n")

        // 写入临时文件供分享（带 BOM，Excel 打开不乱码）
        let fileName = "充值记录导出_\(DateFormatter.yyyyMMddHHmm.string(from: Date())).csv"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do {
            try Data(("\u{FEFF}" + csv).utf8).write(to: url)
            sharePath = MeterShareFile(path: url.path)
        } catch {
            errorText = "CSV 生成失败：\(error.localizedDescription)"
        }
    }
}

private extension DateFormatter {
    static var yyyyMMddHHmm: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMddHHmm"
        return f
    }
}

struct MeterShareFile: Identifiable {
    let id = UUID()
    let path: String
}

struct MeterShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
