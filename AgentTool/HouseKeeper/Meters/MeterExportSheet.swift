//
//  MeterExportSheet.swift
//  公寓管家 · 导出充值记录
//  支持：多选已绑定电表（默认全选）+ 手动输入户号（一行一个）→ 串行拉取全部充值记录 → CSV 分享
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

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(Color.themeBorder).frame(width: 40, height: 4).padding(.top, 10)
            HStack {
                Text("导出充值记录")
                    .font(.system(size: 16, weight: .bold))
                Spacer()
                if !selected.isEmpty {
                    Button("全选") { selectAll() }
                        .font(.system(size: 13))
                        .foregroundColor(.themeAccentDark)
                }
            }
            .padding(.top, 12)
            .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("选择电表（默认全选已绑定）")
                        .font(.system(size: 13))
                        .foregroundColor(.themeText3)
                    if store.meters.isEmpty {
                        Text("暂无已绑定电表，可先到电表管理导入，或在下方手动输入户号")
                            .font(.system(size: 12))
                            .foregroundColor(.themeText3)
                            .padding(12)
                            .frame(maxWidth: .infinity)
                            .background(Color.themeBorder.opacity(0.25))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(store.meters) { meter in
                                Button {
                                    toggle(meter.uid)
                                } label: {
                                    HStack(spacing: 9) {
                                        Image(systemName: selected.contains(meter.uid) ? "checkmark.square.fill" : "square")
                                            .font(.system(size: 18))
                                            .foregroundColor(selected.contains(meter.uid) ? .themeAccentDark : .themeText3)
                                        Text(meter.uid)
                                            .font(.system(size: 14, weight: .semibold))
                                        Spacer()
                                        if !meter.room.isEmpty {
                                            Text(meter.room)
                                                .font(.system(size: 12))
                                                .foregroundColor(.themeText3)
                                        } else {
                                            Text("未绑定")
                                                .font(.system(size: 12))
                                                .foregroundColor(.themeText3.opacity(0.6))
                                        }
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
        .onAppear { if selected.isEmpty { selectAll() } }
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
        selected = Set(store.meters.map { $0.uid })
    }
    private func toggle(_ uid: String) {
        if selected.contains(uid) { selected.remove(uid) } else { selected.insert(uid) }
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
                let records = try await MeterQueryService.shared.payRecords(store: store, uid: uid)
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
