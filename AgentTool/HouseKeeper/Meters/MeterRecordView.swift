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
        case refreshRecords = "刷新记录"
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

            switch tab {
            case .records:
                recordsBody
            case .trend:
                MeterTrendView(meter: meter)
            case .refreshRecords:
                refreshRecordsBody
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

    /// 刷新记录：最新在上，最多 30 条（与用电趋势同源，均来自每次刷新的 history 记录）
    private var refreshLogs: [(t: TimeInterval, s: Double)] {
        (meter.history ?? []).reversed().prefix(30).map { ($0.t, $0.s) }
    }

    private var refreshRecordsBody: some View {
        Group {
            if refreshLogs.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.clockwise.circle")
                        .font(.system(size: 34))
                        .foregroundColor(.themeText3)
                    Text("暂无刷新记录")
                        .font(.system(size: 14))
                        .foregroundColor(.themeText3)
                    Text("每次刷新电表后自动记录剩余电量与刷新时间，最多保留最近 30 次")
                        .font(.system(size: 12))
                        .foregroundColor(.themeText3.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section {
                        ForEach(Array(refreshLogs.enumerated()), id: \.offset) { idx, item in
                            HStack {
                                Text("第 \(refreshLogs.count - idx) 次刷新")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.themeText3)
                                    .frame(width: 86, alignment: .leading)
                                Text(String(format: "剩余 %.2f 度", item.s))
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.themeAccentDark)
                                Spacer()
                                Text(formatLogTime(item.t))
                                    .font(.system(size: 12))
                                    .foregroundColor(.themeText3)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private func formatLogTime(_ t: TimeInterval) -> String {
        let d = Date(timeIntervalSince1970: t)
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f.string(from: d)
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
/// b106：左侧竖轴刻度（剩余电量）+ 底部横轴刻度（时间），每个数据点用浅色虚线垂直/水平连到两条轴
private struct TrendLineView: View {
    let points: [MeterHistoryPoint]
    let size: CGSize

    // 轴预留空间
    private let leftPad: CGFloat = 38
    private let bottomPad: CGFloat = 24
    private let topPad: CGFloat = 10
    private let rightPad: CGFloat = 8

    private struct AxisTick: Identifiable {
        let id = UUID()
        let label: String
        let frac: CGFloat   // 0~1 在轴上的位置
    }

    var body: some View {
        let maxVal = max(points.map(\.s).max() ?? 0, 1)
        let minVal = max(points.map(\.s).min() ?? 0, 0)
        let range = max(maxVal - minVal, 1)
        let w = max(size.width - leftPad - rightPad, 1)
        let h = max(size.height - topPad - bottomPad, 1)
        let n = points.count
        let yTicks = yTicks(max: maxVal)
        let xTicks = xTicks(count: n)

        ZStack {
            // ---- 竖轴（左侧）+ 水平网格线 + 刻度文字 ----
            ForEach(yTicks) { tick in
                let gy = topPad + h * (1 - tick.frac)
                Path { p in
                    p.move(to: CGPoint(x: leftPad, y: gy))
                    p.addLine(to: CGPoint(x: size.width - rightPad, y: gy))
                }
                .stroke(Color.themeBorder.opacity(0.4), lineWidth: 0.6)
                // 左侧刻度值
                Text(tick.label)
                    .font(.system(size: 9))
                    .foregroundColor(.themeText3.opacity(0.85))
                    .position(x: leftPad - 5, y: gy)
            }
            // 竖轴主线
            Path { p in
                p.move(to: CGPoint(x: leftPad, y: topPad))
                p.addLine(to: CGPoint(x: leftPad, y: topPad + h))
            }
            .stroke(Color.themeBorder.opacity(0.7), lineWidth: 0.8)
            // 竖轴标题
            Text("电量(度)")
                .font(.system(size: 9))
                .foregroundColor(.themeText3.opacity(0.7))
                .position(x: 8, y: topPad + 8)

            // ---- 横轴（底部）+ 刻度文字 ----
            Path { p in
                p.move(to: CGPoint(x: leftPad, y: topPad + h))
                p.addLine(to: CGPoint(x: size.width - rightPad, y: topPad + h))
            }
            .stroke(Color.themeBorder.opacity(0.7), lineWidth: 0.8)
            ForEach(xTicks) { tick in
                let gx = leftPad + w * tick.frac
                Path { p in
                    p.move(to: CGPoint(x: gx, y: topPad + h))
                    p.addLine(to: CGPoint(x: gx, y: topPad + h + 3))
                }
                .stroke(Color.themeBorder.opacity(0.6), lineWidth: 0.8)
                Text(tick.label)
                    .font(.system(size: 8))
                    .foregroundColor(.themeText3.opacity(0.85))
                    .position(x: gx, y: topPad + h + 12)
            }

            // ---- 每个数据点：浅色虚线连到横轴与竖轴 ----
            ForEach(0..<n, id: \.self) { i in
                let p = xy(i, padTop: topPad, left: leftPad, w: w, h: h, n: n, minVal: minVal, range: range)
                // 垂直虚线（点到横轴）
                Path { path in
                    path.move(to: CGPoint(x: p.x, y: p.y))
                    path.addLine(to: CGPoint(x: p.x, y: topPad + h))
                }
                .stroke(Color.themeAccent.opacity(0.32), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                // 水平虚线（点到竖轴）
                Path { path in
                    path.move(to: CGPoint(x: p.x, y: p.y))
                    path.addLine(to: CGPoint(x: leftPad, y: p.y))
                }
                .stroke(Color.themeAccent.opacity(0.32), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }

            // ---- 折线（原走势不变） ----
            Path { p in
                p.move(to: xy(0, padTop: topPad, left: leftPad, w: w, h: h, n: n, minVal: minVal, range: range))
                for i in 1..<n {
                    p.addLine(to: xy(i, padTop: topPad, left: leftPad, w: w, h: h, n: n, minVal: minVal, range: range))
                }
            }
            .stroke(Color.themeAccentDark, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            // 渐变填充
            Path { p in
                p.move(to: xy(0, padTop: topPad, left: leftPad, w: w, h: h, n: n, minVal: minVal, range: range))
                for i in 1..<n {
                    p.addLine(to: xy(i, padTop: topPad, left: leftPad, w: w, h: h, n: n, minVal: minVal, range: range))
                }
                p.addLine(to: CGPoint(x: xy(n - 1, padTop: topPad, left: leftPad, w: w, h: h, n: n, minVal: minVal, range: range).x, y: topPad + h))
                p.addLine(to: CGPoint(x: xy(0, padTop: topPad, left: leftPad, w: w, h: h, n: n, minVal: minVal, range: range).x, y: topPad + h))
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
                        .position(xy(i, padTop: topPad, left: leftPad, w: w, h: h, n: n, minVal: minVal, range: range))
                }
            } else {
                Circle().fill(Color.white)
                    .overlay(Circle().stroke(Color.themeAccentDark, lineWidth: 1.5))
                    .frame(width: 7, height: 7)
                    .position(xy(0, padTop: topPad, left: leftPad, w: w, h: h, n: n, minVal: minVal, range: range))
                Circle().fill(Color.white)
                    .overlay(Circle().stroke(Color.themeAccentDark, lineWidth: 1.5))
                    .frame(width: 7, height: 7)
                    .position(xy(n - 1, padTop: topPad, left: leftPad, w: w, h: h, n: n, minVal: minVal, range: range))
            }
        }
        .frame(width: size.width, height: size.height)
    }

    /// 竖轴刻度：5 档取整（0 / 25% / 50% / 75% / 100%）
    private func yTicks(max: Double) -> [AxisTick] {
        let step = max / 4
        return (0...4).map { i in
            let v = step * CGFloat(i)
            let label: String
            if v == v.rounded() {
                label = "\(Int(v))"
            } else {
                label = String(format: "%.1f", v)
            }
            return AxisTick(label: label, frac: CGFloat(i) / 4)
        }
    }

    /// 横轴刻度：最多 4 档（首 / 1/3 / 2/3 / 末）
    private func xTicks(count: Int) -> [AxisTick] {
        guard count > 1 else { return [] }
        let idxs = [0, count / 3, count * 2 / 3, count - 1]
        var seen = Set<Int>()
        var ticks: [AxisTick] = []
        for i in idxs where !seen.contains(i) {
            seen.insert(i)
            let d = Date(timeIntervalSince1970: points[i].t)
            let f = DateFormatter()
            f.dateFormat = "MM-dd HH:mm"
            ticks.append(AxisTick(label: f.string(from: d), frac: CGFloat(i) / CGFloat(count - 1)))
        }
        return ticks
    }

    private func xy(_ i: Int, padTop: CGFloat, left: CGFloat, w: CGFloat, h: CGFloat, n: Int, minVal: Double, range: Double) -> CGPoint {
        let x = left + w * CGFloat(i) / CGFloat(max(n - 1, 1))
        let y = padTop + h * (1 - CGFloat((points[i].s - minVal) / range))
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
