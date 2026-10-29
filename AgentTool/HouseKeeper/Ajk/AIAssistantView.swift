//
//  AIAssistantView.swift
//  公寓管家 · AI 助手对话（v1.85）
//  场景：云端监控 / 用量查询 / 电表盯防 / 批量账单 / 数据问答（快捷指令一键带入）
//  配置：API Key 存钥匙串；模型、端点、偏好模板在设置页可改
//

import SwiftUI

// MARK: - 消息模型

struct AIMessage: Identifiable, Equatable {
    let id = UUID()
    let role: Role
    let text: String
    let time: Date

    enum Role: String {
        case user, assistant
    }
}

// MARK: - 主界面

struct AIAssistantView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var messages: [AIMessage] = []
    @State private var input = ""
    @State private var sending = false
    @State private var showSettings = false
    @State private var errorText: String?

    /// 与设置页共用同一存储：设置改动（模型名/端点/Key 状态）立即反映到本页，无需重启
    @AppStorage("ai.modelName") private var storedModel = "doubao-seed-2-1-turbo-260628"
    @AppStorage("ai.baseURL") private var storedBaseURL = "https://ark.cn-beijing.volces.com/api/v3/chat/completions"
    @AppStorage("ai.promptTemplate") private var storedTemplate = ""
    @AppStorage("ai.apiKeyConfigured") private var keyConfigured = false

    /// 快捷场景（预设指令模板，一键带入输入框）
    private let quickScenes: [(icon: String, label: String, prompt: String)] = [
        ("cloud.fill", "云端监控", "帮我监控云端数据变化：检查我云端的数据目录/备份文件有没有新增或变动，如有变动用大白话告诉我具体变化（哪个文件、什么时间、变大了多少）。"),
        ("gauge", "用量查询", "帮我查一下我云端的存储使用情况：用了多少空间、还剩多少额度、最近计费情况怎么样，用简单的话总结给我。"),
        ("bolt.fill", "电表盯防", "帮我盯着指定房间的电表，电量使用超过我设置的预警值后提醒我，并把当前各房电量情况列出来。"),
        ("creditcard.fill", "批量账单", "帮我把指定房号、指定月份的收租账单批量生成好，格式参照我现在用的账单模板，我确认后手动转发微信。"),
        ("chart.line.uptrend.xyaxis", "数据问答", "调出我 App 里的数据（房源/收支/电表/安居客点击），回答我的问题并按我的要求做分析。")
    ]

    var body: some View {
        VStack(spacing: 0) {
            navBar
            if !hasKey {
                keyNotice
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 12) {
                        if messages.isEmpty {
                            welcome
                        } else {
                            ForEach(messages) { msg in
                                bubble(msg)
                                    .id(msg.id)
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 12)
                }
                .onChange(of: messages.count) { _ in
                    if let last = messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            inputBar()
        }
        .navigationBarHidden(true)
        .sheet(isPresented: $showSettings) {
            NavigationStack { AIAssistantSettingsView() }
        }
        .alert("提示", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("好", role: .cancel) { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
    }

    private var hasKey: Bool {
        keyConfigured
    }

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
                    Text("AI 助手")
                        .font(.system(size: 17, weight: .bold))
                    Text(modelLabel)
                        .font(.system(size: 10.5))
                        .opacity(0.75)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 16))
                        .frame(width: 38, height: 38)
                        .background(Color.white.opacity(0.14))
                        .clipShape(RoundedRectangle(cornerRadius: 11))
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 96)
    }

    private var modelLabel: String {
        "模型：\(storedModel)"
    }

    private var keyNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "key.fill")
                .font(.system(size: 12))
                .foregroundColor(.themeAmber)
            Text("尚未配置 API Key，点右上角设置填写（只保存在本机钥匙串）")
                .font(.system(size: 12))
                .foregroundColor(.themeText2)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.themeAmber.opacity(0.08))
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("我是你的公寓管家 AI 助手")
                    .font(.system(size: 15, weight: .bold))
                Text("可以帮你监控云端数据、查用量、盯电表、批量生成账单、分析 App 里的数据。点下面的场景即可一键带入指令。")
                    .font(.system(size: 12.5))
                    .foregroundColor(.themeText2)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
                ForEach(quickScenes, id: \.label) { scene in
                    Button {
                        input = scene.prompt
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: scene.icon)
                                .font(.system(size: 13))
                                .foregroundColor(.themeAccentDark)
                            Text(scene.label)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundColor(.themeText)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)
                        .background(Color.themePanel)
                        .cornerRadius(10)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.themeBorder, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .background(Color.themePanel.opacity(0.6))
        .cornerRadius(14)
    }

    private func bubble(_ msg: AIMessage) -> some View {
        HStack {
            if msg.role == .user {
                Spacer(minLength: 60)
            }
            VStack(alignment: msg.role == .user ? .trailing : .leading, spacing: 4) {
                Text(msg.text)
                    .font(.system(size: 14))
                    .foregroundColor(.themeText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(msg.role == .user ? Color.themeAccent.opacity(0.14) : Color.themePanel)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                Text(timeText(msg.time))
                    .font(.system(size: 9.5))
                    .foregroundColor(.themeText3)
            }
            if msg.role == .assistant {
                Spacer(minLength: 60)
            }
        }
    }

    private func timeText(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    private func inputBar() -> some View {
        HStack(spacing: 8) {
            TextField(sending ? "正在思考…" : "输入指令，或点上方场景带入", text: $input)
                .font(.system(size: 14))
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.themePanel)
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.themeBorder, lineWidth: 1))
                .disabled(sending)
            Button {
                send()
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(sending ? Color.gray.opacity(0.4) : Color.themeAccent)
                        .frame(width: 42, height: 40)
                    if sending {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(sending || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.themePanel.opacity(0.95))
    }

    // MARK: - 发送

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        guard hasKey else {
            errorText = "请先点右上角设置，填写 API Key（只保存在本机钥匙串）"
            return
        }
        input = ""
        messages.append(AIMessage(role: .user, text: text, time: Date()))
        sending = true
        let apiKey = KeychainHelper.load(key: "ai.volcengine.apiKey") ?? ""
        let baseURL = storedBaseURL
        let model = storedModel
        let template = storedTemplate
        let systemPrompt = AIAssistantSettingsView.defaultSystemPrompt + (template.isEmpty ? "" : "\n\n【我的偏好要求】\n\(template)")
        Task {
            do {
                let reply = try await AIRequestService.send(apiKey: apiKey, baseURL: baseURL, model: model,
                                                            systemPrompt: systemPrompt, userText: text)
                messages.append(AIMessage(role: .assistant, text: reply, time: Date()))
            } catch {
                errorText = error.localizedDescription
            }
            sending = false
        }
    }
}

