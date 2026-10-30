//
//  AIAssistantView.swift
//  公寓管家 · AI 助手对话（v1.88）
//  场景：云端监控 / 用量查询 / 电表盯防 / 批量账单 / 数据问答（快捷指令一键带入）
//  配置：API Key 存钥匙串；模型、端点、偏好模板在设置页可改
//  v1.88：多轮上下文 / 历史保留 / 接入本地房源数据 / 正在思考提示 / 图片·视频首帧·文件发送 / 顶栏改版
//

import SwiftUI
import PhotosUI
import PDFKit
import AVFoundation
import SwiftData
import UniformTypeIdentifiers

// MARK: - 消息模型

struct AIMessage: Identifiable, Equatable, Codable {
    let id: UUID
    let role: Role
    let text: String
    let time: Date
    /// 本条 user 消息附带的图片（data URL），仅当轮展示，历史不重传
    var images: [String] = []
    /// 本条 user 消息附带的文件文本摘要（如 txt/pdf 提取内容）
    var attachText: String?
    /// v1.96：本条 assistant 消息实际执行过的 AI 工具动作标签（气泡内展示，一眼可追溯）
    /// Optional：老版本历史无此字段，decodeIfPresent 兼容
    var toolSummary: [String]? = nil
    /// v1.97：AI 回复末尾给出的预选项快捷指令（点击直接发送）
    var suggestedActions: [String]? = nil
    /// v1.98：assistant 消息附带的本地图片路径（AI 工具生成的账单图片，如 RentBillShareView 渲染 PNG）
    /// Optional：历史兼容
    var imagePath: String? = nil

    enum Role: String, Codable {
        case user, assistant
    }

    init(id: UUID = UUID(), role: Role, text: String, time: Date = Date(),
         images: [String] = [], attachText: String? = nil, toolSummary: [String]? = nil,
         suggestedActions: [String]? = nil, imagePath: String? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.time = time
        self.images = images
        self.attachText = attachText
        self.toolSummary = toolSummary
        self.suggestedActions = suggestedActions
        self.imagePath = imagePath
    }
}

// MARK: - 主界面

struct AIAssistantView: View {
    @Environment(\.dismiss) private var dismiss
    // v1.92：必须用房源专用容器 houseModelContext——主容器 schema 不含 House，用 modelContext 会抛
    // NSInternalInconsistencyException（NSFetchRequest could not locate entity 'House'）导致发送即闪退
    @Environment(\.houseModelContext) private var houseModelContext
    // v1.94：主容器 modelContext（收支/待办等经营数据，App.swift .modelContainer(mainContainer) 注入）
    @Environment(\.modelContext) private var modelContext
    // v1.97：全局 AI 任务管理器——对话状态/执行任务/确认框不随页面关闭丢失（App 划掉才终止）
    @StateObject private var manager = AIManager.shared
    @State private var input = ""
    @State private var showSettings = false
    /// v1.98：历史消息查看（弹 sheet 浏览全部历史，可一键清空）
    @State private var showHistory = false

