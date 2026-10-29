//
//  AjkBoardView.swift
//  公寓管家 · 安居客经纪人后台数据看板（v1.85）
//  功能：登录态抓取 → 概览 + 房源列表（今日/累计点击、房态、已编辑）→ 实地核验/下架预警
//  安全：只读展示，不做任何写操作；抓取仅在用户主动点击时执行
//

import SwiftUI
import UIKit
import WebKit

// MARK: - 主界面

struct AjkBoardView: View {
    @EnvironmentObject private var store: AjkStore
    @Environment(\.dismiss) private var dismiss

    @State private var refreshing = false
    @State private var errorText: String?
    @State private var toastText: String?
    @State private var showLogin = false
    @State private var showSettings = false
    @State private var sortMode: AjkSortMode = .todayClick
    @State private var filterNeedInspect = false

    var body: some View {
        ZStack {
            Color.themePanel.ignoresSafeArea()
            VStack(spacing: 0) {
                navBar
                if refreshing { progressBar }
                // v1.92：取消头部固定——概览/预警/工具行回到 ScrollView 内整体滚动（用户验收后要求撤销 v1.91 的固定）
                ScrollView {
                    VStack(spacing: 0) {
                        overviewCard
                        warningCard
                        toolRow
                        houseList
                    }
                    .padding(.bottom, 30)
                }
                .refreshable { await fetch() }
            }
            if let t = toastText {
                VStack {
                    Spacer()
                    Text(t)
                        .font(.system(size: 13))
                        .foregroundColor(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.82))
                        .clipShape(Capsule())
                        .padding(.bottom, 24)
                }
                .transition(.opacity)
            }
        }
        .navigationBarHidden(true)
        .sheet(isPresented: $showLogin) {
            NavigationStack { AjkLoginView() }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack { AjkSettingsDetailView() }
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
            // v1.90：顶栏配色与 AI 助手/电表监控统一（深绿渐变 + 白色按钮），并整体缩窄
            LinearGradient(colors: [.themeAccentDark, .themeAccent], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
            HStack(spacing: 8) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 34, height: 34)
                        .background(Color.white.opacity(0.16))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text("安居客后台")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                    Text(subTitle)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.8))
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.white)
                        .frame(width: 34, height: 34)
                        .background(Color.white.opacity(0.16))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                Button {
                    Task { await fetch() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                        Text("读取")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(Color.white.opacity(0.18))
                    .clipShape(Capsule())
                }
                .disabled(refreshing)
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 62)
    }

    private var subTitle: String {
        if let t = store.lastFetch {
            let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"
            return "上次抓取 \(f.string(from: t))｜共 \(store.houses.count) 套"
        }
        return "登录后读取你的推广房源数据"
    }

    private var progressBar: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("正在读取页面数据…")
                .font(.system(size: 12))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color.themeAccent.opacity(0.08))
    }

    // MARK: - 概览

    private var overviewCard: some View {
        let o = store.overview
        return VStack(spacing: 10) {
            HStack(spacing: 0) {
                statItem(value: "\(o.todayClickTotal)", label: "今日点击")
                statItem(value: "\(o.promotedCount)", label: "推广房源")
                statItem(value: "\(o.portCount)", label: "剩余端口")
            }
            HStack(spacing: 0) {
                statItem(value: "\(o.packageDays)", label: "套餐剩余(天)")
                statItem(value: "\(o.score)", label: "神奇分")
                statItem(value: "\(o.coin)", label: "房产币")
            }
        }
        .padding(.vertical, 14)
        .background(Color.themePanel)
        .overlay(RoundedRectangle(cornerRadius: 0).stroke(Color.themeBorder, lineWidth: 0.5))
        .padding(.top, 8)
    }

    private func statItem(value: String, label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 19, weight: .bold))
                .foregroundColor(.themeAccentDark)
            Text(label)
                .font(.system(size: 10.5))
                .foregroundColor(.themeText3)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 预警区

    private var warningCard: some View {
        let inspect = store.needInspectHouses
        let removal = store.nearRemovalHouses
        let hasWarn = !inspect.isEmpty || !removal.isEmpty
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.themeAmber)
                Text("预警")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if !inspect.isEmpty || !removal.isEmpty {
                    Button {
                        withAnimation { filterNeedInspect.toggle() }
                    } label: {
                        Text(filterNeedInspect ? "显示全部" : "只看预警")
                            .font(.system(size: 11))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.themeBorder.opacity(0.5))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            if !hasWarn {
                Text("暂无预警：房态未达 \(store.settings.inspectThreshold) 天，已编辑未达 \(store.settings.removalThreshold) 天")
                    .font(.system(size: 12))
                    .foregroundColor(.themeText3)
            } else {
                if !inspect.isEmpty {
                    warningRow(icon: "house.fill", color: .red,
                               text: "\(inspect.count) 套房源房态 ≥ \(store.settings.inspectThreshold) 天，需实地核验",
                               detail: inspect.prefix(3).map { "\($0.number) 房态\($0.houseStateDays)天" }.joined(separator: "、"))
                }
                if !removal.isEmpty {
                    warningRow(icon: "clock.fill", color: .themeAmber,
                               text: "\(removal.count) 套房源已编辑 ≥ \(store.settings.removalThreshold) 天，将自动下架",
                               detail: removal.prefix(3).map { "\($0.number) 已编辑\($0.editedDays)天" }.joined(separator: "、"))
                }
            }
        }
        .padding(12)
        .background(Color.themePanel)
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.themeBorder, lineWidth: 1))
        .padding(.horizontal)
        .padding(.top, 10)
    }

    private func warningRow(icon: String, color: Color, text: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(color)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.themeText)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(.themeText3)
            }
        }
    }

    // MARK: - 工具行

    private var toolRow: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(AjkSortMode.allCases, id: \.self) { mode in
                    Button {
                        sortMode = mode
                    } label: {
                        if sortMode == mode {
                            Label(mode.label, systemImage: "checkmark")
                        } else {
                            Text(mode.label)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 11))
                    Text(sortMode.label)
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.themeBorder.opacity(0.4))
                .clipShape(Capsule())
            }
            Spacer()
            if store.lastFetch == nil {
                Button {
                    showLogin = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "person.badge.key.fill")
                            .font(.system(size: 11))
                        Text("登录后台")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.themeAccent.opacity(0.12))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - 房源列表

    private var houseList: some View {
        let list = filteredList
        return VStack(spacing: 10) {
            if store.houses.isEmpty && !refreshing {
                VStack(spacing: 10) {
                    Image(systemName: "building.2")
                        .font(.system(size: 40))
                        .foregroundColor(.themeText3)
                    Text("还没有房源数据")
                        .font(.system(size: 14, weight: .medium))
                    Text("点右上角「读取」抓取你的安居客推广房源\n首次使用先「登录后台」一次")
                        .font(.system(size: 12))
                        .foregroundColor(.themeText3)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 60)
            } else if list.isEmpty {
                Text("没有匹配的房源")
                    .font(.system(size: 13))
                    .foregroundColor(.themeText3)
                    .padding(.top, 30)
            } else {
                ForEach(list) { house in
                    AjkHouseCard(house: house, settings: store.settings, delta: store.clickDelta(house: house))
                }
                .padding(.horizontal)
            }
        }
    }

    private var filteredList: [AjkHouse] {
        var list = store.houses
        if filterNeedInspect {
            let inspectSet = Set(store.needInspectHouses.map { $0.id })
            let removalSet = Set(store.nearRemovalHouses.map { $0.id })
            list = list.filter { inspectSet.contains($0.id) || removalSet.contains($0.id) }
        }
        switch sortMode {
        case .todayClick: list.sort { $0.todayClick != $1.todayClick ? $0.todayClick > $1.todayClick : $0.totalClick > $1.totalClick }
        case .totalClick: list.sort { $0.totalClick > $1.totalClick }
        case .stateDays:  list.sort { $0.houseStateDays > $1.houseStateDays }
        case .editedDays: list.sort { $0.editedDays > $1.editedDays }
        }
        return list
    }

    // MARK: - 抓取

    private func fetch() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let result = try await AjkWebViewProvider.shared.fetchAll(maxPages: store.settings.maxPages)
            if result.needLogin {
                errorText = "未能读取到房源数据。请先点「登录后台」完成一次登录，再回来点「读取」。"
                return
            }
            if !result.error.isEmpty {
                errorText = result.error
                return
            }
            if result.houses.isEmpty {
                errorText = "没有抓取到房源，请检查后台页面是否正常，或稍后重试。"
                return
            }
            store.applyFetch(houses: result.houses, overview: result.overview)
            showToast("已读取 \(result.houses.count) 套房源")
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func showToast(_ msg: String) {
        toastText = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation { self.toastText = nil }
        }
    }
}

