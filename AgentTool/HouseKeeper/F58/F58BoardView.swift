//
//  F58BoardView.swift
//  公寓管家 · 58同城找房数据看板（v1.99 b105）
//  功能：读取 58 顺德站租房列表第一页（约 40 条）→ 标题/缩略图/价格/经纪人 → 点卡片跳对应详情页
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

    @State private var refreshing = false
    @State private var errorText: String?
    @State private var toastText: String?
    @State private var showSettings = false
    @State private var sortMode: F58SortMode = .defaultOrder
    @State private var onlyWithCover = false
    @State private var selectedHouse: F58House?

    var body: some View {
        ZStack {
            Color.themePanel.ignoresSafeArea()
            VStack(spacing: 0) {
                navBar
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
                    Text("58同城找房")
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
        return "\(kw)｜点「读取」抓第一页约 40 套"
    }

    private var progressBar: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("正在读取 58 列表页…")
                .font(.system(size: 12))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color.themeAccent.opacity(0.08))
    }

    // MARK: - 概览（本次数据现算）

    private var overviewCard: some View {
        let o = store.overview
        return VStack(spacing: 10) {
            HStack(spacing: 0) {
                statItem(value: "\(o.count)", label: "房源(套)")
                statItem(value: "\(o.agentCount)", label: "经纪人(位)")
                statItem(value: o.avgPrice > 0 ? "\(o.avgPrice)" : "—", label: "均价(元/月)")
            }
            HStack(spacing: 0) {
                statItem(value: o.minPrice > 0 ? "\(o.minPrice)" : "—", label: "最低(元/月)")
                statItem(value: o.maxPrice > 0 ? "\(o.maxPrice)" : "—", label: "最高(元/月)")
                statItem(value: "\(o.adCount)", label: "广告位")
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

    // MARK: - 抓取

    private func fetch() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let result = try await F58WebViewProvider.shared.fetchFirstPage(urlString: store.settings.baseURL)
            if result.needCaptcha {
                errorText = "58 弹出了验证码校验。请稍后重试；若反复出现，可到设置里核对列表页链接是否正常。"
                return
            }
            if !result.error.isEmpty {
                errorText = result.error
                return
            }
            if result.houses.isEmpty {
                errorText = "没有抓取到房源，请检查列表页链接是否正常，或稍后重试。"
                return
            }
            store.applyFetch(houses: result.houses)
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

    var body: some View {
        NavigationStack {
            Form {
                Section("列表页 URL") {
                    TextField("58 租房列表页 URL", text: $urlText)
                        .font(.system(size: 13))
                        .autocapitalization(.none)
                        .keyboardType(.URL)
                    Text("默认：利保米兰公馆（m 站手机版）。URL 里的 key 参数决定抓取范围；带 reform=pcfront 会自动剥离（会丢关键词）。页面改版导致抓不到时可按官方新链接更换")
                        .font(.system(size: 11))
                        .foregroundColor(.themeText3)
                }
                Section("显示名称") {
                    TextField("关键词（如：利保米兰公馆）", text: $keywordText)
                        .font(.system(size: 13))
                    Text("仅用于页面标题显示，不影响抓取内容")
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
                        dismiss()
                    }
                }
            }
            .navigationTitle("58找房设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear {
                keywordText = store.settings.keyword
                urlText = store.settings.baseURL
            }
        }
    }
}