    /// 附件：待发送的图片（UIImage 源）+ 文件文本
    @State private var pendingImages: [UIImage] = []
    @State private var pendingAttachText: String?
    @State private var pendingAttachName: String?
    @State private var showPhotoPicker = false
    @State private var showFilePicker = false
    @State private var photoPickerItems: [PhotosPickerItem] = []

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
                        if manager.showWelcome {
                            welcome
                        } else {
                            ForEach(manager.messages) { msg in
                                bubble(msg)
                                    .id(msg.id)
                            }
                            if manager.sending {
                                thinkingBubble
                                    .id("thinking")
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 12)
                }
                // v1.98：进入页面直接定位到对话最底端（最新消息），不再停在顶端
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        if let last = manager.messages.last {
                            withAnimation(.none) { proxy.scrollTo(last.id, anchor: .bottom) }
                        } else if manager.sending {
                            withAnimation(.none) { proxy.scrollTo("thinking", anchor: .bottom) }
                        }
                    }
                }
                .onChange(of: manager.messages.count) { _ in
                    if let last = manager.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    } else if manager.sending {
                        withAnimation { proxy.scrollTo("thinking", anchor: .bottom) }
                    }
                }
                .onChange(of: manager.sending) { _ in
                    if manager.sending {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            withAnimation { proxy.scrollTo("thinking", anchor: .bottom) }
                        }
                    }
                }
            }
            attachBar
            inputBar()
        }
        .navigationBarHidden(true)
        .sheet(isPresented: $showHistory) {
            NavigationStack { AIHistoryView(manager: manager) }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack { AIAssistantSettingsView() }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoPickerItems, maxSelectionCount: 6, matching: .any(of: [.images, .videos]))
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.text, .plainText, .pdf, .json, .commaSeparatedText], allowsMultipleSelection: false) { result in
            handleFileImport(result)
        }
        .alert("提示", isPresented: Binding(get: { manager.errorText != nil }, set: { if !$0 { manager.errorText = nil } })) {
            Button("好", role: .cancel) { manager.errorText = nil }
        } message: {
            Text(manager.errorText ?? "")
        }
        // v1.96：AI 写操作确认框（系统弹窗，同提示框样式；删除类动作执行按钮标红）
        // v1.97：确认状态在全局 manager——对话页关闭时挂起，重开页面自动继续弹出
        .alert("确认执行以下操作？", isPresented: $manager.pendingConfirm) {
            let dangerous = (manager.pendingToolCalls ?? []).contains { AIToolExecutor.isDangerous(toolName: $0.name, arguments: $0.arguments) }
            Button("取消", role: .cancel) {
                manager.confirm(accept: false)
            }
            Button(dangerous ? "执行（谨慎）" : "执行", role: dangerous ? .destructive : .none) {
                manager.confirm(accept: true)
            }
        } message: {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(manager.pendingToolSummaries, id: \.self) { line in
                    Text("• \(line)")
                        .font(.system(size: 13))
                }
                if (manager.pendingToolCalls ?? []).contains(where: { AIToolExecutor.isDangerous(toolName: $0.name, arguments: $0.arguments) }) {
                    Text("注意：其中包含删除/覆盖类操作，请确认无误后再执行。")
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: photoPickerItems) { items in
            handlePhotoItems(items)
        }
        .onAppear {
            manager.onAppear(modelContext: modelContext, houseModelContext: houseModelContext)
        }
    }

    /// 已选附件栏（图片缩略 + 文件文本），可移除
    private var attachBar: some View {
        Group {
            if !pendingImages.isEmpty || pendingAttachText != nil {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(pendingImages.enumerated()), id: \.offset) { idx, img in
                            ZStack(alignment: .topTrailing) {
                                Image(uiImage: img)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 52, height: 52)
                                    .clipShape(RoundedRectangle(cornerRadius: 9))
                                Button {
                                    // v1.89：防快速连点导致数组越界闪退
                                    if idx < pendingImages.count { pendingImages.remove(at: idx) }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 15))
                                        .foregroundColor(.white)
                                        .background(Color.black.opacity(0.6))
                                        .clipShape(Circle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        if let name = pendingAttachName {
                            HStack(spacing: 6) {
                                Image(systemName: "doc.text.fill")
                                    .font(.system(size: 12))
                                    .foregroundColor(.themeAccentDark)
                                Text(name)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                Button {
                                    pendingAttachText = nil
                                    pendingAttachName = nil
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 15))
                                        .foregroundColor(.gray)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.themePanel)
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(Color.themeBorder, lineWidth: 1))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                .background(Color.themePanel.opacity(0.8))
            }
        }
    }

    /// 「正在思考」气泡（v1.95：三个静态圆点改为动态转圈；v1.96：工具执行阶段动态显示文案）
    private var thinkingBubble: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.themeAccent)
                    Text(manager.toolPhase ?? "正在思考…")
                        .font(.system(size: 12))
                        .foregroundColor(.themeText2)
                }
                if let calls = manager.pendingToolCalls, !calls.isEmpty {
                    Text("共 \(calls.count) 项操作，等待你确认")
                        .font(.system(size: 10.5))
                        .foregroundColor(.themeText3)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Color.themePanel)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            Spacer(minLength: 60)
        }
    }

    private var hasKey: Bool {
        keyConfigured
    }

    private var navBar: some View {
        ZStack {
            // v1.89：顶栏改深绿渐变（与 App 主题一致），白色高对比按钮，与白色聊天区明显区分
            LinearGradient(colors: [.themeAccentDark, .themeAccent], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
            HStack(spacing: 8) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 32, height: 32)
                        .background(Color.white.opacity(0.16))
                        .clipShape(Circle())
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text("AI 助手")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                    Text(modelLabel)
                        .font(.system(size: 9.5))
                        .foregroundColor(.white.opacity(0.8))
                        .lineLimit(1)
                }
                Spacer()
                // v1.98：历史查看按钮（浏览全部历史对话，可一键清空）
                Button {
                    showHistory = true
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 14))
                        .foregroundColor(.white)
                        .frame(width: 32, height: 32)
                        .background(Color.white.opacity(0.16))
                        .clipShape(Circle())
                }
                if !manager.messages.isEmpty {
                    Button {
                        manager.clearChat()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 14))
                            .foregroundColor(.white)
                            .frame(width: 32, height: 32)
                            .background(Color.white.opacity(0.16))
                            .clipShape(Circle())
                    }
                }
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 15))
                        .foregroundColor(.white)
                        .frame(width: 32, height: 32)
                        .background(Color.white.opacity(0.16))
                        .clipShape(Circle())
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
        }
        .frame(height: 64)
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
                        // v1.95：电表盯防场景一键开启「App 原生定时刷新」——AI 无法在后台自行定时执行
                        //（iOS 系统限制），盯防落地为：每 2 小时自动刷新电表 + 低电量本地通知；
                        // AI 对话时读取的即是最新电表数据（快照已接入）
                        if scene.label == "电表盯防" {
                            enableMeterWatch()
                        }
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
        HStack(alignment: .bottom, spacing: 8) {
            if msg.role == .user {
                Spacer(minLength: 56)
            }
            VStack(alignment: msg.role == .user ? .trailing : .leading, spacing: 4) {
                if !msg.images.isEmpty {
                    // 图片缩略（base64 本地渲染）
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 4) {
                        ForEach(Array(msg.images.enumerated()), id: \.offset) { _, url in
                            if let img = imageFromDataURL(url) {
                                Image(uiImage: img)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 74, height: 74)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }
                    .frame(maxWidth: 240)
                }
                // v1.98：AI 工具生成的图片（如收租账单图）直接展示在气泡里
                if let path = msg.imagePath, let img = UIImage(contentsOfFile: path) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 300)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                if let attach = msg.attachText {
                    Label(attach, systemImage: "paperclip")
                        .font(.system(size: 11))
                        .foregroundColor(.themeAccentDark)
                }
                Text(msg.text)
                    .font(.system(size: 14))
                    .foregroundColor(msg.role == .user ? .white : .themeText)
                    // v1.95：对话文字可长按复制
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    // v1.97：微信式双气泡——用户绿底白字、AI 灰底深字，双方都有明确底色
                    .background(msg.role == .user ? Color.themeAccent : Color(white: 0.93))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .frame(maxWidth: 300, alignment: msg.role == .user ? .trailing : .leading)
                // v1.96：AI 实际执行过的动作标签（一眼可追溯）
                if let ts = msg.toolSummary, !ts.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(ts, id: \.self) { label in
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 10))
                                Text(label)
                                    .font(.system(size: 10.5))
                                    .lineLimit(1)
                            }
                            .foregroundColor(.themeAccentDark)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.themeAccent.opacity(0.1))
                            .clipShape(Capsule())
                        }
                    }
                    .padding(.top, 2)
                }
                // v1.97：AI 回复预选项（豆包式快捷指令 chips，点击直接发送）
                if let acts = msg.suggestedActions, !acts.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(acts, id: \.self) { act in
                            Button {
                                manager.sendQuick(act)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.up.circle")
                                        .font(.system(size: 10))
                                    Text(act)
                                        .font(.system(size: 12))
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    Spacer(minLength: 0)
                                }
                                .foregroundColor(.themeAccentDark)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(Color.themeAccent.opacity(0.1))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.themeAccent.opacity(0.25), lineWidth: 1))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: 300, alignment: .leading)
                    .padding(.top, 2)
                }
                Text(timeText(msg.time))
                    .font(.system(size: 9.5))
                    .foregroundColor(.themeText3)
                    .padding(.top, 1)
            }
            if msg.role == .assistant {
                Spacer(minLength: 56)
            }
        }
    }

    private func timeText(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    private func inputBar() -> some View {
        HStack(spacing: 6) {
            // 相册（图片/视频，视频自动截首帧）——v1.93：回答期间不禁用，可提前选图排队
            Button {
                showPhotoPicker = true
            } label: {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 15))
                    .foregroundColor(.themeText2)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            // 文件（txt/md/json/csv/pdf，自动提取文本）——v1.93：回答期间不禁用
            Button {
                showFilePicker = true
            } label: {
                Image(systemName: "paperclip")
                    .font(.system(size: 15))
                    .foregroundColor(.themeText2)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            // v1.97：思考/执行期间输入框与发送按钮保持可用——此时点发送会排队，当前任务完成后自动发送
            //（不再是"发送被转圈取代、只能打字不能发"）
            TextField(manager.sending ? "正在思考…（仍可发送，将排队自动发出）" : "输入指令，或点上方场景带入", text: $input)
                .font(.system(size: 14))
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.themePanel)
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.themeBorder, lineWidth: 1))
            Button {
                let text = input
                input = ""
                manager.send(userText: text, images: pendingImages, attachText: pendingAttachText, attachName: pendingAttachName)
                pendingImages = []
                pendingAttachText = nil
                pendingAttachName = nil
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill((input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pendingImages.isEmpty)
                              ? Color.gray.opacity(0.35) : Color.themeAccent)
                        .frame(width: 44, height: 40)
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                    // v1.97：排队角标——执行中继续发送的条数
                    if manager.queuedCount > 0 {
                        Text("\(manager.queuedCount)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.red)
                            .clipShape(Capsule())
                            .offset(x: 16, y: -16)
                    }
                }
            }
            .buttonStyle(.plain)
            // v1.97：仅空输入禁用；思考/执行期间可继续发送（入队自动发出）
            .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pendingImages.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        // v1.89：背景延伸到屏幕底部安全区，输入栏整体下移贴底
        .background(Color.themePanel.opacity(0.95).ignoresSafeArea(edges: .bottom))
    }

    // MARK: - 发送

    /// v1.95：电表盯防场景一键开启——App 原生定时刷新（2 小时）+ 低电量本地通知
    private func enableMeterWatch() {
        let store = MeterStore.shared
        store.settings.autoRefreshEnabled = true
        store.settings.autoRefreshMinutes = 120
        store.settings.lowAlertEnabled = true
        store.saveSettings() // 内部会重建定时器并立即补刷一次
        manager.errorText = "已开启电表盯防：每 2 小时自动刷新一次，低电量会本地通知提醒。注意：iOS 限制 App 被杀后无法后台执行，保持 App 在后台运行即可持续盯防；重新打开会立即补刷最新数据。"
    }

    private func handlePhotoItems(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        Task {
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let img = UIImage(data: data) {
                    pendingImages.append(img)
                } else if let fileURL = try? await item.loadTransferable(type: URL.self) {
                    // 视频：PhotosPicker 对视频返回临时文件 URL，截取首帧
                    if let frame = extractFirstFrame(url: fileURL) {
                        pendingImages.append(frame)
                    } else {
                        manager.errorText = "视频首帧提取失败，请改发图片"
                    }
                }
            }
            photoPickerItems = []
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        let name = url.lastPathComponent
        do {
            if url.pathExtension.lowercased() == "pdf" {
                if let doc = PDFDocument(url: url), let text = doc.string, !text.isEmpty {
                    pendingAttachText = String(text.prefix(4000))
                    pendingAttachName = name
                    return
                }
            } else {
                let data = try Data(contentsOf: url)
                if let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) {
                    pendingAttachText = String(text.prefix(4000))
                    pendingAttachName = name
                    return
                }
            }
            manager.errorText = "该文件类型暂不支持读取内容（支持 txt/md/json/csv/pdf）"
        } catch {
            manager.errorText = "文件读取失败：\(error.localizedDescription)"
        }
    }

    /// 图片压缩到长边 1280、JPEG 0.7，转 data URL
    private func extractFirstFrame(url: URL) -> UIImage? {
        let asset = AVAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let time = CMTime(value: 0, timescale: 60)
        guard let cg = try? gen.copyCGImage(at: time, actualTime: nil) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// base64 data URL → UIImage
    private func imageFromDataURL(_ s: String) -> UIImage? {
        guard let comma = s.firstIndex(of: ",") else { return nil }
        let b64 = String(s[s.index(after: comma)...])
        guard let data = Data(base64Encoded: b64) else { return nil }
        return UIImage(data: data)
    }
}

