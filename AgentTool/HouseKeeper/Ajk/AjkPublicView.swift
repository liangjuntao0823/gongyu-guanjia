//
//  AjkPublicView.swift
//  公寓管家 · 安居客前台找房 tab（v2.2 b109）
//  功能：读取安居客前台找房页第一页（宽松文本解析）→ 列表展示 → 点卡片 Safari 打开详情
//  安全：只读展示；仅用户主动点击读取；只抓第一页
//

import SwiftUI
import SafariServices

struct AjkPublicView: View {
    @EnvironmentObject private var store: AjkPublicStore
    @State private var errorText: String?
    @State private var openURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            header
            if !store.houses.isEmpty || store.lastFetch != nil { statsRow }
            if store.loading { progressBar }
            ScrollView {
                VStack(spacing: 10) {
                    if store.houses.isEmpty && !store.loading {
                        emptyView
                    } else {
                        ForEach(store.houses) { house in
                            Button {
                                if let url = URL(string: house.href) {
                                    openURL = url
                                }
                            } label: {
                                AjkPublicCard(house: house)
                            }
                            .buttonStyle(.plain)
                        }
                        Text("共 \(store.houses.count) 套（每次只抓第一页）")
                            .font(.system(size: 11))
                            .foregroundColor(.themeText3)
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 30)
            }
        }
        .alert("提示", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("好", role: .cancel) { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
        .sheet(isPresented: Binding(get: { openURL != nil }, set: { if !$0 { openURL = nil } })) {
            if let url = openURL {
                SafariSheet(url: url)
            }
        }
    }

    /// v2.3（需求⑤）：顶栏统计——房源套数 / 均价 / 最高租金（与 58 tab 概览卡同风格三列）
    private var statsRow: some View {
        let prices = store.houses.compactMap { Double($0.price) }
        let avg = prices.isEmpty ? nil : Int(prices.reduce(0, +) / Double(prices.count))
        let maxP = prices.max().map { Int($0) }
        return HStack(spacing: 0) {
            statItem(value: "\(store.houses.count)", label: "房源(套)")
            statItem(value: avg.map(String.init) ?? "—", label: "均价(元/月)")
            statItem(value: maxP.map(String.init) ?? "—", label: "最高(元/月)")
        }
        .padding(.vertical, 10)
        .background(Color.themePanel)
        .overlay(RoundedRectangle(cornerRadius: 0).stroke(Color.themeBorder, lineWidth: 0.5))
    }

    private func statItem(value: String, label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(.themeAccentDark)
            Text(label)
                .font(.system(size: 10.5))
                .foregroundColor(.themeText3)
        }
        .frame(maxWidth: .infinity)
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.settingsKeyword.isEmpty ? "安居客找房" : store.settingsKeyword)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.themeText)
                Text(subTitle)
                    .font(.system(size: 11))
                    .foregroundColor(.themeText3)
            }
            Spacer()
            Button {
                Task { await fetch() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                    Text("读取")
                        .font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Color.themeAccent.opacity(0.12))
                .foregroundColor(.themeAccentDark)
                .clipShape(Capsule())
            }
            .disabled(store.loading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.themePanel)
        .overlay(RoundedRectangle(cornerRadius: 0).stroke(Color.themeBorder, lineWidth: 0.5))
    }

    private var subTitle: String {
        if let t = store.lastFetch {
            let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"
            return "上次抓取 \(f.string(from: t))｜共 \(store.houses.count) 套"
        }
        return "点「读取」抓第一页约 60 套"
    }

    private var progressBar: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("正在读取安居客找房页…")
                .font(.system(size: 12))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color.themeAccent.opacity(0.08))
    }

    private var emptyView: some View {
        VStack(spacing: 10) {
            Image(systemName: "building.2")
                .font(.system(size: 40))
                .foregroundColor(.themeText3)
            Text(store.lastError == nil ? "还没有安居客数据" : "读取失败")
                .font(.system(size: 14, weight: .medium))
            Text(store.lastError ?? "点「读取」抓取安居客找房页第一页\n标题/价格/位置，点卡片浏览器打开详情")
                .font(.system(size: 12))
                .foregroundColor(.themeText3)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 60)
    }

    private func fetch() async {
        await store.fetch()
        if let err = store.lastError {
            errorText = err
        }
    }
}

// MARK: - 卡片

struct AjkPublicCard: View {
    let house: AjkPublicHouse

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.themeBorder.opacity(0.25))
                    .frame(width: 76, height: 76)
                Image(systemName: "building")
                    .font(.system(size: 20))
                    .foregroundColor(.themeText3)
            }
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.themeBorder, lineWidth: 1))
            VStack(alignment: .leading, spacing: 5) {
                Text(house.title.isEmpty ? "（无标题）" : house.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.themeText)
                    .lineLimit(2)
                if !house.loc.isEmpty || !house.area.isEmpty {
                    Text([house.area, house.loc].filter { !$0.isEmpty }.joined(separator: " ｜ "))
                        .font(.system(size: 12))
                        .foregroundColor(.themeText2)
                        .lineLimit(1)
                }
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(house.price)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.themeAccentDark)
                    Text("元/月")
                        .font(.system(size: 11))
                        .foregroundColor(.themeText3)
                    Spacer()
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

// MARK: - Safari 打开详情

struct SafariSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }
    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
