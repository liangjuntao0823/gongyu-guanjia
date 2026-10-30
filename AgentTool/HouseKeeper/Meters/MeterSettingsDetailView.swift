//
//  MeterSettingsDetailView.swift
//  公寓管家 · 电表监控设置
//  查询链接自定义更换（换微信换链接）/ 数据源方案 / 低电量阈值 / 定时刷新 / 提醒
//

import SwiftUI

struct MeterSettingsDetailView: View {
    @EnvironmentObject private var store: MeterStore
    @Environment(\.dismiss) private var dismiss

    @State private var linkInput = ""
    @State private var linkTip: String?
    @State private var showLinkSaved = false

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("官方电表查询链接")
                        .font(.system(size: 13))
                        .foregroundColor(.themeText3)
                    TextField("粘贴微信里的查询链接", text: $linkInput, axis: .vertical)
                        .lineLimit(3...5)
                        .font(.system(size: 14))
                        .padding(10)
                        .background(Color.themeBorder.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        saveLink()
                    } label: {
                        Text("保存链接")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(Color.themeAccentDark)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    if !store.settings.openId.isEmpty {
                        Label("当前微信身份：\(maskedOpenId)", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.themeAccentDark)
                    }
                    if let tip = linkTip {
                        Text(tip)
                            .font(.system(size: 12))
                            .foregroundColor(tip.contains("已保存") ? .themeAccentDark : .red)
                    }
                }
            } header: {
                Text("查询链接")
            } footer: {
                Text("从微信复制电表缴费页链接粘贴到这里，App 会解析 openId 作为查询身份。换微信后需更换链接（openId 随微信账号变化）。链接本身不加密存储，仅本机使用。")
            }

            Section {
                Picker("数据源方案", selection: Binding(
                    get: { store.settings.provider },
                    set: { store.settings.provider = $0; store.saveSettings() }
                )) {
                    ForEach(MeterProviderKind.allCases, id: \.self) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .pickerStyle(.navigationLink)
            } header: {
                Text("数据源")
            } footer: {
                Text("直连接口：无需打开网页，串行查询更快更稳（默认）。网页抓取：通过隐藏网页读取数据，作为官方改版时的兜底。")
            }

            Section {
                HStack {
                    Text("低电量阈值")
                    Spacer()
                    HStack(spacing: 2) {
                        TextField("30", value: Binding(
                            get: { store.settings.lowThreshold },
                            set: { store.settings.lowThreshold = max(1, min(999, $0)); store.saveSettings() }
                        ), format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 56)
                        Text("度")
                            .font(.system(size: 13))
                            .foregroundColor(.themeText3)
                    }
                }
                Toggle("低电量提醒", isOn: Binding(
                    get: { store.settings.lowAlertEnabled },
                    set: { store.settings.lowAlertEnabled = $0; store.saveSettings() }
                ))
            } header: {
                Text("预警")
            } footer: {
                Text("刷新后剩余电量低于阈值的房号在列表标红；低电量提醒每天最多推送一次，避免骚扰。拉闸房号同样标红。")
            }

            Section {
                Toggle("定时自动刷新", isOn: Binding(
                    get: { store.settings.autoRefreshEnabled },
                    set: { store.settings.autoRefreshEnabled = $0; store.saveSettings() }
                ))
                if store.settings.autoRefreshEnabled {
                    Picker("刷新间隔", selection: Binding(
                        get: { store.settings.autoRefreshMinutes },
                        set: { store.settings.autoRefreshMinutes = $0; store.saveSettings() }
                    )) {
                        Text("10 分钟").tag(10)
                        Text("30 分钟").tag(30)
                        Text("1 小时").tag(60)
                        Text("2 小时").tag(120)
                    }
                    .pickerStyle(.menu)
                }
            } header: {
                Text("自动刷新")
            } footer: {
                Text("开启后 App 运行期间按间隔自动刷新全部电表；关闭则只在进入板块或手动刷新时更新。")
            }
        }
        .navigationTitle("电表监控设置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            linkInput = store.settings.queryLink
        }
    }

    private var maskedOpenId: String {
        let id = store.settings.openId
        guard id.count > 8 else { return id }
        return String(id.prefix(4)) + "****" + String(id.suffix(4))
    }

    private func saveLink() {
        let trimmed = linkInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            linkTip = "请先粘贴查询链接"
            return
        }
        guard let openId = store.parseOpenId(from: trimmed), !openId.isEmpty else {
            linkTip = "链接里没有找到 openId，请粘贴完整的电表缴费页链接（形如 http://wy.mlh-china.com/electricmeter/?openId=…）"
            return
        }
        store.applyQueryLink(trimmed)
        store.resetSession()
        linkTip = "已保存，当前微信身份 openId 已更新"
    }
}