// MARK: - 历史查看（v1.98）

/// AI 对话历史查看：正序展示（旧→新，进入自动滚到最新），长消息单击折叠/展开，支持关键词搜索，可一键清空
struct AIHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var manager: AIManager
    @State private var confirmClear = false
    @State private var searchText = ""
    /// v1.98：已展开的消息 id（单击文本在"折叠3行/展开全文"间切换）
    @State private var expandedIDs: Set<UUID> = []

    /// v1.98：按关键词过滤（匹配 我/AI 角色、正文、动作标签、账单图标记）；保持时间正序
    private var filtered: [AIMessage] {
        let kw = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else { return manager.messages }
        return manager.messages.filter { msg in
            msg.text.localizedCaseInsensitiveContains(kw)
                || (msg.toolSummary?.joined(separator: " ") ?? "").localizedCaseInsensitiveContains(kw)
                || (msg.role == .user ? "我" : "AI").contains(kw)
        }
    }

    /// v1.98：长消息（超过3行才显示"展开/收起"提示）单击切换折叠状态
    private func isLong(_ msg: AIMessage) -> Bool {
        // 粗略判断：文本较长或含较多换行即视为长消息
        msg.text.count > 80 || msg.text.filter { $0 == "\n" }.count >= 2
    }

    var body: some View {
        Group {
            if manager.messages.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "clock")
                        .font(.system(size: 34))
                        .foregroundColor(.themeText3)
                    Text("暂无历史记录")
                        .font(.system(size: 14))
                        .foregroundColor(.themeText2)
                    Text("发送第一条指令后，历史会保存在这里（保留最近 1 年）")
                        .font(.system(size: 12))
                        .foregroundColor(.themeText3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    // v1.98：历史搜索框
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 14))
                            .foregroundColor(.themeText3)
                        TextField("搜索历史消息（房号/租金/关键词）", text: $searchText)
                            .font(.system(size: 14))
                            .autocorrectionDisabled()
                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundColor(.themeText3)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color(.systemGray6).opacity(0.7))
                    .cornerRadius(10)
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 4)

                    // v1.98：正序列表，进入后自动滚动到最底部（最新消息），不改变阅读顺序
                    ScrollViewReader { proxy in
                        List {
                            ForEach(filtered) { msg in
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack(spacing: 6) {
                                        Text(msg.role == .user ? "我" : "AI")
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 2)
                                            .background(msg.role == .user ? Color.themeAccent : Color.gray.opacity(0.65))
                                            .clipShape(Capsule())
                                        Text(timeFullText(msg.time))
                                            .font(.system(size: 11))
                                            .foregroundColor(.themeText3)
                                        if let ts = msg.toolSummary, !ts.isEmpty {
                                            Text("执行 \(ts.count) 项操作")
                                                .font(.system(size: 10))
                                                .foregroundColor(.themeAccentDark)
                                        }
                                        if msg.imagePath != nil {
                                            Text("含账单图")
                                                .font(.system(size: 10))
                                                .foregroundColor(.themeAccentDark)
                                        }
                                    }
                                    Text(msg.text)
                                        .font(.system(size: 13))
                                        .foregroundColor(.themeText)
                                        // v1.98：默认折叠3行，展开后显示全文；点击文本区切换
                                        .lineLimit(expandedIDs.contains(msg.id) ? nil : 3)
                                        .textSelection(.enabled)
                                    if isLong(msg) {
                                        HStack(spacing: 4) {
                                            Text(expandedIDs.contains(msg.id) ? "收起" : "展开全文")
                                                .font(.system(size: 11))
                                                .foregroundColor(.themeAccentDark)
                                            Image(systemName: expandedIDs.contains(msg.id) ? "chevron.up" : "chevron.down")
                                                .font(.system(size: 10))
                                                .foregroundColor(.themeAccentDark)
                                        }
                                    }
                                }
                                .padding(.vertical, 3)
                                .id(msg.id)
                                // v1.98：单击切换折叠/展开（长按仍可选中复制文本）
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if isLong(msg) {
                                        if expandedIDs.contains(msg.id) {
                                            expandedIDs.remove(msg.id)
                                        } else {
                                            expandedIDs.insert(msg.id)
                                        }
                                    }
                                }
                            }
                        }
                        .listStyle(.insetGrouped)
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                if let last = filtered.last {
                                    withAnimation(.none) { proxy.scrollTo(last.id, anchor: .bottom) }
                                }
                            }
                        }
                        .onChange(of: searchText) { _ in
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                if let last = filtered.last {
                                    withAnimation(.none) { proxy.scrollTo(last.id, anchor: .bottom) }
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("对话历史（\(manager.messages.count) 条，近 1 年）")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("关闭") { dismiss() }
            }
            if !manager.messages.isEmpty {
                ToolbarItem(placement: .confirmationAction) {
                    Button("清空") { confirmClear = true }
                        .foregroundColor(.red)
                }
            }
        }
        .alert("清空全部对话历史？", isPresented: $confirmClear) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) { manager.clearChat() }
        } message: {
            Text("历史记录将被删除，AI 将不再记得之前的对话内容。")
        }
    }

    private func timeFullText(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: d)
    }
}

