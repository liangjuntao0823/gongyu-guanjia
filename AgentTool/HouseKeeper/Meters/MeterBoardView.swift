//
//  MeterBoardView.swift
//  公寓管家 · 电表监控主界面
//  三行卡片布局：户号+房号+状态 / 剩余电量+累计+记录充值 / 抄表时间+单表刷新
//

import SwiftUI

// MARK: - 主界面

struct MeterBoardView: View {
    @EnvironmentObject private var store: MeterStore
    @Environment(\.dismiss) private var dismiss

    @State private var sortMode: MeterSortMode = .balAsc
    @State private var filterMode: MeterFilterMode = .all
    @State private var threshold: Double = MeterStore.shared.settings.lowThreshold

    @State private var refreshing = false
    @State private var refreshProgress = 0
    @State private var refreshTotal = 0
    @State private var refreshLabel = ""
    @State private var errorText: String?

    @State private var showSort = false
    @State private var showFilter = false
    @State private var showAdd = false
    @State private var showExport = false
    @State private var showManage = false
    @State private var selectedMeter: MeterLedger?

    var body: some View {
        ZStack {
            Color.themePanel.ignoresSafeArea()
            VStack(spacing: 0) {
                navBar
                if refreshing { refreshProgressBar }
                ScrollView {
                    VStack(spacing: 0) {
                        statsCards
                        toolRow
                        meterList
                    }
                    .padding(.bottom, 30)
                }
                .refreshable { await refreshAll() }
            }
        }
        .navigationBarHidden(true)
        .onAppear { autoRefreshOnEnter() }
        .sheet(isPresented: $showSort) { MeterSortSheet(mode: $sortMode) }
        .sheet(isPresented: $showFilter) { MeterFilterSheet(mode: $filterMode, threshold: $threshold) }
        .sheet(isPresented: $showAdd) { MeterAddSheet() }
        .sheet(isPresented: $showExport) { MeterExportSheet() }
        .sheet(isPresented: $showManage) {
            NavigationStack { MeterManageView() }
        }
        .sheet(item: $selectedMeter) { meter in
            NavigationStack { MeterRecordView(meter: meter) }
        }
        .alert("提示", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("好", role: .cancel) { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
    }

    // MARK: - 顶部导航

    private var navBar: some View {
        ZStack {
            LinearGradient(colors: [.themeAccentDark, .themeAccent], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
            HStack(spacing: 8) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 38, height: 38)
                        .background(Color.white.opacity(0.14))
                        .clipShape(RoundedRectangle(cornerRadius: 11))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("电表监控")
                        .font(.system(size: 17, weight: .bold))
                    Text(subTitle)
                        .font(.system(size: 10.5))
                        .opacity(0.75)
                        .lineLimit(1)
                }
                Spacer()
                HStack(spacing: 6) {
                    // 导出记录（右上角，刷新左侧）
                    Button { showExport = true } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 36, height: 36)
                            .background(Color.white.opacity(0.14))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    // 刷新全部
                    Button { Task { await refreshAll() } } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 36, height: 36)
                            .background(Color.white.opacity(0.14))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    // 电表管理（添加入口）
                    Button { showManage = true } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 36, height: 36)
                            .background(Color.white.opacity(0.14))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 10)
            .foregroundColor(.white)
        }
        .frame(height: 56)
    }

    private var subTitle: String {
        if refreshing { return "米兰公馆 · 正在刷新 \(refreshLabel)" }
        return "米兰公馆 · 共 \(store.meters.count) 台电表"
    }

    private var refreshProgressBar: some View {
        VStack(spacing: 0) {
            ProgressView(value: refreshTotal > 0 ? Double(refreshProgress) / Double(refreshTotal) : 0)
                .progressViewStyle(.linear)
                .tint(.white)
                .background(Color.white.opacity(0.25))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(height: 12)
            Text("正在刷新 \(refreshProgress)/\(refreshTotal)：\(refreshLabel)")
                .font(.system(size: 11))
                .foregroundColor(.themeText3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
        }
        .background(Color.themeAccent.opacity(0.06))
    }

    // MARK: - 统计卡

    private var statsCards: some View {
        HStack(spacing: 8) {
            statCard(title: "电表总数", value: "\(store.meters.count)", hint: "全部已绑定", color: .themeText)
            statCard(title: "低电量 <\(Int(threshold))", value: "\(lowCount)", hint: "需及时充值", color: .red)
            statCard(title: "拉闸", value: "\(offCount)", hint: "已断电", color: .orange)
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }

    private func statCard(title: String, value: String, hint: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(.themeText3)
            Text(value)
                .font(.system(size: 23, weight: .heavy, design: .rounded))
                .foregroundColor(color)
                .contentTransition(.numericText())
            Text(hint)
                .font(.system(size: 10))
                .foregroundColor(.themeText3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.themeBorder, lineWidth: 1))
    }

    private var lowCount: Int {
        store.meters.filter { $0.isLow(threshold: threshold) }.count
    }
    private var offCount: Int {
        store.meters.filter { $0.isOff }.count
    }

    // MARK: - 工具行

    private var toolRow: some View {
        HStack(spacing: 8) {
            Button { showSort = true } label: {
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

            Button { showFilter = true } label: {
                HStack(spacing: 4) {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 11, weight: .semibold))
                    Text(filterMode == .low ? "低于 \(Int(threshold)) 度" : (filterMode == .off ? "拉闸" : "筛选"))
                        .font(.system(size: 13))
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(Color.white)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(filterMode == .all ? Color.themeBorder : Color.red.opacity(0.4), lineWidth: 1))
            }
            .buttonStyle(.plain)

            Spacer()
            Text("全部 \(store.meters.count)")
                .font(.system(size: 13))
                .foregroundColor(.themeText3)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(Color.white)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color.themeBorder, lineWidth: 1))
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    // MARK: - 电表列表（三行卡片）

    private var filteredMeters: [MeterLedger] {
        var arr = store.meters
        switch filterMode {
        case .all: break
        case .low: arr = arr.filter { $0.isLow(threshold: threshold) }
        case .off: arr = arr.filter { $0.isOff }
        }
        switch sortMode {
        case .balAsc: arr.sort { $0.shengyu < $1.shengyu }
        case .balDesc: arr.sort { $0.shengyu > $1.shengyu }
        case .usageDesc: arr.sort { $0.leiji > $1.leiji }
        case .roomAsc: arr.sort { ($0.room.isEmpty ? $0.uid : $0.room) < ($1.room.isEmpty ? $1.uid : $1.room) }
        }
        return arr
    }

    private var meterList: some View {
        LazyVStack(spacing: 8) {
            if filteredMeters.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bolt.slash")
                        .font(.system(size: 36))
                        .foregroundColor(.themeText3)
                    Text("没有符合条件的电表")
                        .font(.system(size: 14))
                        .foregroundColor(.themeText3)
                    Text("可点右上角 + 进入电表管理，或先刷新拉取绑定")
                        .font(.system(size: 12))
                        .foregroundColor(.themeText3.opacity(0.8))
                }
                .padding(.top, 60)
            } else {
                ForEach(filteredMeters) { meter in
                    MeterCardRow(meter: meter, threshold: threshold) { action in
                        handleCardAction(action, meter: meter)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .animation(.easeOut(duration: 0.18), value: sortMode)
        .animation(.easeOut(duration: 0.18), value: filterMode)
    }

    private func handleCardAction(_ action: MeterCardAction, meter: MeterLedger) {
        switch action {
        case .pay:
            // 充值：App 内打开官方充值页（支付步骤跳微信），不实现任何充值代码
            if let url = meterPayURL(uid: meter.uid) {
                UIApplication.shared.open(url)
            }
        case .records:
            selectedMeter = meter
        case .refresh:
            Task { await refreshOne(meter) }
        }
    }

    // MARK: - 刷新

    private func autoRefreshOnEnter() {
        // 进入板块自动刷新：首次进入（无数据）或本地无最近成功刷新记录时触发
        if store.meters.isEmpty || store.meters.allSatisfy({ $0.lastRefresh == nil }) {
            Task { await refreshAll() }
        }
    }

    private func refreshAll() async {
        guard !refreshing else { return }
        guard !store.meters.isEmpty else {
            // 清单为空：尝试一键拉取绑定
            do {
                let bindings = try await MeterQueryService.shared.fetchBindings(store: store)
                store.importBindings(bindings)
            } catch {
                errorText = error.localizedDescription
            }
            return
        }
        refreshing = true
        refreshProgress = 0
        refreshTotal = store.meters.count
        defer { refreshing = false }
        do {
            let ok = try await MeterQueryService.shared.refreshAll(store: store) { done, total, label in
                refreshProgress = done
                refreshTotal = total
                refreshLabel = label
            }
            if ok > 0 {
                // 刷新完成（静默成功，靠卡片数据变化呈现）
            }
        } catch {
            errorText = "刷新失败：\(error.localizedDescription)"
        }
    }

    private func refreshOne(_ meter: MeterLedger) async {
        do {
            let result = try await MeterQueryService.shared.query(store: store, uid: meter.uid)
            store.applyQueryResult(uid: meter.uid, result: result)
        } catch {
            errorText = "刷新 \(meter.room.isEmpty ? meter.uid : meter.room) 失败：\(error.localizedDescription)"
        }
    }

    private func meterPayURL(uid: String) -> URL? {
        // 官方充值页：meterpay?wechatUserOpenid=openId&meterId=uid（支付步骤跳微信）
        let openId = store.settings.openId
        guard !openId.isEmpty else { return nil }
        return URL(string: "http://wy.mlh-china.com/electricmeter/pages/meterlist/meterpay?wechatUserOpenid=\(openId)&meterId=\(uid)")
    }
}

// MARK: - 卡片行

enum MeterCardAction {
    case pay, records, refresh
}

struct MeterCardRow: View {
    let meter: MeterLedger
    let threshold: Double
    let onAction: (MeterCardAction) -> Void

    private var isLow: Bool { meter.isLow(threshold: threshold) }
    private var isOff: Bool { meter.isOff }
    private var warn: Bool { isLow || isOff }

    var body: some View {
        VStack(spacing: 0) {
            // 第一行：户号（稍大）+ 房号备注 + 状态徽章
            HStack(spacing: 7) {
                Text(meter.uid)
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
                if !meter.room.isEmpty {
                    Text(meter.room)
                        .font(.system(size: 12))
                        .foregroundColor(warn ? .red : .themeText3)
                }
                Spacer()
                badge
            }
            // 第二行：剩余电量 + 累计抄表 + 记录/充值（记录左、充值右）
            HStack(spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(String(format: "%.2f", meter.shengyu))
                        .font(.system(size: 26, weight: .heavy, design: .rounded))
                        .foregroundColor(warn ? .red : .themeText)
                        .contentTransition(.numericText())
                    Text("度")
                        .font(.system(size: 11))
                        .foregroundColor(.themeText3)
                }
                Text("累计 \(String(format: "%.2f", meter.leiji)) 度 · 抄表 \(shortTime(meter.shijian))")
                    .font(.system(size: 11))
                    .foregroundColor(.themeText3)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    miniButton("记录", icon: "list.bullet.rectangle") { onAction(.records) }
                    miniButton("充值", icon: "creditcard.fill", filled: true) { onAction(.pay) }
                }
            }
            .padding(.top, 7)
            // 第三行：抄表时间 + 单独刷新
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 10))
                    Text("抄表 \(fullTime(meter.shijian))")
                        .font(.system(size: 11))
                }
                .foregroundColor(Color.themeText3.opacity(0.7))
                .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    onAction(.refresh)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                        Text("刷新")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 13)
                    .padding(.vertical, 6)
                    .background(Color.themeAccent.opacity(0.08))
                    .foregroundColor(.themeAccentDark)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 7)
        }
        .padding(10)
        .background(warn ? LinearGradient(colors: [.white, Color.red.opacity(0.05)], startPoint: .top, endPoint: .bottom) : LinearGradient(colors: [.white, .white], startPoint: .top, endPoint: .bottom))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(warn ? Color.red.opacity(0.35) : Color.themeBorder, lineWidth: 1))
    }

    private var badge: some View {
        Text(isOff ? "拉闸" : (isLow ? "低电量" : "合闸"))
            .font(.system(size: 10.5, weight: .bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(isOff || isLow ? Color.red.opacity(0.12) : Color.themeAccent.opacity(0.12))
            .foregroundColor(isOff || isLow ? .red : .themeAccentDark)
            .clipShape(Capsule())
    }

    private func miniButton(_ title: String, icon: String, filled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(filled ? Color.themeAccentDark : Color.white)
            .foregroundColor(filled ? .white : .themeText)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(filled ? Color.clear : Color.themeBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func shortTime(_ raw: String) -> String {
        guard raw.count >= 16 else { return raw }
        return String(raw[raw.index(raw.startIndex, offsetBy: 11)..<raw.index(raw.startIndex, offsetBy: 16)])
    }
    private func fullTime(_ raw: String) -> String {
        guard raw.count >= 16 else { return raw.isEmpty ? "--" : raw }
        let start = raw.index(raw.startIndex, offsetBy: 5)
        return String(raw[start...])
    }
}

// MARK: - 排序 / 筛选 / 添加 / 导出面板

enum MeterSortMode: String, CaseIterable {
    case balAsc, balDesc, usageDesc, roomAsc
    var label: String {
        switch self {
        case .balAsc: return "剩余低→高"
        case .balDesc: return "剩余高→低"
        case .usageDesc: return "累计用量"
        case .roomAsc: return "房号升序"
        }
    }
}

enum MeterFilterMode: String, CaseIterable {
    case all, low, off
}

struct MeterSortSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var mode: MeterSortMode

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(Color.themeBorder).frame(width: 40, height: 4).padding(.top, 10)
            Text("排序方式")
                .font(.system(size: 16, weight: .bold))
                .padding(.top, 12)
                .padding(.bottom, 8)
            ForEach(MeterSortMode.allCases, id: \.self) { m in
                Button {
                    mode = m
                    dismiss()
                } label: {
                    HStack {
                        Text(m.label)
                            .font(.system(size: 15, weight: mode == m ? .bold : .regular))
                            .foregroundColor(mode == m ? .themeAccentDark : .themeText)
                        Spacer()
                        if mode == m {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.themeAccentDark)
                        }
                    }
                    .padding(.vertical, 13)
                    .padding(.horizontal, 4)
                }
                .buttonStyle(.plain)
                Divider().padding(.leading, 4)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .presentationDetents([.height(260)])
        .presentationDragIndicator(.visible)
    }
}

struct MeterFilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var mode: MeterFilterMode
    @Binding var threshold: Double

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(Color.themeBorder).frame(width: 40, height: 4).padding(.top, 10)
            Text("筛选电表")
                .font(.system(size: 16, weight: .bold))
                .padding(.top, 12)
                .padding(.bottom, 8)
            filterRow("显示全部", detail: "全部电表", target: .all)
            Divider().padding(.leading, 4)
            HStack {
                Button { mode = .low } label: {
                    HStack {
                        Text("只看低电量")
                            .font(.system(size: 15, weight: mode == .low ? .bold : .regular))
                            .foregroundColor(mode == .low ? .themeAccentDark : .themeText)
                        Spacer()
                        if mode == .low { Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundColor(.themeAccentDark) }
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                HStack(spacing: 2) {
                    Text("低于")
                        .font(.system(size: 13))
                        .foregroundColor(.themeText3)
                    TextField("30", value: $threshold, format: .number)
                        .keyboardType(.decimalPad)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.red)
                        .frame(width: 44)
                        .multilineTextAlignment(.center)
                        .padding(6)
                        .background(Color.red.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    Text("度")
                        .font(.system(size: 13))
                        .foregroundColor(.themeText3)
                }
            }
            .padding(.vertical, 13)
            Divider().padding(.leading, 4)
            filterRow("只看拉闸", detail: "已断电电表", target: .off)
            Spacer()
            Button("完成") { dismiss() }
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(Color.themeAccentDark)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.top, 8)
        }
        .padding(.horizontal, 16)
        .presentationDetents([.height(330)])
        .presentationDragIndicator(.visible)
    }

    private func filterRow(_ title: String, detail: String, target: MeterFilterMode) -> some View {
        Button {
            mode = target
        } label: {
            HStack {
                Text(title)
                    .font(.system(size: 15, weight: mode == target ? .bold : .regular))
                    .foregroundColor(mode == target ? .themeAccentDark : .themeText)
                Spacer()
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundColor(.themeText3)
                if mode == target {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.themeAccentDark)
                }
            }
            .padding(.vertical, 13)
            .padding(.horizontal, 4)
        }
        .buttonStyle(.plain)
    }
}