// MARK: - 排序模式

enum AjkSortMode: String, CaseIterable {
    case todayClick, totalClick, stateDays, editedDays
    var label: String {
        switch self {
        case .todayClick: return "今日点击"
        case .totalClick: return "累计点击"
        case .stateDays: return "房态天数"
        case .editedDays: return "已编辑天数"
        }
    }
}

// MARK: - 房源卡片

struct AjkHouseCard: View {
    let house: AjkHouse
    let settings: AjkSettings
    let delta: Int

    var body: some View {
        // v1.90：封面图（本地已下载才显示；无封面走占位）
        let coverPath = AjkStore.shared.coverLocalPath(for: house.number)
        // v1.91：显示裁剪——小区去掉「顺德-龙江，」前缀只留小区名；面积不显示；核验只显示「核验成功」
        let communityShort = house.community.components(separatedBy: "，").last ?? house.community
        let verifiedShort = house.verified.components(separatedBy: "·").last ?? house.verified
        // v1.91：推广合并显示——58与安居客推广同步，只显示最高推广类型（精选 > 普通推广）
        let promoDisplay: String = {
            var types: [String] = []
            for g in house.promotions {
                let parts = g.components(separatedBy: "·")
                if parts.count >= 2 { types.append(contentsOf: parts.dropFirst()) }
            }
            if types.contains("精选") { return "精选" }
            if types.contains("普通推广") { return "普通推广" }
            return types.first ?? ""
        }()
        return HStack(alignment: .top, spacing: 10) {
            // v1.91：封面 + 推广状态胶囊（左上角）
            ZStack(alignment: .topLeading) {
                if let cp = coverPath, let img = UIImage(contentsOfFile: cp) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 62, height: 62)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.themeBorder, lineWidth: 1))
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.themeBorder.opacity(0.25))
                            .frame(width: 62, height: 62)
                        Image(systemName: "house")
                            .font(.system(size: 20))
                            .foregroundColor(.themeText3)
                    }
                }
                if !promoDisplay.isEmpty {
                    Text(promoDisplay)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1.5)
                        .background(Color.themeAccentDark)
                        .clipShape(Capsule())
                        .padding(2)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 6) {
                    Text(house.title.isEmpty ? "（无标题）" : house.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.themeText)
                        .lineLimit(2)
                    Spacer()
                    if !house.quality.isEmpty {
                        tag(house.quality, color: house.quality == "高" ? .themeAccentDark : .themeAmber)
                    }
                }
                Text("\(communityShort) · \(house.layout) \(house.floor) \(house.price)")
                    .font(.system(size: 12))
                    .foregroundColor(.themeText2)
                    .lineLimit(1)

                HStack(spacing: 10) {
                    Text("编号 \(house.number)")
                        .font(.system(size: 11))
                        .foregroundColor(.themeText3)
                    Spacer()
                    if house.houseStateDays >= settings.inspectThreshold {
                        Text("房态\(house.houseStateDays)天·需核验")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.red)
                    } else {
                        Text("房态\(house.houseStateDays)天")
                            .font(.system(size: 11))
                            .foregroundColor(.themeText3)
                    }
                    if house.editedDays >= settings.removalThreshold {
                        Text("已编辑\(house.editedDays)天·将下架")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.red)
                    } else {
                        Text("已编辑\(house.editedDays)天")
                            .font(.system(size: 11))
                            .foregroundColor(.themeText3)
                    }
                }

                // 点击量：左今日 / 右累计（v1.91 恢复显示）+ 较上次变化 + 平台与维护人
                HStack(spacing: 10) {
                    HStack(spacing: 3) {
                        Text("\(house.todayClick)")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.themeAccentDark)
                        Text("/")
                            .font(.system(size: 12))
                            .foregroundColor(.themeText3)
                        Text("\(house.totalClick)")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.themeText2)
                    }
                    if delta > 0 {
                        Text("较上次 +\(delta)")
                            .font(.system(size: 10))
                            .foregroundColor(.themeAccentDark)
                    } else if delta < 0 {
                        Text("较上次 \(delta)")
                            .font(.system(size: 10))
                            .foregroundColor(.red)
                    }
                    Spacer()
                    ForEach(house.platforms, id: \.self) { p in
                        Text(p)
                            .font(.system(size: 10))
                            .foregroundColor(.themeBlue)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.themeBlue.opacity(0.1))
                            .clipShape(Capsule())
                    }
                    if !house.maintainer.isEmpty {
                        Text(house.maintainer)
                            .font(.system(size: 10))
                            .foregroundColor(.themeAmber)
                    }
                }

                HStack(spacing: 10) {
                    if !verifiedShort.isEmpty {
                        Text(verifiedShort)
                            .font(.system(size: 10))
                            .foregroundColor(.themeText2)
                    }
                    if !house.video.isEmpty {
                        Text(house.video)
                            .font(.system(size: 10))
                            .foregroundColor(.themeText2)
                    }
                    // v1.91：推广状态已移到封面左上角胶囊，此处不再重复显示
                }
            }
        }
        .padding(12)
        .background(Color.themePanel)
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.themeBorder, lineWidth: 1))
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.1))
            .clipShape(Capsule())
    }
}

