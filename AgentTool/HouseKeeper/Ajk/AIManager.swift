//
//  AIManager.swift
//  公寓管家 · AI 任务管理器（v1.97）
//  职责：
//   - 全局单例持有对话与执行状态，AI 对话页关闭/重开不影响正在执行的任务（App 划掉才终止）
//   - 发送排队：AI 思考/执行期间仍可继续输入发送，当前任务完成后自动发送下一条
//   - 系统确认框状态全局化：页面关闭时写操作确认挂起，重开页面自动弹出继续确认
//   - 回复预选项解析（AI 输出 JSON suggestions → 气泡下方快捷 chips）
//   - 欢迎页 10 分钟冷却：超时未对话再次进入重新展示问候语与场景预选项
//

import Foundation
import SwiftUI
import SwiftData

@MainActor
final class AIManager: ObservableObject {

    static let shared = AIManager()
    private init() {}

    // MARK: - 全局对话状态（页面关闭保留，重开恢复）

    @Published var messages: [AIMessage] = []
    @Published var sending = false
    @Published var toolPhase: String?
    @Published var errorText: String?
    @Published var pendingToolCalls: [AIRequestService.AIToolCall]?
    @Published var pendingToolSummaries: [String] = []
    @Published var pendingConfirm = false
    /// 排队待发送条数（sending 期间继续发送时递增，显示在发送按钮角标）
    @Published var queuedCount = 0
    /// 欢迎页（问候语+场景预选项）是否展示；对话后隐藏，超 10 分钟无对话再次进入重新展示
    @Published var showWelcome = true
    /// 上次对话时间（欢迎页冷却判断）
    @Published var lastActiveAt = Date.distantPast

    /// 确认框回调容器（class 引用语义，跨 alert 回调稳定可用）
    final class ToolConfirmBox {
        var continuation: CheckedContinuation<Bool, Never>?
    }
    let confirmBox = ToolConfirmBox()

    /// 待发送消息队列（sending 期间的新消息排队，当前任务完成后自动发送）
    private struct PendingSend {
        let text: String
        let images: [String]      // data URL（已压缩）
        let attachText: String?
        let attachName: String?
    }
    private var queue: [PendingSend] = []

    /// SwiftData 容器（每次 send 从页面注入并保存，页面关闭期间保留引用）
    private var modelContext: ModelContext?
    private var houseModelContext: ModelContext?

    private let historyKey = "ai.chatHistory"
    // v1.98：历史不再按条数截断，改按时间保留最近 1 年（见 loadHistory/saveHistory）

    // MARK: - 页面生命周期

    /// 页面出现：加载历史 + 欢迎页冷却判定（超过 10 分钟无对话 → 重新展示问候语/场景预选项）
    func onAppear(modelContext: ModelContext, houseModelContext: ModelContext?) {
        self.modelContext = modelContext
        self.houseModelContext = houseModelContext
        if messages.isEmpty { loadHistory() }
        reviewWelcome()
    }

    /// 欢迎页冷却：无消息或距上次对话超 10 分钟 → 展示
    func reviewWelcome() {
        if messages.isEmpty {
            showWelcome = true
        } else if let last = messages.last, Date().timeIntervalSince(last.time) > 600 {
            showWelcome = true
        } else {
            showWelcome = false
        }
    }

    // MARK: - 发送（支持排队）

    /// 用户点发送：无图无文字不响应；未配置 Key 提示；执行中则入队（sending 期间仍可发）
    func send(userText: String, images: [UIImage], attachText: String?, attachName: String?) {
        let text = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !images.isEmpty else { return }
        guard UserDefaults.standard.bool(forKey: "ai.apiKeyConfigured") else {
            errorText = "请先点右上角设置，填写 API Key（只保存在本机钥匙串）"
            return
        }
        let imageDataURLs = images.compactMap { compressToDataURL($0) }
        var fullText = text
        if let attach = attachText, let name = attachName {
            fullText += "\n\n【附件：\(name)】\n\(attach)"
        }
        let userMsg = AIMessage(role: .user, text: fullText, time: Date(),
                                images: imageDataURLs, attachText: attachName)
        messages.append(userMsg)
        lastActiveAt = Date()
        showWelcome = false
        saveHistory()

        if sending {
            // 排队：当前任务完成后自动发送
            queue.append(PendingSend(text: fullText, images: imageDataURLs, attachText: attachText, attachName: attachName))
            queuedCount = queue.count
            return
        }
        startRun(fullText: fullText, imageDataURLs: imageDataURLs)
    }

