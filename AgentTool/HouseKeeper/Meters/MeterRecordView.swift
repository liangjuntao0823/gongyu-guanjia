//
//  MeterRecordView.swift
//  公寓管家 · 单表充值记录 + 用电趋势
//  点击记录按钮即自动拉取最新官方充值记录；支持手动刷新与 CSV 导出；
//  分段查看「用电趋势」：每次刷新自动积累的剩余电量走势
//

import SwiftUI

struct MeterRecordView: View {
    @EnvironmentObject private var store: MeterStore
    let meter: MeterLedger

    @State private var tab: MeterRecordTab = .records
    @State private var records: [MeterPayRecord] = []
    @State private var loading = false
    @State private var errorText: String?
    @State private var sharePath: MeterShareFile?

    enum MeterRecordTab: String, CaseIterable, Identifiable {
        case records = "充值记录"
        case trend = "用电趋势"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(MeterRecordTab.allCases) { t in
                    Text(t.rawValue).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 8)

            if tab == .records {
                recordsBody
            } else {
                MeterTrendView(meter: meter)
            }
        }
        .navigationTitle(meter.room.isEmpty ? "\(meter.uid) · 详情" : "\(meter.room) · 详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(loading)
            }
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
            // 点记录按钮即自动刷新展示最新记录
            Task { await load() }
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

