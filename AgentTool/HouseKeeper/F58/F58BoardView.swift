//
//  F58BoardView.swift
//  公寓管家 · 房源排名看板（v2.2 b109）
//  功能：双 tab——「58找房」读取 58 顺德站租房列表第一页（约 40 条）→ 标题/缩略图/价格/经纪人（详情页补抓）
//        「安居客」读取安居客前台找房页（fs.zu.anjuke.com 等）；顶栏按经纪人展示房源数量排名
//  安全：只读展示，不做任何写操作；抓取仅在用户主动点击时执行；只抓第一页
//

import SwiftUI
import UIKit
import WebKit
import SafariServices

// MARK: - 主界面

struct F58BoardView: View {
    @EnvironmentObject private var store: F58Store
    @Environment(\.dismiss) private var dismiss

    @State private var tab: F58BoardTab = .f58
    @State private var refreshing = false
    @State private var errorText: String?
    @State private var toastText: String?
    @State private var showSettings = false
    @State private var sortMode: F58SortMode = .defaultOrder
    @State private var onlyWithCover = false
    @State private var selectedHouse: F58House?

    enum F58BoardTab: String, CaseIterable, Identifiable {
        case f58 = "58找房"
        case ajk = "安居客"
        var id: String { rawValue }
    }

    var body: some View {
        ZStack {
            Color.themePanel.ignoresSafeArea()
            VStack(spacing: 0) {
                navBar
                tabPicker
                if tab == .f58 {
                    f58Body
                } else {
                    AjkPublicView()
                        .environmentObject(AjkPublicStore.shared)
                }
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
        .sheet(isPresented: $showSettings) {
            F58SettingsDetailView()
        }
        .alert("提示", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("好", role: .cancel) { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
        .navigationDestination(isPresented: Binding(get: { selectedHouse != nil }, set: { if !$0 { selectedHouse = nil } })) {
            if let h = selectedHouse { F58DetailWebView(house: h) }
        }
    }

    private var tabPicker: some View {
        Picker("", selection: $tab) {
            ForEach(F58BoardTab.allCases) { t in
                Text(t.rawValue).tag(t)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.themePanel)
    }

    /// 58 tab 主体（原有列表逻辑）
    private var f58Body: some View {
        VStack(spacing: 0) {
            if refreshing { progressBar }
            ScrollView {
                VStack(spacing: 0) {
                    overviewCard
                    toolRow
                    houseList
                }
                .padding(.bottom, 30)
            }
            .refreshable { await fetch() }
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
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 34, height: 34)
                        .background(Color.white.opacity(0.16))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text("房源排名")
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
        let kw = store.settings.keyword.isEmpty ? "关键词" : store.settings.keyword
        if let t = store.lastFetch {
            let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"
            return "\(kw)｜上次抓取 \(f.string(from: t))｜共 \(store.houses.count) 套"
        }
        return "\(kw)｜点「读取」抓取 58 第一页约 40 套"
    }

    private var progressBar: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            if let p = store.detailProgress {
                Text("正在补抓经纪人 \(p.current)/\(p.total)…")
                    .font(.system(size: 12))
            } else {
                Text("正在读取 58 列表页…")
                    .font(.system(size: 12))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color.themeAccent.opacity(0.08))
    }

    // MARK: - 概览（v2.2：删均价/广告位，改按经纪人展示房源数量排名）

    private var overviewCard: some View {
        let o = store.overview
        return VStack(spacing: 10) {
            HStack(spacing: 0) {
                statItem(value: "\(o.count)", label: "房源(套)")
                statItem(value: "\(o.agentCount)", label: "经纪人(位)")
                statItem(value: "\(o.agentRank.count)", label: "上榜经纪人")
            }
            // 按经纪人展示房源数量排名（Top 5）
            if !o.agentRank.isEmpty {
                VStack(spacing: 4) {
                    ForEach(Array(o.agentRank.prefix(5).enumerated()), id: \.offset) { idx, rank in
                        HStack(spacing: 8) {
                            Text("\(idx + 1)")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 20, height: 20)
                                .background(idx == 0 ? Color.themeAmber : Color.themeAccentDark)
                                .clipShape(Circle())
                            Text(rank.name)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.themeText)
                                .lineLimit(1)
                            Spacer()
                            Text("\(rank.count)套")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.themeAccentDark)
                        }
                        .padding(.horizontal, 14)
                    }
                }
                .padding(.top, 2)
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

    // MARK: - 工具行

    private var toolRow: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(F58SortMode.allCases, id: \.self) { mode in
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
                Divider()
                Button {
                    onlyWithCover.toggle()
                } label: {
                    if onlyWithCover {
                        Label("只看带实拍图", systemImage: "checkmark")
                    } else {
                        Text("只看带实拍图")
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 11))
                    Text(onlyWithCover ? "带图 · \(sortMode.label)" : sortMode.label)
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.themeBorder.opacity(0.4))
                .clipShape(Capsule())
            }
            Spacer()
            if store.lastFetch == nil {
                Text("首次使用点右上角「读取」")
                    .font(.system(size: 11))
                    .foregroundColor(.themeText3)
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
                    Image(systemName: "house.lodge")
                        .font(.system(size: 40))
                        .foregroundColor(.themeText3)
                    Text("还没有房源数据")
                        .font(.system(size: 14, weight: .medium))
                    Text("点右上角「读取」抓取 58 列表第一页\n标题/缩略图/价格/位置，点卡片看详情")
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
                    Button {
                        selectedHouse = house
                    } label: {
                        F58HouseCard(house: house)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal)
                Text("共 \(list.count) 套（每次只抓第一页）")
                    .font(.system(size: 11))
                    .foregroundColor(.themeText3)
                    .padding(.top, 4)
            }
        }
    }

    private var filteredList: [F58House] {
        var list = store.houses
        if onlyWithCover {
            list = list.filter { !$0.coverURL.isEmpty }
        }
        switch sortMode {
        case .defaultOrder: break
        case .priceAsc:  list.sort { ($0.priceValue ?? .max) < ($1.priceValue ?? .max) }
        case .priceDesc: list.sort { ($0.priceValue ?? .min) > ($1.priceValue ?? .min) }
        case .agent:     list.sort { $0.agent < $1.agent }
        }
        return list
    }

    // MARK: - 抓取（v2.2：走 store，含详情页经纪人补抓进度）

    private func fetch() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        await store.fetch()
        if let err = store.lastError {
            errorText = err
            return
        }
        if !store.houses.isEmpty {
            showToast("已读取 \(store.houses.count) 套房源")
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

enum F58SortMode: String, CaseIterable {
    case defaultOrder, priceAsc, priceDesc, agent
    var label: String {
        switch self {
        case .defaultOrder: return "默认顺序"
        case .priceAsc: return "价格从低到高"
        case .priceDesc: return "价格从高到低"
        case .agent: return "按经纪人"
        }
    }
}

// MARK: - 房源卡片

struct F58HouseCard: View {
    let house: F58House

    var body: some View {
        let coverPath = F58Store.shared.coverLocalPath(for: house.infoid)
        return HStack(alignment: .top, spacing: 10) {
            // 缩略图 + 标签胶囊（左上角：安选 / 广告）
            ZStack(alignment: .topLeading) {
                if let cp = coverPath, let img = UIImage(contentsOfFile: cp) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 76, height: 76)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.themeBorder, lineWidth: 1))
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.themeBorder.opacity(0.25))
                            .frame(width: 76, height: 76)
                        Image(systemName: "photo")
                            .font(.system(size: 20))
                            .foregroundColor(.themeText3)
                    }
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.themeBorder, lineWidth: 1))
                }
                if !house.tip.isEmpty || !house.ad.isEmpty {
                    HStack(spacing: 3) {
                        if !house.tip.isEmpty {
                            Text(house.tip)
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1.5)
                                .background(Color.themeAccentDark)
                                .clipShape(Capsule())
                        }
                        if !house.ad.isEmpty {
                            Text(house.ad)
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1.5)
                                .background(Color.themeAmber)
                                .clipShape(Capsule())
                        }
                    }
                    .padding(2)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(house.title.isEmpty ? "（无标题）" : house.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.themeText)
                    .lineLimit(2)
                if !house.room.isEmpty || !house.loc.isEmpty {
                    Text([house.room, house.loc].filter { !$0.isEmpty }.joined(separator: " ｜ "))
                        .font(.system(size: 12))
                        .foregroundColor(.themeText2)
                        .lineLimit(1)
                }
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(house.price.isEmpty ? "—" : house.price)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.themeAccentDark)
                    Text("元/月")
                        .font(.system(size: 11))
                        .foregroundColor(.themeText3)
                    Spacer()
                    if !house.agent.isEmpty {
                        Text("来自经纪人：\(house.agent)")
                            .font(.system(size: 11))
                            .foregroundColor(.themeAmber)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.themeText3)
                .padding(.top, 2)
        }
        .padding(12)
        .background(Color.themePanel)
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.themeBorder, lineWidth: 1))
    }
}