// MARK: - 登录视图（WebView 持久会话，用户自行登录）

struct AjkLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var webView: WKWebView?
    @State private var loadedURL = ""

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                // v1.90：登录页顶栏与 AI/电表统一（深绿渐变 + 白色按钮），同步缩窄
                LinearGradient(colors: [.themeAccentDark, .themeAccent], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea(edges: .top)
                HStack(spacing: 8) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 32, height: 32)
                            .background(Color.white.opacity(0.16))
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text("登录安居客后台")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white)
                        Text("账号/扫码登录后，返回点「读取」即可抓取数据")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.8))
                    }
                    Spacer()
                    Button("完成") { dismiss() }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 12)
            }
            .frame(height: 62)
            AjkLoginWebView(url: URL(string: AjkStore.shared.settings.baseURL) ?? URL(string: "https://vip.anjuke.com/zufang/main/zufang/subpages/allHouse")!)
        }
        .navigationBarHidden(true)
    }
}

/// 登录用 WebView（持久 cookie；与抓取共用默认 dataStore）
struct AjkLoginWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.load(URLRequest(url: url))
        return wv
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// MARK: - 设置

struct AjkSettingsDetailView: View {
    @EnvironmentObject private var store: AjkStore
    @Environment(\.dismiss) private var dismiss
    @State private var urlText = ""
    @State private var inspect = 7
    @State private var removal = 90
    @State private var maxPages = 5
    @State private var saveSnap = true

