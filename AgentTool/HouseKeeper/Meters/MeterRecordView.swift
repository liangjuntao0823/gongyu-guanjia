//
//  MeterRecordView.swift
//  公寓管家 · 单表充值记录
//  查看指定电表的全部官方充值记录；右上角导出本表 CSV
//

import SwiftUI

struct MeterRecordView: View {
    @EnvironmentObject private var store: MeterStore
    let meter: MeterLedger

    @State private var records: [MeterPayRecord] = []
    @State private var loading = false
    @State private var errorText: String?
    @State private var sharePath: MeterShareFile?

    var body: some View {
        Group {
            if loading && records.isEmpty {
                ProgressView("正在拉取充值记录…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if records.isEmpty {
                        Section {
                            Text("该电表暂无充值记录")
                                .font(.system(size: 14))
                                .foregroundColor(.themeText3)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 30)
                        }
                    } else {
                        Section {
                            ForEach(records) { r in
                                HStack(alignment: .top, spacing: 10) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(r.amountText)
                                            .font(.system(size: 16, weight: .bold))
                                            .foregroundColor(r.paid ? .themeAccentDark : .orange)
                                        Text("订单 \(r.paymentOrder)")
                                            .font(.system(size: 11))
                                            .foregroundColor(.themeText3)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 3) {
                                        Text(r.paid ? "成功" : "未支付")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundColor(r.paid ? .themeAccentDark : .orange)
                                        Text(r.paymentPayDate.isEmpty ? r.paymentCreateDate : r.paymentPayDate)
                                            .font(.system(size: 11))
                                            .foregroundColor(.themeText3)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }
                .refreshable {
                    await load()
                }
            }
        }
        .navigationTitle(meter.room.isEmpty ? "充值记录 · \(meter.uid)" : "\(meter.room) · 充值记录")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await exportCSV() }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(loading || records.isEmpty)
            }
        }
        .onAppear {
            if records.isEmpty { Task { await load() } }
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

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            records = try await MeterQueryService.shared.payRecords(store: store, uid: meter.uid)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func exportCSV() async {
        do {
            let recs = try await MeterQueryService.shared.payRecords(store: store, uid: meter.uid)
            let room = meter.room.isEmpty ? meter.uid : meter.room
            var rows: [[String]] = [["房号", "电表用户号", "订单号", "充值金额", "充值时间", "状态"]]
            for r in recs {
                rows.append([room, meter.uid, r.paymentOrder, r.paymentPayMoney, r.paymentPayDate, r.paid ? "成功" : "未支付"])
            }
            let csv = rows.map { row in
                row.map { cell in
                    let c = cell.replacingOccurrences(of: "\"", with: "\"\"")
                    return c.contains(",") || c.contains("\"") ? "\"\(c)\"" : c
                }.joined(separator: ",")
            }.joined(separator: "\n")
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("充值记录_\(meter.uid)_\(DateFormatter.exportStamp.string(from: Date())).csv")
            try Data(("\u{FEFF}" + csv).utf8).write(to: url)
            sharePath = MeterShareFile(path: url.path)
        } catch {
            errorText = error.localizedDescription
        }
    }
}

private extension DateFormatter {
    static var exportStamp: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMddHHmm"
        return f
    }
}
