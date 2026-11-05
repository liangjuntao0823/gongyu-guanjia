//
//  AjkPublicView.swift
//  公寓管家 · 安居客前台找房 tab（v2.17 b138 与 58 抓取板块对齐）
//  功能：读取安居客找房页 → 概览（套数/均价/最高）→ 排序（默认/价格升/价格降）+ 只看带实拍图
//        → 卡片（缩略图/标签/标题/户型面积/区域小区/租金/楼层）→ 点卡片站内看详情
//        → 下拉刷新；遇到验证码弹出可交互页面，用户手动过验证后继续读取
//  安全：只读展示；仅用户主动点击读取。
//

import SwiftUI
import UIKit
import WebKit

struct AjkPublicView: View {
    @EnvironmentObject private var store: AjkPublicStore
    @State private var sortMode: AjkSortMode = .defaultOrder
    @State private var onlyWithCover = false
    @State private var selectedHouse: AjkPublicHouse?
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            if store.loading { progressBar }
            ScrollView {
                VStack(spacing: 0) {
                    overviewCard
                    toolRow
                    houseList
                }
                .padding(.bottom, 30)
            }
            .refreshable { await store.fetch() }
        }
        .sheet(isPresented: Binding(
            get: { store.needVerify },
            set: { newValue in if !newValue { store.needVerify = false } }
        )) {
            AjkVerifySheet()
                .environmentObject(store)
        }
        .alert("提示", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("好", role: .cancel) { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
        .navigationDestination(isPresented: Binding(get: { selectedHouse != nil }, set: { if !$0 { selectedHouse = nil } })) {
            if let h = selectedHouse { AjkDetailView(house: h) }
        }
        .onChange(of: store.lastError) { _, newValue in
            if let e = newValue, !e.isEmpty { errorText = e }
        }
    }

    // MARK: - 进度

    private var progressBar: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("正在读取安居客找房页…")
                .font(.system(size: 12))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color.themeAccent.opacity(0.08))
    }

    // MARK: - 概览（与 58 同风格三列）

    private var overviewCard: some View {
        HStack(spacing: 0) {
            statItem(value: "\(store.houses.count)", label: "房源(套)")
            statItem(value: store.avgPrice.map(String.init) ?? "—", label: "均价(元/月)")
            statItem(value: store.maxPrice.map(String.init) ?? "—", label: "最高(元/月)")
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

    // MARK: - 工具行（与 58 一致：排序 + 只看带图）

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

    // MARK: - 列表

    private var houseList: some View {
        let list = filteredList
        return VStack(spacing: 10) {
            if store.houses.isEmpty && !store.loading {
                VStack(spacing: 10) {
                    Image(systemName: "building.2")
                        .font(.system(size: 40))
                        .foregroundColor(.themeText3)
                    Text(store.lastError == nil ? "还没有安居客数据" : "读取失败")
                        .font(.system(size: 14, weight: .medium))
                    Text(store.lastError ?? "点右上角「读取」抓取安居客找房页\n标题/缩略图/价格/位置，点卡片看详情")
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
                        AjkPublicCard(house: house)
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

    private var filteredList: [AjkPublicHouse] {
        var list = store.houses
        if onlyWithCover {
            list = list.filter { !$0.coverURL.isEmpty }
        }
        switch sortMode {
        case .defaultOrder: break
        case .priceAsc:  list.sort { ($0.priceValue ?? .max) < ($1.priceValue ?? .max) }
        case .priceDesc: list.sort { ($0.priceValue ?? .min) > ($1.priceValue ?? .min) }
        }
        return list
    }
}

// MARK: - 排序

enum AjkSortMode: String, CaseIterable {
    case defaultOrder, priceAsc, priceDesc
    var label: String {
        switch self {
        case .defaultOrder: return "默认顺序"
        case .priceAsc: return "价格从低到高"
        case .priceDesc: return "价格从高到低"
        }
    }
}

// MARK: - 卡片（与 58 卡片同结构）

struct AjkPublicCard: View {
    let house: AjkPublicHouse

    var body: some View {
        let coverPath = AjkPublicStore.shared.coverLocalPath(for: house.infoid)
        return HStack(alignment: .top, spacing: 10) {
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
                if !house.tag.isEmpty || !house.toward.isEmpty {
                    HStack(spacing: 3) {
                        if !house.tag.isEmpty {
                            Text(house.tag)
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1.5)
                                .background(Color.themeAccentDark)
                                .clipShape(Capsule())
                        }
                        if !house.toward.isEmpty {
                            Text(house.toward)
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
                if !house.room.isEmpty || !house.size.isEmpty || !house.loc.isEmpty {
                    Text([house.room, house.size, house.loc].filter { !$0.isEmpty }.joined(separator: " ｜ "))
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
                    if !house.floor.isEmpty {
                        Text(house.floor)
                            .font(.system(size: 11))
                            .foregroundColor(.themeText3)
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

// MARK: - 详情（站内浏览器，与 58 详情一致：失败可重试 + Safari 打开）

struct AjkDetailView: View {
    let house: AjkPublicHouse
    @Environment(\.dismiss) private var dismiss
    @State private var loadFailed = false
    @State private var reloadToken = 0

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
                ZStack {
                    AjkDetailWKView(url: url, onLoadFailed: { loadFailed = true }, reloadToken: reloadToken)
                    if loadFailed {
                        VStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 30))
                                .foregroundColor(.themeAmber)
                            Text("详情加载失败（网络或平台风控拦截），请重试")
                                .font(.system(size: 13))
                            Button("重新加载") {
                                loadFailed = false
                                reloadToken += 1
                            }
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Color.themePanel)
                            .clipShape(Capsule())
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.themePanel)
                    }
                }
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

/// 详情 WebView：手机 UA（与抓取一致，避免桌面 UA 触发反爬）
struct AjkDetailWKView: UIViewRepresentable {
    let url: URL
    var onLoadFailed: (() -> Void)?
    var reloadToken: Int = 0

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.customUserAgent = AjkPublicWebViewProvider.mobileUA
        wv.navigationDelegate = context.coordinator
        context.coordinator.start(url: url, webView: wv)
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        if reloadToken != context.coordinator.lastReloadToken {
            context.coordinator.lastReloadToken = reloadToken
            context.coordinator.start(url: url, webView: uiView)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let parent: AjkDetailWKView
        var lastReloadToken: Int = -1
        private var didFinish = false
        private var timeoutWork: DispatchWorkItem?

        init(_ parent: AjkDetailWKView) { self.parent = parent }

        func start(url: URL, webView: WKWebView) {
            didFinish = false
            timeoutWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.didFinish else { return }
                self.parent.onLoadFailed?()
            }
            timeoutWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
            webView.load(URLRequest(url: url))
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            didFinish = true
            timeoutWork?.cancel()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.onLoadFailed?()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.onLoadFailed?()
        }
    }
}

// MARK: - 验证码人工处理弹窗

struct AjkVerifySheet: View {
    @EnvironmentObject private var store: AjkPublicStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.shield")
                        .foregroundColor(.themeAmber)
                    Text("安居客要求验证：请在下方页面手动完成验证码，完成后点右下角按钮继续读取")
                        .font(.system(size: 12))
                        .foregroundColor(.themeText2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.themeAmber.opacity(0.10))

                if let wv = AjkPublicWebViewProvider.shared.verifyWebView {
                    VerifyWebViewHolder(webView: wv)
                } else {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("正在准备验证页面…")
                            .font(.system(size: 12))
                            .foregroundColor(.themeText3)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                HStack(spacing: 10) {
                    Button {
                        store.needVerify = false
                        dismiss()
                    } label: {
                        Text("取消")
                            .font(.system(size: 13))
                            .foregroundColor(.themeText2)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.themeBorder.opacity(0.35))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    Button {
                        Task { await store.continueAfterVerify() }
                        store.needVerify = false
                        dismiss()
                    } label: {
                        Text("我已验证，继续读取")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.themeAccent)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(12)
            }
            .navigationTitle("安居客验证")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        store.needVerify = false
                        dismiss()
                    }
                }
            }
        }
    }
}

/// 复用抓取时的 WKWebView（用户能在这里点验证码，验证通过后同一会话继续抓）
struct VerifyWebViewHolder: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