    var body: some View {
        NavigationStack {
            Form {
                Section("数据来源") {
                    TextField("安居客房源列表页 URL", text: $urlText)
                        .font(.system(size: 13))
                        .autocapitalization(.none)
                        .keyboardType(.URL)
                    Text("一般无需修改；页面改版导致抓取失败时可按官方新链接更换")
                        .font(.system(size: 11))
                        .foregroundColor(.themeText3)
                }
                Section("预警阈值") {
                    Stepper(value: $inspect, in: 1...90) {
                        Text("实地核验预警：房态 ≥ \(inspect) 天")
                    }
                    Stepper(value: $removal, in: 30...180) {
                        Text("下架预警：已编辑 ≥ \(removal) 天")
                    }
                }
                Section("抓取") {
                    Stepper(value: $maxPages, in: 1...20) {
                        Text("最大翻页数：\(maxPages) 页")
                    }
                    Toggle("保存历史快照（点击趋势对比）", isOn: $saveSnap)
                }
                Section {
                    Button("保存设置") {
                        var s = store.settings
                        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { s.baseURL = trimmed }
                        s.inspectThreshold = inspect
                        s.removalThreshold = removal
                        s.maxPages = maxPages
                        s.saveSnapshots = saveSnap
                        store.settings = s
                        store.saveSettings()
                        dismiss()
                    }
                }
            }
            .navigationTitle("安居客设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear {
                urlText = store.settings.baseURL
                inspect = store.settings.inspectThreshold
                removal = store.settings.removalThreshold
                maxPages = store.settings.maxPages
                saveSnap = store.settings.saveSnapshots
            }
        }
    }
}
