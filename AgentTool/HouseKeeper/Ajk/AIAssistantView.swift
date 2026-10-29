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

    enum Role: String, Codable {
        case user, assistant
    }

    init(id: UUID = UUID(), role: Role, text: String, time: Date = Date(),
         images: [String] = [], attachText: String? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.time = time
        self.images = images
        self.attachText = attachText
    }
}

// MARK: - 主界面

struct AIAssistantView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var messages: [AIMessage] = []
    @State private var input = ""
    @State private var sending = false
    @State private var showSettings = false
    @State private var errorText: String?

    /// 附件：待发送的图片（UIImage 源）+ 文件文本
    @State private var pendingImages: [UIImage] = []
    @State private var pendingAttachText: String?
    @State private var pendingAttachName: String?
    @State private var showPhotoPicker = false
    @State private var showFilePicker = false
    @State private var photoPickerItems: [PhotosPickerItem] = []

    /// 历史记录存储键（保留最近 60 条）
    private let historyKey = "ai.chatHistory"
    private let historyLimit = 60

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
                            if sending {
                                thinkingBubble
                                    .id("thinking")
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 12)
                }
                .onChange(of: messages.count) { _ in
                    if let last = messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    } else if sending {
                        withAnimation { proxy.scrollTo("thinking", anchor: .bottom) }
                    }
                }
                .onChange(of: sending) { _ in
                    if sending {
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
        .sheet(isPresented: $showSettings) {
            NavigationStack { AIAssistantSettingsView() }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoPickerItems, maxSelectionCount: 6, matching: .any(of: [.images, .videos]))
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.text, .plainText, .pdf, .json, .commaSeparatedText], allowsMultipleSelection: false) { result in
            handleFileImport(result)
        }
        .alert("提示", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("好", role: .cancel) { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
        .onChange(of: photoPickerItems) { items in
            handlePhotoItems(items)
        }
        .onAppear {
            loadHistory()
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
                                    pendingImages.remove(at: idx)
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

    /// 「正在思考」气泡
    private var thinkingBubble: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Circle().fill(Color.themeText3).frame(width: 6, height: 6)
                    Circle().fill(Color.themeText3).frame(width: 6, height: 6)
                    Circle().fill(Color.themeText3).frame(width: 6, height: 6)
                }
                Text("正在思考…")
                    .font(.system(size: 11))
                    .foregroundColor(.themeText3)
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
            // v1.88：浅色顶栏（按钮深色高对比），高度收窄为标准栏
            Color.themePanel
                .ignoresSafeArea(edges: .top)
            HStack(spacing: 8) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.themeText)
                        .frame(width: 32, height: 32)
                        .background(Color.themeBorder.opacity(0.5))
                        .clipShape(Circle())
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text("AI 助手")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.themeText)
                    Text(modelLabel)
                        .font(.system(size: 9.5))
                        .foregroundColor(.themeText3)
                        .lineLimit(1)
                }
                Spacer()
                if !messages.isEmpty {
                    Button {
                        messages = []
                        saveHistory()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 14))
                            .foregroundColor(.themeText)
                            .frame(width: 32, height: 32)
                            .background(Color.themeBorder.opacity(0.5))
                            .clipShape(Circle())
                    }
                }
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 15))
                        .foregroundColor(.themeText)
                        .frame(width: 32, height: 32)
                        .background(Color.themeBorder.opacity(0.5))
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
            VStack(alignment: msg.role == .user ? .trailing : .leading, spacing: 5) {
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
                if let attach = msg.attachText {
                    Label(attach, systemImage: "paperclip")
                        .font(.system(size: 11))
                        .foregroundColor(.themeAccentDark)
                }
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
        HStack(spacing: 6) {
            // 相册（图片/视频，视频自动截首帧）
            Button {
                showPhotoPicker = true
            } label: {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 15))
                    .foregroundColor(.themeText2)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .disabled(sending)
            // 文件（txt/md/json/csv/pdf，自动提取文本）
            Button {
                showFilePicker = true
            } label: {
                Image(systemName: "paperclip")
                    .font(.system(size: 15))
                    .foregroundColor(.themeText2)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .disabled(sending)
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
            .disabled(sending || (input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pendingImages.isEmpty))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.themePanel.opacity(0.95))
    }

    // MARK: - 发送

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !pendingImages.isEmpty, !sending else { return }
        guard hasKey else {
            errorText = "请先点右上角设置，填写 API Key（只保存在本机钥匙串）"
            return
        }
        // 图片 → data URL（压缩）
        let imageDataURLs = pendingImages.compactMap { compressToDataURL($0) }
        // 附件文件文本拼进本条
        var fullText = text
        if let attach = pendingAttachText, let name = pendingAttachName {
            fullText += "\n\n【附件：\(name)】\n\(attach)"
        }
        let userMsg = AIMessage(role: .user, text: fullText, time: Date(),
                                images: imageDataURLs, attachText: pendingAttachName)
        messages.append(userMsg)
        saveHistory()
        input = ""
        pendingImages = []
        pendingAttachText = nil
        pendingAttachName = nil

        sending = true
        let apiKey = KeychainHelper.load(key: "ai.volcengine.apiKey") ?? ""
        let baseURL = storedBaseURL
        let model = storedModel
        let systemPrompt = buildSystemPrompt()
        // 多轮上下文：除本条外的历史（最多保留最近 40 条，防 token 爆炸；历史图片不重传）
        let history = Array(messages.dropLast().suffix(40)).compactMap { msg -> AIRequestService.ChatTurn? in
            guard !msg.text.isEmpty else { return nil }
            return AIRequestService.ChatTurn(role: msg.role == .user ? "user" : "assistant", text: msg.text)
        }
        Task {
            do {
                let reply = try await AIRequestService.send(apiKey: apiKey, baseURL: baseURL, model: model,
                                                            systemPrompt: systemPrompt, history: history,
                                                            userText: fullText, userImages: imageDataURLs)
                messages.append(AIMessage(role: .assistant, text: reply, time: Date()))
                saveHistory()
            } catch {
                errorText = error.localizedDescription
            }
            sending = false
        }
    }

    // MARK: - 系统提示 + 数据快照（v1.88：接入 App 本地房源数据）

    private func buildSystemPrompt() -> String {
        let base = AIAssistantSettingsView.defaultSystemPrompt
            + (storedTemplate.isEmpty ? "" : "\n\n【我的偏好要求】\n\(storedTemplate)")
        let snapshot = houseDataSnapshot()
        guard !snapshot.isEmpty else { return base }
        return base + "\n\n【当前 App 房源数据快照（只读参考，涉及房源数量/租金/状态的问题据此回答，不要编造）】\n\(snapshot)"
    }

    /// 从本地 SwiftData 拉取房源，生成文本快照注入系统提示
    private func houseDataSnapshot() -> String {
        let houses = (try? modelContext.fetch(FetchDescriptor<House>())) ?? []
        let active = houses.filter { !($0.isDeleted ?? false) }
        guard !active.isEmpty else { return "" }
        let rented = active.filter { $0.status == .rented }.count
        let available = active.count - rented
        var lines = ["共 \(active.count) 套（不含回收站）；待租 \(available) 套 / 已租 \(rented) 套"]
        for h in active.sorted(by: { $0.roomNo < $1.roomNo }) {
            let status = h.status == .rented ? "已租" : "待租"
            var line = "房号\(h.roomNo)（\(h.tower)座）户型\(h.layout) 租金\(h.price)元 房东\(h.landlord) 状态\(status)"
            if !h.remark.isEmpty { line += " 备注\(h.remark)" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 历史记录持久化（保留最近 60 条；图片不持久化，控制体积）

    private func loadHistory() {
        guard let data = UserDefaults.standard.data(forKey: historyKey),
              let arr = try? JSONDecoder().decode([AIMessage].self, from: data) else { return }
        messages = arr
    }

    private func saveHistory() {
        let recent = Array(messages.suffix(historyLimit))
        // 图片 data URL 不入库（避免 UserDefaults 膨胀），只保留文本与附件名
        let slim = recent.map { msg -> AIMessage in
            guard !msg.images.isEmpty else { return msg }
            return AIMessage(id: msg.id, role: msg.role, text: msg.text, time: msg.time,
                             images: [], attachText: msg.attachText)
        }
        if let data = try? JSONEncoder().encode(slim) {
            UserDefaults.standard.set(data, forKey: historyKey)
        }
    }

    // MARK: - 附件处理

    /// 相册选择结果：图片直接加，视频截取首帧当图片发
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
                        errorText = "视频首帧提取失败，请改发图片"
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
            errorText = "该文件类型暂不支持读取内容（支持 txt/md/json/csv/pdf）"
        } catch {
            errorText = "文件读取失败：\(error.localizedDescription)"
        }
    }

    /// 图片压缩到长边 1280、JPEG 0.7，转 data URL
    private func compressToDataURL(_ img: UIImage) -> String? {
        let maxSide: CGFloat = 1280
        var target = img
        let side = max(img.size.width, img.size.height)
        if side > maxSide {
            let scale = maxSide / side
            let newSize = CGSize(width: img.size.width * scale, height: img.size.height * scale)
            UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
            img.draw(in: CGRect(origin: .zero, size: newSize))
            target = UIGraphicsGetImageFromCurrentImageContext() ?? img
            UIGraphicsEndImageContext()
        }
        guard let data = target.jpegData(compressionQuality: 0.7) else { return nil }
        return "data:image/jpeg;base64,\(data.base64EncodedString())"
    }

    /// 视频取首帧
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