// MARK: - 详情页（点卡片 = 浏览器点击该房源）

struct F58DetailWebView: View {
    let house: F58House
    @Environment(\.dismiss) private var dismiss
    @State private var canOpen = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
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
                        Text("房源详情")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white)
                        Text(house.title.isEmpty ? house.infoid : String(house.title.prefix(18)))
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.8))
                            .lineLimit(1)
                    }
                    Spacer()
                    Button {
                        if let url = URL(string: house.href) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Image(systemName: "safari")
                            .font(.system(size: 14))
                            .foregroundColor(.white)
                            .frame(width: 34, height: 34)
                            .background(Color.white.opacity(0.16))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(.horizontal, 12)
            }
            .frame(height: 62)
            if let url = URL(string: house.href) {
                F58DetailWKView(url: url)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 30))
                        .foregroundColor(.themeAmber)
                    Text("详情链接无效")
                        .font(.system(size: 13))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.themePanel)
            }
        }
        .navigationBarHidden(true)
    }
}

/// 详情 WebView（桌面 UA + 持久会话，等同浏览器打开该房源）
struct F58DetailWKView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.customUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        wv.load(URLRequest(url: url))
        return wv
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// MARK: - 设置

struct F58SettingsDetailView: View {
    @EnvironmentObject private var store: F58Store
    @Environment(\.dismiss) private var dismiss
    @State private var keywordText = ""
    @State private var urlText = ""
    @State private var ajkURLText = ""
    @State private var ajkKWText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("58找房 · 列表页 URL") {
                    TextField("58 租房列表页 URL", text: $urlText)
                        .font(.system(size: 13))
                        .autocapitalization(.none)
                        .keyboardType(.URL)
                    Text("默认：利保米兰公馆（m 站手机版）。URL 里的 key 参数决定抓取范围；带 reform=pcfront 会自动剥离（会丢关键词）。页面改版导致抓不到时可按官方新链接更换")
                        .font(.system(size: 11))
                        .foregroundColor(.themeText3)
                }
                Section("58找房 · 显示名称") {
                    TextField("关键词（如：利保米兰公馆）", text: $keywordText)
                        .font(.system(size: 13))
                    Text("仅用于页面标题显示，不影响抓取内容")
                        .font(.system(size: 11))
                        .foregroundColor(.themeText3)
                }
                Section("安居客 · 前台找房页 URL") {
                    TextField("安居客找房页 URL", text: $ajkURLText)
                        .font(.system(size: 13))
                        .autocapitalization(.none)
                        .keyboardType(.URL)
                    Text("默认：fs.zu.anjuke.com 精选页（利保米兰公馆）。在 App 内用手机 UA 打开抓取第一页；如页面弹验证码请稍后再试，或到手机上打开该链接确认可访问后更换")
                        .font(.system(size: 11))
                        .foregroundColor(.themeText3)
                }
                Section("安居客 · 显示名称") {
                    TextField("关键词（如：利保米兰公馆）", text: $ajkKWText)
                        .font(.system(size: 13))
                    Text("仅用于安居客页标题显示")
                        .font(.system(size: 11))
                        .foregroundColor(.themeText3)
                }
                Section {
                    Button("保存设置") {
                        var s = store.settings
                        let trimmedURL = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmedURL.isEmpty { s.baseURL = trimmedURL }
                        let trimmedKW = keywordText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmedKW.isEmpty { s.keyword = trimmedKW }
                        store.settings = s
                        store.saveSettings()
                        AjkPublicStore.shared.settingsURL = ajkURLText.trimmingCharacters(in: .whitespacesAndNewlines)
                        AjkPublicStore.shared.settingsKeyword = ajkKWText.trimmingCharacters(in: .whitespacesAndNewlines)
                        AjkPublicStore.shared.saveSettings()
                        dismiss()
                    }
                }
            }
            .navigationTitle("房源排名设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear {
                keywordText = store.settings.keyword
                urlText = store.settings.baseURL
                ajkURLText = AjkPublicStore.shared.settingsURL
                ajkKWText = AjkPublicStore.shared.settingsKeyword
            }
        }
    }
}