    private var recordsBody: some View {
        Group {
            if loading && records.isEmpty {
                ProgressView("正在拉取充值记录…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if records.isEmpty {
                        Section {
                            VStack(spacing: 6) {
                                Text("该电表暂无充值记录")
                                    .font(.system(size: 14))
                                    .foregroundColor(.themeText3)
                                Text("提示：官方接口仅返回本微信身份充值的记录")
                                    .font(.system(size: 11))
                                    .foregroundColor(.themeText3.opacity(0.7))
                            }
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
                .listStyle(.plain)
                .refreshable {
                    await load()
                }
            }
        }
    }

    private func currentProvider() -> MeterQuerying {
        switch store.settings.provider {
        case .webView: return MeterWebViewProvider.shared
        default: return MeterQueryService.shared
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            records = try await currentProvider().payRecords(store: store, uid: meter.uid)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func exportCSV() async {
        do {
            let recs = try await currentProvider().payRecords(store: store, uid: meter.uid)
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

// MARK: - 用电趋势（每次刷新自动积累，纯 SwiftUI 折线，无三方依赖）

struct MeterTrendView: View {
    let meter: MeterLedger

    private var points: [MeterHistoryPoint] {
        meter.history ?? []
    }

    var body: some View {
        Group {
            if points.count < 2 {
                VStack(spacing: 10) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 34))
                        .foregroundColor(.themeText3)
                    Text("暂无趋势数据")
                        .font(.system(size: 14))
                        .foregroundColor(.themeText3)
                    Text("每次刷新电表后自动记录剩余电量，积累 2 次以上即可查看走势")
                        .font(.system(size: 12))
                        .foregroundColor(.themeText3.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Text("剩余电量走势（度）")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.themeText3)
                        Spacer()
                        Text("最近 \(points.count) 次刷新")
                            .font(.system(size: 11))
                            .foregroundColor(.themeText3.opacity(0.7))
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)

                    GeometryReader { geo in
                        TrendLineView(points: points, size: geo.size)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)

                    HStack {
                        Text(formatTime(points.first?.t))
                            .font(.system(size: 10))
                            .foregroundColor(.themeText3.opacity(0.8))
                        Spacer()
                        Text(formatTime(points.last?.t))
                            .font(.system(size: 10))
                            .foregroundColor(.themeText3.opacity(0.8))
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)

                    // 最新数据摘要
                    if let last = points.last {
                        HStack(spacing: 12) {
                            metricBox("剩余", String(format: "%.2f 度", last.s), .themeAccentDark)
                            metricBox("累计", String(format: "%.2f 度", last.l), .orange)
                            metricBox("变化", lastChangeText, .red)
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.themePanel)
    }

    private var lastChangeText: String {
        guard points.count >= 2 else { return "--" }
        let d = points[points.count - 1].s - points[points.count - 2].s
        return d >= 0 ? "+\(String(format: "%.2f", d))" : String(format: "%.2f", d)
    }

    private func metricBox(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10))
                .foregroundColor(.themeText3)
            Text(value)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.themeBorder, lineWidth: 1))
    }

    private func formatTime(_ t: TimeInterval?) -> String {
        guard let t else { return "--" }
        let d = Date(timeIntervalSince1970: t)
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: d)
    }
}

/// 折线绘制：x 按时间均匀分布，y 覆盖 [0, max] 并留 12% 上边距
private struct TrendLineView: View {
    let points: [MeterHistoryPoint]
    let size: CGSize

    var body: some View {
        let maxVal = max(points.map(\.s).max() ?? 0, 1)
        let minVal = max(points.map(\.s).min() ?? 0, 0)
        let range = max(maxVal - minVal, 1)
        let pad: CGFloat = 6
        let w = max(size.width - pad * 2, 1)
        let h = max(size.height - pad * 2, 1)
        let n = points.count

        ZStack {
            // 网格线（3 条水平）
            ForEach(0..<4, id: \.self) { i in
                let gy = pad + h * CGFloat(i) / 3
                Path { p in
                    p.move(to: CGPoint(x: pad, y: gy))
                    p.addLine(to: CGPoint(x: size.width - pad, y: gy))
                }
                .stroke(Color.themeBorder.opacity(0.4), lineWidth: 0.6)
            }
            // 折线
            Path { p in
                p.move(to: xy(0, pad: pad, w: w, h: h, n: n, minVal: minVal, range: range))
                for i in 1..<n {
                    p.addLine(to: xy(i, pad: pad, w: w, h: h, n: n, minVal: minVal, range: range))
                }
            }
            .stroke(Color.themeAccentDark, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            // 渐变填充
            Path { p in
                p.move(to: xy(0, pad: pad, w: w, h: h, n: n, minVal: minVal, range: range))
                for i in 1..<n {
                    p.addLine(to: xy(i, pad: pad, w: w, h: h, n: n, minVal: minVal, range: range))
                }
                p.addLine(to: CGPoint(x: xy(n - 1, pad: pad, w: w, h: h, n: n, minVal: minVal, range: range).x, y: pad + h))
                p.addLine(to: CGPoint(x: xy(0, pad: pad, w: w, h: h, n: n, minVal: minVal, range: range).x, y: pad + h))
                p.closeSubpath()
            }
            .fill(LinearGradient(colors: [Color.themeAccent.opacity(0.22), Color.themeAccent.opacity(0.02)],
                                 startPoint: .top, endPoint: .bottom))
            // 数据点（最多显示 20 个圆点，避免密集）
            if n <= 20 {
                ForEach(0..<n, id: \.self) { i in
                    Circle()
                        .fill(Color.white)
                        .overlay(Circle().stroke(Color.themeAccentDark, lineWidth: 1.5))
                        .frame(width: 7, height: 7)
                        .position(xy(i, pad: pad, w: w, h: h, n: n, minVal: minVal, range: range))
                }
            } else {
                // 密集时显示首尾两点
                Circle().fill(Color.white)
                    .overlay(Circle().stroke(Color.themeAccentDark, lineWidth: 1.5))
                    .frame(width: 7, height: 7)
                    .position(xy(0, pad: pad, w: w, h: h, n: n, minVal: minVal, range: range))
                Circle().fill(Color.white)
                    .overlay(Circle().stroke(Color.themeAccentDark, lineWidth: 1.5))
                    .frame(width: 7, height: 7)
                    .position(xy(n - 1, pad: pad, w: w, h: h, n: n, minVal: minVal, range: range))
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func xy(_ i: Int, pad: CGFloat, w: CGFloat, h: CGFloat, n: Int, minVal: Double, range: Double) -> CGPoint {
        let x = pad + w * CGFloat(i) / CGFloat(max(n - 1, 1))
        let y = pad + h * (1 - CGFloat((points[i].s - minVal) / range))
        return CGPoint(x: x, y: y)
    }
}

private extension DateFormatter {
    static var exportStamp: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMddHHmm"
        return f
    }
}