struct MeterAddSheet: View {
    @EnvironmentObject private var store: MeterStore
    @Environment(\.dismiss) private var dismiss
    @State private var uid = ""
    @State private var room = ""
    @State private var toast: String?

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(Color.themeBorder).frame(width: 40, height: 4).padding(.top, 10)
            Text("添加电表")
                .font(.system(size: 16, weight: .bold))
                .padding(.top, 12)
            VStack(alignment: .leading, spacing: 6) {
                Text("电表用户号")
                    .font(.system(size: 13))
                    .foregroundColor(.themeText3)
                TextField("如 012348", text: $uid)
                    .keyboardType(.numberPad)
                    .padding(12)
                    .background(Color.themeBorder.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .font(.system(size: 16))
                Text("备注房号（选填）")
                    .font(.system(size: 13))
                    .foregroundColor(.themeText3)
                TextField("如 1座2334上", text: $room)
                    .padding(12)
                    .background(Color.themeBorder.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .font(.system(size: 16))
            }
            .padding(.top, 14)
            HStack(spacing: 8) {
                Button("取消") { dismiss() }
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Color.themeBorder.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                Button("添加") {
                    let u = uid.trimmingCharacters(in: .whitespaces)
                    guard !u.isEmpty else { toast = "请输入电表用户号"; return }
                    guard !store.meters.contains(where: { $0.uid == u }) else {
                        toast = "该电表已存在：\(u)"
                        return
                    }
                    store.upsert(MeterLedger(uid: u, room: room.trimmingCharacters(in: .whitespaces)))
                    dismiss()
                }
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(Color.themeAccentDark)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.top, 16)
            Spacer()
        }
        .padding(.horizontal, 16)
        .presentationDetents([.height(330)])
        .presentationDragIndicator(.visible)
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
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                            withAnimation { self.toast = nil }
                        }
                    }
            }
        }
    }
}