    /// 发送一条预选项/快捷指令（不附带附件）
    func sendQuick(_ text: String) {
        send(userText: text, images: [], attachText: nil, attachName: nil)
    }

    /// 确认框回调：true=执行 / false=取消
    func confirm(accept: Bool) {
        pendingToolCalls = nil
        pendingToolSummaries = []
        pendingConfirm = false
        confirmBox.continuation?.resume(returning: accept)
        confirmBox.continuation = nil
    }

    /// 清空对话
    func clearChat() {
        messages = []
        queue = []
        queuedCount = 0
        saveHistory()
        reviewWelcome()
    }

    // MARK: - 核心执行（后台任务，页面关闭不中断）

    private func startRun(fullText: String, imageDataURLs: [String]) {
        guard let mc = modelContext, let hc = houseModelContext else {
            errorText = "数据容器不可用，请重新打开 AI 助手"
            return
        }
        sending = true
        toolPhase = "正在思考…"
        let apiKey = KeychainHelper.load(key: "ai.volcengine.apiKey") ?? ""
        let baseURL = UserDefaults.standard.string(forKey: "ai.baseURL") ?? AIRequestService.defaultBaseURL
        let model = UserDefaults.standard.string(forKey: "ai.modelName") ?? AIAssistantSettingsView.defaultModel
        // 多轮上下文：除本条外的历史（v1.98：40→20 条，prompt 减半、首字更快；历史仍全量本地保存 1 年）
        let history = Array(messages.dropLast().suffix(20)).compactMap { msg -> AIRequestService.ChatTurn? in
            guard !msg.text.isEmpty else { return nil }
            return AIRequestService.ChatTurn(role: msg.role == .user ? "user" : "assistant", text: msg.text)
        }

        // 任务保存在属性上：View 关闭不取消；App 划掉进程终止
        let task = Task {
            // 发送前实时拉取云端用量（失败给提示不阻断）
            let cloudUsage = await fetchCloudUsageText()
            let systemPrompt = buildSystemPrompt(cloudUsage: cloudUsage)
            var messages: [[String: Any]] = [["role": "system", "content": systemPrompt]]
            for turn in history {
                messages.append(["role": turn.role, "content": turn.text])
            }
            if !imageDataURLs.isEmpty {
                var content: [Any] = []
                for url in imageDataURLs {
                    content.append(["type": "image_url", "image_url": ["url": url]])
                }
                content.append(["type": "text", "text": fullText])
                messages.append(["role": "user", "content": content])
            } else {
                messages.append(["role": "user", "content": fullText])
            }
            var executedLabels: [String] = []
            var finalText: String?
            // v1.98：工具结果若带【图片】路径标记，提取展示在气泡；v1.98：支持多张（多套房账单各一张，按生成顺序）
            var toolImagePaths: [String] = []
            do {
                // v1.97：工具循环上限提到 6 轮（批量/多动作场景不再被 3 轮截断）
                for _ in 0..<6 {
                    let completion = try await AIRequestService.sendMessages(apiKey: apiKey, baseURL: baseURL,
                                                                             model: model, messages: messages,
                                                                             tools: AIToolExecutor.toolSchemas)
                    if completion.toolCalls.isEmpty {
                        finalText = completion.content ?? ""
                        break
                    }
                    // 回填 assistant tool_calls 消息
                    let assistantMsg: [String: Any] = [
                        "role": "assistant",
                        "content": completion.content ?? "",
                        "tool_calls": completion.toolCalls.map { call -> [String: Any] in
                            ["id": call.id, "type": "function",
                             "function": ["name": call.name, "arguments": call.arguments]]
                        }
                    ]
                    messages.append(assistantMsg)
                    // 写操作 → 系统确认框；页面关闭时挂起，重开页面继续弹出
                    toolPhase = "等待你确认操作…"
                    let confirmed = await confirmToolCalls(completion.toolCalls)
                    guard confirmed else {
                        for call in completion.toolCalls {
                            messages.append(["role": "tool", "tool_call_id": call.id,
                                             "content": "用户取消了该操作，未执行任何更改"])
                        }
                        finalText = "已取消本次操作（未执行任何更改）。需要调整的话告诉我新的指令。"
                        break
                    }
                    // 执行全部工具调用，结果回填
                    toolPhase = "正在执行操作…"
                    var executor = AIToolExecutor(modelContext: mc, houseModelContext: hc)
                    // v1.98：执行过程中实时上报具体步骤（如「正在抄表 012030（2/3）」「正在生成 1-2319 账单图片」）
                    executor.phase = { [weak self] step in
                        self?.toolPhase = step
                    }
                    var labels: [String] = []
                    for call in completion.toolCalls {
                        let label = actionLabel(for: call)
                        toolPhase = "正在执行：\(label)…"
                        let resultText = await executor.execute(tool: call)
                        labels.append(label)
                        // v1.98：工具结果若带【图片】路径标记，提取出来展示在对话气泡（如 AI 生成的账单图）
                        // v1.98：多张图片全部收集（每套房账单一张），按生成顺序展示
                        if let imgMark = resultText.range(of: "【图片】") {
                            let path = String(resultText[imgMark.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                            if !path.isEmpty, !toolImagePaths.contains(path) {
                                toolImagePaths.append(path)
                            }
                        }
                        messages.append(["role": "tool", "tool_call_id": call.id, "content": resultText])
                    }
                    executedLabels.append(contentsOf: labels)
                    toolPhase = "正在整理回复…"
                }
                if finalText == nil {
                    finalText = "操作已完成（见上方动作标签）。如需继续调整，直接告诉我。"
                }
                let (cleanText, suggestions) = Self.parseSuggestions(finalText!)
                self.messages.append(AIMessage(role: .assistant, text: cleanText, time: Date(),
                                               toolSummary: executedLabels, suggestedActions: suggestions,
                                               imagePath: toolImagePaths.first, imagePaths: toolImagePaths))
                saveHistory()
            } catch {
                // 超时/网络错误给中文提示
                if let ue = error as? URLError, ue.code == .timedOut {
                    errorText = "请求超时：模型响应较慢（工具定义多或生成内容较长），已自动重试可稍后再试；生成账单类任务请用「生成 XX 房 XX 月账单」让 AI 直接调用工具生成，速度更快。"
                } else if let ue = error as? URLError, ue.code == .notConnectedToInternet {
                    errorText = "网络不可用，请检查网络后重试"
                } else {
                    errorText = error.localizedDescription
                }
            }
            sending = false
            toolPhase = nil
            // 处理排队消息（自动发送下一条）
            if !queue.isEmpty {
                let next = queue.removeFirst()
                queuedCount = queue.count
                let text = next.text
                let imgs = next.images
                DispatchQueue.main.async { [weak self] in
                    self?.startRun(fullText: text, imageDataURLs: imgs)
                }
            }
        }
        _ = task
    }

    // MARK: - 工具确认与标签

    /// 过滤出需确认的写操作并弹系统确认框（全局状态：页面关闭时挂起，重开自动弹出）；无写操作直接放行
    private func confirmToolCalls(_ calls: [AIRequestService.AIToolCall]) async -> Bool {
        let needing = calls.filter { call in
            AIToolExecutor.needsConfirm(toolName: call.name, actionType: actionType(of: call))
        }
        if needing.isEmpty { return true }
        pendingToolSummaries = needing.map { call in
            let args = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8)) as? [String: Any]) ?? [:]
            return AIToolExecutor.summary(toolName: call.name, arguments: args)
        }
        pendingToolCalls = needing
        return await withCheckedContinuation { cont in
            confirmBox.continuation = cont
            pendingConfirm = true
        }
    }

    private func actionType(of call: AIRequestService.AIToolCall) -> String {
        let args = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8)) as? [String: Any]) ?? [:]
        return args["action_type"] as? String ?? ""
    }

    /// 紧凑动作标签（气泡展示，如「房源·2334 已租」「收租·2-1006 已收」）
    private func actionLabel(for call: AIRequestService.AIToolCall) -> String {
        let args = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8)) as? [String: Any]) ?? [:]
        let rooms = args["room_nos"] as? [String]
        let room = args["room_no"] as? String ?? rooms?.first ?? ""
        let action = actionType(of: call)
        switch (call.name, action) {
        case ("update_property", "add_house"): return "房源·新增 \(room)"
        case ("update_property", "edit_field"): return "房源·编辑 \(room)"
        case ("update_property", "change_status"):
            let status = args["status"] as? String ?? ""
            return "房源·\(room) \(status == "rented" || status == "已租" ? "已租" : "待租")"
        case ("update_property", "delete_house"): return "房源·移入回收站 \(room)"
        case ("update_property", "restore_trash"): return "房源·还原 \(room)"
        case ("update_property", "share_house"): return "房源·生成分享 \(room)"
        case ("record_finance", "record_rent"): return "收租·\(room) 已收"
        case ("record_finance", "unrecord_rent"): return "收租·\(room) 已取消"
        case ("record_finance", "edit_rent_setting"): return "收租·\(room) 设置"
        case ("record_finance", "record_deal"): return "成交·\(room)"
        case ("record_finance", "record_income"): return "杂项·收入"
        case ("record_finance", "record_expense"): return "杂项·支出"
        case ("record_finance", "edit_misc"): return "杂项·编辑"
        case ("record_finance", "delete_misc"): return "杂项·删除"
        case ("record_finance", "utility_settle"): return "水电·\(room) 结算"
        case ("manage_todo", "add"): return "待办·新增"
        case ("manage_todo", "complete"): return "待办·完成"
        case ("manage_todo", "reopen"): return "待办·恢复"
        case ("manage_todo", "edit"): return "待办·编辑"
        case ("manage_todo", "delete"): return "待办·删除"
        case ("refresh_data", "refresh_meters"): return "电表·刷新"
        case ("refresh_data", "query_meters"):
            let uids = args["uids"] as? [String] ?? []
            let rooms = args["room_nos"] as? [String] ?? []
            return "电表·抄表 \((uids + rooms).joined(separator: "、"))"
        case ("refresh_data", "refresh_ajk"): return "安居客·刷新"
        case ("refresh_data", "create_quick_backup"): return "备份·快速"
        case ("refresh_data", "create_full_backup"): return "备份·全量"
        case ("refresh_data", "list_backups"): return "备份·列表"
        case ("refresh_data", "sync_status"): return "同步·状态"
        case ("teach_action", _): return "教学·\(args["action_name"] as? String ?? "")"
        case ("manage_meter", "set_low_alert"): return "电表·预警设置"
        case ("manage_meter", "set_auto_refresh"): return "电表·定时刷新"
        case ("query_report", "overdue_list"): return "报表·欠租"
        case ("query_report", "lease_expiry"): return "报表·到期"
        case ("query_report", "rent_summary"): return "报表·收租汇总"
        case ("query_report", "utility_settle"): return "报表·水电结算"
        case ("query_report", "generate_rent_bill"): return "账单·\(room) \(args["month"] as? Int ?? 0)月"
        case ("query_report", "generate_rent_bill_image"): return "账单图·\(room) \(args["month"] as? Int ?? 0)月"
        case ("export_data", "export_excel"): return "导出·\(args["data_type"] as? String ?? "")"
        case ("web_search", "search"): return "联网·搜索"
        default: return call.name + "·" + action
        }
    }

    // MARK: - 预选项解析

    /// 从 AI 回复中提取预选项 JSON，返回（正文，预选项数组）
    /// 约定：AI 在回复末尾输出 【预选项】{"suggestions":["..",".."]}，最多 3 个
    static func parseSuggestions(_ text: String) -> (String, [String]?) {
        guard let range = text.range(of: "【预选项】") else { return (text, nil) }
        let jsonPart = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = jsonPart.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["suggestions"] as? [String] else { return (text, nil) }
        let clean = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (clean, Array(arr.prefix(3)))
    }

    // MARK: - 系统提示 + 数据快照（v1.97：安居客全量明细 + 电表全量 + 预选项/联网/导出规则）

    private func buildSystemPrompt(cloudUsage: String = "") -> String {
        var base = AIAssistantSettingsView.defaultSystemPrompt
            + (UserDefaults.standard.string(forKey: "ai.promptTemplate")?.isEmpty == false
               ? "\n\n【我的偏好要求】\n\(UserDefaults.standard.string(forKey: "ai.promptTemplate") ?? "")" : "")
        // v1.96：工具调用能力说明
        base += "\n\n【工具操作能力】你可以调用工具直接执行 App 内的操作：新增/编辑房源、切换待租已租、移入回收站、标记收租、记成交与杂项、管理待办、刷新电表/安居客、新建备份、设置电表预警与定时刷新、查询欠租/租约到期/收租汇总、生成收租账单、导出 Excel/CSV 文件、联网搜索资料。调用规则：①参数名用工具定义里的字段（如 room_no、action_type），房号按用户规则（2- 前缀=2座）；②凡是写操作（新增/修改/删除/备份）系统都会先弹确认框，确认后我才执行，你不需要征求用户意见，也不要擅自替用户编造数据；③执行结果会以 tool 结果返回给你，你必须在最终回复里用大白话向用户汇报：改了什么（改了谁/房号）、多少钱、什么时间、结果如何；④批量类操作（如一次切换多套已租）优先用批量字段一次性完成；⑤查询类工具（query_report/export_data/web_search）可直接调用，不会打扰用户。"
        // v1.98：抄表与教学规则
        base += "\n\n【抄表与自定义操作规则（v1.98）】①用户指定某几个表号/房号抄表时，必须调用 refresh_data 的 query_meters 动作只抄指定表（绝不要刷新全部电表）；②用户指定的表号不在绑定列表时，query_meters 会自动添加后再抄，你直接调用即可，不要回答「暂不支持」；③用户教你的复合操作（先说出操作名、再一步步步骤）用 teach_action 记录，之后用户说该操作名就直接按步骤展开执行。"
        // v1.98：已教学操作注入
        base += AIToolExecutor.taughtActionsSummary()
        // v1.97：回复格式要求（预选项 + 长内容收敛）
        base += "\n\n【回复格式要求（v1.97）】①回答完每轮对话后，在结尾附上 2-3 个最可能的下一个指令预选项，格式必须严格为一行：【预选项】{\"suggestions\":[\"选项1\",\"选项2\"]}（JSON 里中文引号不可用，用英文双引号；最多 3 个；如果用户指令不需要后续动作可不给）；②涉及列表类内容（电表、房源、安居客）必须完整列出，不要省略中间项；③生成账单任务必须调用 generate_rent_bill 工具获取账单文本，然后只给用户摘要+金额，不要自行编造长账单；④用户要求导出文件时调用 export_data 工具生成并告知保存位置。"
        // 房源（独立容器）
        let house = houseDataSnapshot()
        if !house.isEmpty { base += "\n\n【房源数据快照（只读参考，涉及房源数量/租金/状态的问题据此回答，不要编造）】\n" + house }
        // 主容器经营数据
        let appData = appDataSnapshot()
        if !appData.isEmpty { base += "\n\n【App 经营数据快照（收支/待办/电表/安居客，只读参考，据实回答）】\n" + appData }
        // v1.95：云端用量
        if !cloudUsage.isEmpty { base += "\n\n【云端用量（实时拉取，据实回答）】\n" + cloudUsage }
        return base
    }

    /// v1.95：实时拉取腾讯云桶用量（云函数 act=usage；未配置/失败返回提示，不阻断发送）
    /// v1.98：加缓存——成功缓存 5 分钟、失败缓存 60 秒，避免每次发消息前都串行等网络（慢的根因之一）
    private var usageCache: (text: String, time: Date)?
    private func fetchCloudUsageText() async -> String {
        // 命中缓存直接返回，不发请求
        if let cache = usageCache,
           Date().timeIntervalSince(cache.time) < (cache.text.contains("拉取失败") ? 60 : 300) {
            return cache.text
        }
        guard !CloudConfig.functionURL.isEmpty, !CloudConfig.passwordHash.isEmpty,
              let url = URL(string: "\(CloudConfig.functionURL)?act=usage&k=\(CloudConfig.passwordHash)") else {
            return "云端用量：未配置云函数地址或密钥（设置→云端配置），无法拉取"
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4 // v1.98：8s→4s，减少对首条回复的拖累
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let obj = try? JSONDecoder().decode(UsageResponse.self, from: data), obj.ok {
                let mb = Double(obj.total) / 1024.0 / 1024.0
                let text = "腾讯云桶共 \(obj.total_files) 个文件，占用 \(String(format: "%.1f", mb)) MB"
                usageCache = (text, Date())
                return text
            }
            let text = "云端用量：拉取失败（请确认云函数已部署）"
            usageCache = (text, Date())
            return text
        } catch {
            let text = "云端用量：拉取失败（网络不可用或超时）"
            usageCache = (text, Date())
            return text
        }
    }

    /// 房源快照（House 容器）
    private func houseDataSnapshot() -> String {
        guard let hc = houseModelContext else { return "" }
        let houses = (try? hc.fetch(FetchDescriptor<House>())) ?? []
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

    /// App 经营数据快照（收支/待办/电表/安居客）
    private func appDataSnapshot() -> String {
        guard let mc = modelContext else { return "" }
        var lines: [String] = []
        let cal = Calendar.current
        let now = Date()
        let ym = cal.dateComponents([.year, .month], from: now)

        // ---- 收支 ----
        let activeProps = (try? mc.fetch(FetchDescriptor<Property>(predicate: #Predicate { !$0.isDeleted }))) ?? []
        let rentingProps = activeProps.filter { !$0.isTerminated }
        let rents = (try? mc.fetch(FetchDescriptor<RentMonthRecord>())) ?? []
        let monthRents = rents.filter { $0.year == ym.year && $0.month == ym.month }
        let totalRent = monthRents.reduce(0.0) { $0 + $1.amount }
        let paidRent = monthRents.filter { $0.isPaid }.reduce(0.0) { $0 + $1.amount }
        if !rentingProps.isEmpty || !monthRents.isEmpty {
            lines.append("收租中房源 \(rentingProps.count) 套；本月(\(ym.year)-\(ym.month))应收租金 \(Self.fmtYuan(totalRent)) 元，已收 \(Self.fmtYuan(paidRent)) 元，未收 \(Self.fmtYuan(totalRent - paidRent)) 元")
        }
        let utility = (try? mc.fetch(FetchDescriptor<UtilitySettlementRecord>(predicate: #Predicate { !$0.isSettled }))) ?? []
        if !utility.isEmpty {
            let totalU = utility.reduce(0.0) { $0 + $1.electricAmount + $1.waterAmount }
            lines.append("未结清水电结算 \(utility.count) 笔，合计约 \(Self.fmtYuan(totalU)) 元")
        }
        let incs = (try? mc.fetch(FetchDescriptor<MiscIncome>(predicate: #Predicate { !$0.isDeleted }))) ?? []
        let exps = (try? mc.fetch(FetchDescriptor<MiscExpense>(predicate: #Predicate { !$0.isDeleted }))) ?? []
        let monthIncs = incs.filter { cal.isDate($0.date, equalTo: now, toGranularity: .month) }
        let monthExps = exps.filter { cal.isDate($0.date, equalTo: now, toGranularity: .month) }
        if !monthIncs.isEmpty || !monthExps.isEmpty {
            let sumInc = monthIncs.reduce(0.0) { $0 + $1.amount }
            let sumExp = monthExps.reduce(0.0) { $0 + $1.amount }
            lines.append("本月杂项收入 \(Self.fmtYuan(sumInc)) 元（\(monthIncs.count)笔）、杂项支出 \(Self.fmtYuan(sumExp)) 元（\(monthExps.count)笔）")
        }

        // ---- 待办 ----
        let todos = (try? mc.fetch(FetchDescriptor<TodoItem>(predicate: #Predicate { !$0.isCompleted && !$0.isDeleted }))) ?? []
        if !todos.isEmpty {
            let top = todos.sorted { $0.sortOrder < $1.sortOrder }.prefix(20)
            var t = "未完成待办 \(todos.count) 条"
            let tList = top.map { $0.content.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if !tList.isEmpty { t += "：" + tList.joined(separator: "；") }
            lines.append(t)
        }

        // ---- 电表（v1.97：全量列出，不再截断 15 条）----
        let meters = MeterStore.shared.meters
        if !meters.isEmpty {
            let low = meters.filter { $0.isLow(threshold: MeterStore.shared.settings.lowThreshold) }
            var m = "电表共 \(meters.count) 个（按剩余电量从低到高）："
            let sorted = meters.sorted { $0.shengyu < $1.shengyu }
            let descs = sorted.map { mm -> String in
                let room = mm.room.isEmpty ? mm.uid : mm.room
                return "\(room)剩\(Int(mm.shengyu))度\(mm.zhuangtai)"
            }
            m += descs.joined(separator: "；")
            if !low.isEmpty { m += "；其中低电量预警 \(low.count) 个（低于 \(Int(MeterStore.shared.settings.lowThreshold)) 度）" }
            lines.append(m)
        }

        // ---- 安居客（v1.97：概览 + 每套房源明细全量，支持按点击量/推广等分析）----
        let ajk = AjkStore.shared
        if let fetch = ajk.lastFetch {
            var a = "安居客(上次抓取 \(Self.timeStr(fetch)))：共 \(ajk.overview.totalHouses) 套房源；今日点击合计 \(ajk.overview.todayClickTotal) 次；推广 \(ajk.overview.promotedCount) 套；剩余端口 \(ajk.overview.portCount)；套餐剩 \(ajk.overview.packageDays) 天；神奇分 \(ajk.overview.score)；房产币 \(ajk.overview.coin)；全城排名 \(ajk.overview.cityRank)"
            lines.append(a)
            if !ajk.houses.isEmpty {
                let sortedByClick = ajk.houses.sorted { $0.todayClick > $1.todayClick }
                var h = "每套房源明细（今日点击从高到低）："
                let detail = sortedByClick.map { hh -> String in
                    var s = "\(hh.number)「\(hh.title)」今日点击\(hh.todayClick) 累计\(hh.totalClick) 租金\(hh.price) \(hh.layout)"
                    if !hh.promotions.isEmpty { s += " 推广:\(hh.promotions.joined(separator: "/"))" }
                    if !hh.platforms.isEmpty { s += " 平台:\(hh.platforms.joined(separator: "/"))" }
                    if hh.houseStateDays >= 7 { s += " 房态\(hh.houseStateDays)天(需核验)" }
                    return s
                }
                h += detail.joined(separator: "\n")
                lines.append(h)
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func fmtYuan(_ v: Double) -> String {
        String(format: "%.2f", v)
    }

    private static func timeStr(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: d)
    }

    // MARK: - 历史记录持久化

    private func loadHistory() {
        guard let data = UserDefaults.standard.data(forKey: historyKey),
              let arr = try? JSONDecoder().decode([AIMessage].self, from: data) else { return }
        var seen = Set<UUID>()
        // v1.98：只保留最近 1 年（兼容旧版本超期数据）
        let cutoff = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()
        messages = arr.filter { $0.time >= cutoff && seen.insert($0.id).inserted }
    }

    // v1.98：历史保存策略改为"保留最近 1 年"，不再按 60 条截断
    private func saveHistory() {
        let cutoff = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()
        let recent = messages.filter { $0.time >= cutoff }
        let slim = recent.map { msg -> AIMessage in
            // v1.98：历史精简时保留 imagePath（账单图片是本地沙盒文件，路径可长期复用）；v1.98：多图 imagePaths 一并保留
            guard !msg.images.isEmpty else { return msg }
            return AIMessage(id: msg.id, role: msg.role, text: msg.text, time: msg.time,
                             images: [], attachText: msg.attachText, toolSummary: msg.toolSummary,
                             suggestedActions: msg.suggestedActions, imagePath: msg.imagePath,
                             imagePaths: msg.imagePaths)
        }
        if let data = try? JSONEncoder().encode(slim) {
            UserDefaults.standard.set(data, forKey: historyKey)
        }
    }

    // MARK: - 图片处理（与页面共用）

    func compressToDataURL(_ img: UIImage) -> String? {
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
}