// MARK: - 设置

struct AIAssistantSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    /// 火山方舟完整模型 ID（正确 ID；旧版短名 Seed-2.1-turbo 会在进入时自动迁移）
    static let defaultModel = "doubao-seed-2-1-turbo-260628"
    /// v1.91：账号已开通模型全量接入（2026-10-29 从火山方舟控制台实测抓取；
    /// 全部模型均带「新用户赠送 50 万 tokens 推理额度」，可免费调用）
    static let builtinModels: [RemoteConfig.AIModelInfo] = [
        // ── 豆包（字节）系列 ──
        RemoteConfig.AIModelInfo(modelID: "doubao-seed-2-1-turbo-260628", name: "Doubao-Seed-2.1-turbo",
                                desc: "效果与成本均衡的日常首选：对话、编程、智能体、多模态全面均衡，响应快，适合日常问答与多轮对话"),
        RemoteConfig.AIModelInfo(modelID: "doubao-seed-2-1-lite-260915", name: "Doubao-Seed-2.1-lite",
                                desc: "轻量快速版：响应更快、成本更低，支持 1M 超长上下文，适合简单问答与长文本处理"),
        RemoteConfig.AIModelInfo(modelID: "doubao-seed-evolving", name: "Doubao-Seed-Evolving",
                                desc: "深度思考增强版：先思考再回答，Agent 执行与多模态理解更强，适合复杂分析类问题"),
        RemoteConfig.AIModelInfo(modelID: "doubao-seed-2-1-pro-260915", name: "Doubao-Seed-2.1-pro",
                                desc: "旗舰级大模型：推理与生成质量最高，适合复杂推理、深度分析与高质量长文写作"),
        RemoteConfig.AIModelInfo(modelID: "doubao-seed-2-0-lite-260428", name: "Doubao-Seed-2.0-lite",
                                desc: "上一代轻量版：速度快、成本低，适合简单任务与低延迟场景"),
        RemoteConfig.AIModelInfo(modelID: "doubao-seed-2-0-mini-260428", name: "Doubao-Seed-2.0-mini",
                                desc: "轻量小模型：极速响应、极致成本，适合高频轻量问答"),
        RemoteConfig.AIModelInfo(modelID: "doubao-seed-2-0-code-preview-260215", name: "Doubao-Seed-2.0-code",
                                desc: "代码专项模型：代码生成、解释、调试与补全能力更强，适合编程类问题"),
        RemoteConfig.AIModelInfo(modelID: "doubao-seed-character-260628", name: "Doubao-Seed-Character",
                                desc: "角色扮演模型：擅长人设一致的角色对话与沉浸式剧情互动"),
        RemoteConfig.AIModelInfo(modelID: "doubao-smart-router-250928", name: "Doubao-Smart-Router",
                                desc: "智能路由：自动把请求分发给最合适的模型，兼顾效果与成本"),
        // ── DeepSeek 系列 ──
        RemoteConfig.AIModelInfo(modelID: "deepseek-v4-1-flash-261017", name: "DeepSeek-V4.1-Flash",
                                desc: "高性价比快模型：推理能力强、价格低，适合日常问答与批量任务"),
        RemoteConfig.AIModelInfo(modelID: "deepseek-v4-1-flash-economy-261017", name: "DeepSeek-V4.1-Flash经济版",
                                desc: "超低成本版：价格仅为标准版一半，适合高频轻量调用"),
        RemoteConfig.AIModelInfo(modelID: "deepseek-v4-flash-ga-260731", name: "DeepSeek-V4-Flash正式版",
                                desc: "正式版快模型：稳定可用，速度与效果均衡"),
        RemoteConfig.AIModelInfo(modelID: "deepseek-v4-pro-ga-260813", name: "DeepSeek-V4-Pro正式版",
                                desc: "正式版强模型：深度推理能力强，适合复杂分析类问题"),
        // ── 第三方系列 ──
        RemoteConfig.AIModelInfo(modelID: "kimi-k3-1-pro-261024", name: "Kimi-K3.1-Pro",
                                desc: "月之暗面旗舰：超长上下文 + 强推理，适合长文档理解与深度分析"),
        RemoteConfig.AIModelInfo(modelID: "glm-5-2-260617", name: "GLM-5.2",
                                desc: "智谱旗舰：综合能力强，中英文对话与工具调用表现出色"),
        RemoteConfig.AIModelInfo(modelID: "glm-5-3-flash-260828", name: "GLM-5.3-Flash",
                                desc: "智谱快模型：速度优先，适合高频互动场景"),
        RemoteConfig.AIModelInfo(modelID: "glm-4-5-air-20250728", name: "GLM-4.5-Air",
                                desc: "智谱轻量版：低延迟低成本，适合简单问答"),
        RemoteConfig.AIModelInfo(modelID: "qwen3-0-6b-20250429", name: "Qwen3-0.6B",
                                desc: "通义超轻量：极小规模、极速响应，适合简单任务"),
        RemoteConfig.AIModelInfo(modelID: "qwen3-8b-20250429", name: "Qwen3-8B",
                                desc: "通义轻量：开源模型，性价比高，适合日常问答"),
        RemoteConfig.AIModelInfo(modelID: "qwen3-14b-20250429", name: "Qwen3-14B",
                                desc: "通义中等规模：效果与速度平衡，适合一般任务"),
        RemoteConfig.AIModelInfo(modelID: "qwen3-32b-20250429", name: "Qwen3-32B",
                                desc: "通义较强：推理能力更强，适合复杂问题"),
        RemoteConfig.AIModelInfo(modelID: "qwen2-5-72b-20240919", name: "Qwen2.5-72B",
                                desc: "通义旧版强模型：72B 大规模，综合能力扎实")
    ]
    /// 内置 + 云端扩展（去重合并）
    static var allModels: [RemoteConfig.AIModelInfo] {
        var list = builtinModels
        for m in RemoteConfig.aiModels where !list.contains(where: { $0.modelID == m.modelID }) {
            list.append(m)
        }
        return list
    }
    /// 火山方舟账号已开通的模型（2026-10-29 控制台「开通管理」页核实）；
    /// 未开通的模型直接调用会返回 ModelNotOpen(404)，本列表用于设置页实时标注开通状态
    static let activatedModelIDs: Set<String> = [
        "doubao-seed-2-1-turbo-260628",   // Doubao-Seed-2.1-turbo
        "doubao-seed-2-1-lite-260915",    // Doubao-Seed-2.1-lite
        "doubao-seed-evolving"            // Doubao-Seed-Evolving
    ]
    static func isActivated(_ modelID: String) -> Bool {
        activatedModelIDs.contains(modelID)
    }
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
            apiKeySection
            modelSection
            endpointSection
            templateSection
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
            if Self.allModels.contains(where: { $0.modelID == newModel }) {
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

    /// v1.89：当前选中模型的说明（内置/云端合并列表中查找）；v1.93 起带开通状态
    private var currentModelDesc: String {
        if model == "custom" && !modelCustom.isEmpty {
            return "自定义模型：请填写火山方舟已开通模型的完整 ID（如 doubao- 开头）；ID 写错会返回 InvalidEndpointOrModel.NotFound"
        }
        if let m = Self.allModels.first(where: { $0.modelID == model }) {
            let state = Self.isActivated(m.modelID) ? "已开通" : "未开通（需到火山方舟控制台开通）"
            return "【" + state + "】" + m.name + "｜" + m.desc
        }
        return "请选择上方模型查看说明"
    }

    /// v1.93：模型选择器选项文字（带开通状态标注）
    private func modelPickerLabel(_ m: RemoteConfig.AIModelInfo) -> String {
        if Self.isActivated(m.modelID) {
            return m.modelID + "（已开通）"
        }
        return m.modelID + "（未开通）"
    }

    /// v1.93：模型 Section 底部说明（开通状态提示）
    private var modelStatusFooter: String {
        "当前账号已开通：Doubao-Seed-2.1-turbo / Doubao-Seed-2.1-lite / Doubao-Seed-Evolving；其余模型需在火山方舟控制台「开通管理」页开通后调用，未开通会提示模型未开通"
    }

    // MARK: - 设置页分块（v1.93 拆分，避免 body 过大触发类型检查超时）

    private var apiKeySection: some View {
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
    }

    private var modelSection: some View {
        Section {
            Picker("对话模型", selection: $model) {
                ForEach(Self.allModels, id: \.modelID) { m in
                    Text(modelPickerLabel(m)).tag(m.modelID)
                }
                Text("自定义（填下方 ID）").tag("custom")
            }
            TextField("自定义模型 ID（选填，覆盖上方选择）", text: $modelCustom)
                .font(.system(size: 13))
                .autocapitalization(.none)
            Text("输入即保存；保存过自定义 ID 后再次进入会自动回填显示")
                .font(.system(size: 11))
                .foregroundColor(.themeText3)
            // v1.89：当前模型的说明介绍（v1.93 起带开通状态标注）
            VStack(alignment: .leading, spacing: 4) {
                Text("模型说明")
                    .font(.system(size: 12, weight: .semibold))
                Text(currentModelDesc)
                    .font(.system(size: 11.5))
                    .foregroundColor(.themeText2)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.themeBorder.opacity(0.35))
            .cornerRadius(8)
        } footer: {
            Text(modelStatusFooter)
        }
    }

    private var endpointSection: some View {
        Section("接口端点") {
            TextField("API 端点 URL", text: $baseURL)
                .font(.system(size: 12))
                .autocapitalization(.none)
                .keyboardType(.URL)
        }
    }

    private var templateSection: some View {
        Section("偏好模板（调教）") {
            TextEditor(text: $template)
                .frame(minHeight: 110)
                .font(.system(size: 12))
            Text("填写你希望 AI 一直遵守的规则（如：报价只说每月租金；金额精确到元；先结论后明细）。每次对话都会带上。")
                .font(.system(size: 11))
                .foregroundColor(.themeText3)
            // v1.97：一键填入「房产中介场景推荐模板」，可在此基础上修改
            Button {
                template = Self.recommendedTemplate
            } label: {
                Label("填入推荐模板（房产中介场景）", systemImage: "wand.and.stars")
                    .font(.system(size: 13))
            }
            .disabled(template == Self.recommendedTemplate)
        }
    }

    /// v1.97：房产中介场景默认偏好模板（用户可自行修改完善；首次进入 AI 设置自动写入）
    static let recommendedTemplate = """
【身份与口径】
- 我是佛山顺德龙江利保米兰公馆的二房东/房产中介（梁涛），管理米兰公馆 1 座、2 座的多套出租房源。
- 对外沟通一律自称/代称"梁涛"，语气口语化、简体中文，先结论后依据，不用"好的呢"这类敷衍词。

【房号规则】
- 房号带"2-"前缀 = 2 座（如 2-1006），不带前缀 = 1 座（如 1006、2334）；上下层等细分按用户原话保留。

【报价与金额】
- 报价只说每月租金（如"1100/月"），不主动拆算日租/押金，除非用户要求。
- 金额一律精确到元，涉及账单/结算保留到分；汇率、比例、合计用 App 数据现算，不估。

【房源信息】
- 收录房源时按：房号/座/户型/租金/房东/状态（待租或已租）/是否上架/有无实拍图 记录；未提供的信息标"待补充"，不编造。
- 只有用户明确提到"全屋定制"才加该备注；其他户型特征（如中空复式）不自动添加。
- 回答房源相关问题时先检查是否重复收录，发现重复要先提醒。

【操作习惯】
- 写操作（改状态/改信息/收租/删数据）前先向用户复述将执行的内容；执行后汇报"改了谁、房号、多少钱、什么时间"。
- 房源相关的修改记录在云端（共享）；批量操作优先合并执行。

【数据与列表】
- 列出电表/房源/安居客数据时必须完整，不省略中间项；按用户要求排序（如电量从低到高）。
- 用户要文件时用导出工具生成 CSV/Excel 保存到 App 沙盒根目录，并告知文件名。

【保密与合规】
- 不透露租客隐私、不泄露钥匙串里的 API Key；涉及租约纠纷只提供建议与法律渠道，不代签任何文书。
"""

    private func loadFromStorage() {
        apiKey = KeychainHelper.load(key: "ai.volcengine.apiKey") ?? ""
        // v1.97：首次使用自动写入推荐模板（用户可在设置里修改）
        if !UserDefaults.standard.bool(forKey: "ai.templateInitialized") {
            let saved = UserDefaults.standard.string(forKey: "ai.promptTemplate") ?? ""
            if saved.isEmpty {
                template = Self.recommendedTemplate
                UserDefaults.standard.set(Self.recommendedTemplate, forKey: "ai.promptTemplate")
            }
            UserDefaults.standard.set(true, forKey: "ai.templateInitialized")
        }
        apiKey = KeychainHelper.load(key: "ai.volcengine.apiKey") ?? ""
        let saved = UserDefaults.standard.string(forKey: "ai.modelName") ?? Self.defaultModel
        if Self.legacyModels.contains(saved) {
            // 旧版错误短名 → 自动迁移到正确模型 ID 并写回
            storedModel = Self.defaultModel
            model = Self.defaultModel
            modelCustom = ""
        } else if Self.allModels.contains(where: { $0.modelID == saved }) {
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