// MARK: - 设置

struct AIAssistantSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    /// 火山方舟完整模型 ID（正确 ID；旧版短名 Seed-2.1-turbo 会在进入时自动迁移）
    static let defaultModel = "doubao-seed-2-1-turbo-260628"
    static let modelOptions = ["doubao-seed-2-1-turbo-260628", "doubao-seed-2-1-lite-260915", "doubao-seed-evolving"]
    /// 旧版本写错的短模型名（不含 doubao- 前缀，API 会 404），进入设置时自动迁移
    static let legacyModels = ["Seed-2.1-turbo", "Seed-2.1-pro", "Seed-2.1-lite", "DeepSeek-V4-flash"]
    static let defaultSystemPrompt = "你是「公寓管家」的 AI 助手。用户是佛山顺德的二房东/房产从业者，管理米兰公馆的多套出租房源。回答要简洁、口语化、中文优先；涉及数据时先给结论再给依据；涉及金额要精确到分。你只能基于用户 App 里的数据和我提供的信息回答，不要编造数据。"

    /// 存储即实时：@AppStorage 与 UserDefaults 双向同步，改动立即生效，无需点保存/重启
    @AppStorage("ai.modelName") private var storedModel = "doubao-seed-2-1-turbo-260628"
    @AppStorage("ai.baseURL") private var storedBaseURL = "https://ark.cn-beijing.volces.com/api/v3/chat/completions"
    @AppStorage("ai.promptTemplate") private var storedTemplate = ""
    @AppStorage("ai.apiKeyConfigured") private var keyConfigured = false

    @State private var apiKey = ""
    @State private var model = ""
    @State private var baseURL = ""
    @State private var template = ""
    @State private var modelCustom = ""

    var body: some View {
        Form {
            Section {
                SecureField("API Key（火山方舟）", text: $apiKey)
                    .font(.system(size: 13))
                    .autocapitalization(.none)
                Text("只保存在本机钥匙串（Keychain），不上传、不备份；输入即保存，改动立即生效")
                    .font(.system(size: 11))
                    .foregroundColor(.themeText3)
            } header: {
                Text("API Key")
            } footer: {
                Text("在火山方舟控制台创建 API Key 后粘贴到这里；清空输入即删除本机 Key")
            }

            Section("模型") {
                Picker("对话模型", selection: $model) {
                    ForEach(Self.modelOptions, id: \.self) { m in
                        Text(m).tag(m)
                    }
                    Text("自定义（填下方 ID）").tag("custom")
                }
                TextField("自定义模型 ID（选填，覆盖上方选择）", text: $modelCustom)
                    .font(.system(size: 13))
                    .autocapitalization(.none)
                Text("输入即保存；保存过自定义 ID 后再次进入会自动回填显示")
                    .font(.system(size: 11))
                    .foregroundColor(.themeText3)
            }

            Section("接口端点") {
                TextField("API 端点 URL", text: $baseURL)
                    .font(.system(size: 12))
                    .autocapitalization(.none)
                    .keyboardType(.URL)
            }

            Section("偏好模板（调教）") {
                TextEditor(text: $template)
                    .frame(minHeight: 90)
                    .font(.system(size: 12))
                Text("填写你希望 AI 一直遵守的规则（如：报价只说每月租金；金额精确到元；先结论后明细）。每次对话都会带上。")
                    .font(.system(size: 11))
                    .foregroundColor(.themeText3)
            }
        }
        .navigationTitle("AI 助手设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }
            }
        }
        .onAppear(perform: loadFromStorage)
        // 以下全部实时保存（水印开关同款修法：输入即生效，不依赖「保存」按钮）
        .onChange(of: apiKey) { newKey in
            let t = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty {
                KeychainHelper.delete(key: "ai.volcengine.apiKey")
                keyConfigured = false
            } else {
                _ = KeychainHelper.save(key: "ai.volcengine.apiKey", value: t)
                keyConfigured = true
            }
        }
        .onChange(of: model) { newModel in
            guard newModel != "custom" else { return }
            if Self.modelOptions.contains(newModel) {
                storedModel = newModel
                if !modelCustom.isEmpty { modelCustom = "" }
            }
        }
        .onChange(of: modelCustom) { newValue in
            let t = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty {
                storedModel = t
                if model != "custom" { model = "custom" }
            } else if model == "custom" {
                storedModel = Self.defaultModel
                model = Self.defaultModel
            }
        }
        .onChange(of: baseURL) { newValue in
            let t = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            storedBaseURL = t.isEmpty ? AIRequestService.defaultBaseURL : t
        }
        .onChange(of: template) { newValue in
            storedTemplate = newValue
        }
    }

    private func loadFromStorage() {
        apiKey = KeychainHelper.load(key: "ai.volcengine.apiKey") ?? ""
        let saved = UserDefaults.standard.string(forKey: "ai.modelName") ?? Self.defaultModel
        if Self.legacyModels.contains(saved) {
            // 旧版错误短名 → 自动迁移到正确模型 ID 并写回
            storedModel = Self.defaultModel
            model = Self.defaultModel
            modelCustom = ""
        } else if Self.modelOptions.contains(saved) {
            model = saved
            modelCustom = ""
        } else {
            // 已保存的自定义模型 ID → 回填自定义输入框
            model = "custom"
            modelCustom = saved
        }
        baseURL = UserDefaults.standard.string(forKey: "ai.baseURL") ?? AIRequestService.defaultBaseURL
        template = UserDefaults.standard.string(forKey: "ai.promptTemplate") ?? ""
        keyConfigured = !apiKey.isEmpty
    }
}
