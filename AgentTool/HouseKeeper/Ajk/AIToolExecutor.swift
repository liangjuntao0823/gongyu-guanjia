//
//  AIToolExecutor.swift
//  公寓管家 · AI 工具执行器（v1.96）
//  六大领域工具：update_property / record_finance / manage_todo / refresh_data / manage_meter / query_report
//  约定：
//   - 所有写操作必须先经 AIAssistantView 确认框确认，确认后本执行器执行
//   - 写操作成功执行后统一写操作日志（BackupLogStore），action 带（AI）标识，与手动操作区分
//   - 执行结果以纯文本返回，由 AI 回填后组织最终回复（改了谁/多少钱/什么时间）
//

import Foundation
import SwiftData
import SwiftUI

/// @MainActor：内部访问 MeterStore/AjkStore/SyncStore/BackupV5Manager 等主线程隔离单例
@MainActor
struct AIToolExecutor {

    let modelContext: ModelContext        // 主容器：Property / DealRecord / MiscIncome / MiscExpense / TodoItem / Utility*
    let houseModelContext: ModelContext?  // 房源容器：House / MediaItem

    /// v1.98：执行过程中的实时步骤上报（AIManager 注入，驱动「正在思考」气泡展示具体执行到哪一步）
    var phase: ((String) -> Void)?

    // MARK: - AI 产物统一存储（v1.98）
    // 规则：AI 生成的账单图片、导出文件等产物统一存沙盒根目录「AI产物」文件夹；
    // 设置页「AI对话缓存」条目显示其大小并可一键清空（二级确认）。

    /// AI 产物根目录：Documents/AI产物/
    static func aiArtifactDir() -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AI产物", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// AI 产物目录大小（字节，递归统计）
    static func aiArtifactSizeBytes() -> Int64 {
        let dir = aiArtifactDir()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey], options: []) else { return 0 }
        var total: Int64 = 0
        for f in files {
            let isDir = (try? f.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir, let sub = try? FileManager.default.subpathsOfDirectory(atPath: f.path) {
                for p in sub {
                    let full = f.appendingPathComponent(p)
                    if let size = (try? full.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                        total += Int64(size)
                    }
                }
            } else if let size = (try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    /// 清空 AI 产物文件夹（设置页二级确认后调用）
    static func clearAIArtifacts() {
        let dir = aiArtifactDir()
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: []) {
            for f in files { try? FileManager.default.removeItem(at: f) }
        }
    }

    // MARK: - 已教学的自定义操作（v1.98「AI 可教学」）
    // 用户可用指令一步步教 AI 完成代码里没有的复合操作：AI 把操作名+步骤存本地规则库，
    // 之后用户说出该操作名时，AI 直接把步骤展开为多个工具调用一次性执行。

    /// 教学规则库存储键
    static let taughtActionsKey = "ai.taughtActions"

    /// 一个教学步骤（arguments 为完整参数 JSON 字符串，AI 可直接构造工具调用）
    struct TaughtStep: Codable {
        let tool: String
        let arguments: String
        let description: String
    }

    /// 一个已教学操作
    struct TaughtAction: Codable {
        let name: String
        let steps: [TaughtStep]
    }

    /// 读本地教学规则库
    static func loadTaughtActions() -> [TaughtAction] {
        guard let data = UserDefaults.standard.data(forKey: taughtActionsKey),
              let arr = try? JSONDecoder().decode([TaughtAction].self, from: data) else { return [] }
        return arr
    }

    static func saveTaughtActions(_ actions: [TaughtAction]) {
        if let data = try? JSONEncoder().encode(actions) {
            UserDefaults.standard.set(data, forKey: taughtActionsKey)
        }
    }

    /// 教学步骤只允许引用这些已注册工具
    static let knownToolNames: Set<String> = [
        "update_property", "record_finance", "manage_todo", "refresh_data",
        "manage_meter", "query_report", "export_data", "web_search"
    ]

    /// 教学规则库摘要文本（注入 systemPrompt，AI 知道有哪些已学会的操作）
    static func taughtActionsSummary() -> String {
        let actions = loadTaughtActions()
        guard !actions.isEmpty else { return "" }
        var lines = ["【你已学会的自定义操作（用户教过你的）】"]
        for act in actions {
            let steps = act.steps.enumerated().map { "第\($0.offset + 1)步 \($0.element.tool)：\($0.element.description)" }
            lines.append("- 操作名「\(act.name)」：\n  " + steps.joined(separator: "\n  "))
        }
        lines.append("规则：当用户说出某个已学会的操作名时，你必须把该操作的每一步展开为对应的工具调用，一次性返回全部 tool_calls 依次执行（不要问用户怎么做，直接照步骤做）；参数值按用户本次指令和 App 数据补全。")
        return "\n\n" + lines.joined(separator: "\n")
    }

    // MARK: - 工具 Schema（注册给火山方舟 function calling 用）

    /// 工具 Schema 列表（注册给火山方舟 function calling 用）
    static let toolSchemas: [[String: Any]] = [
        updatePropertySchema,
        recordFinanceSchema,
        manageTodoSchema,
        refreshDataSchema,
        manageMeterSchema,
        queryReportSchema,
        exportDataSchema,
        webSearchSchema,
        teachActionSchema
    ]

    static let updatePropertySchema: [String: Any] = [
        "type": "function",
        "function": [
            "name": "update_property",
            "description": "房源域通用工具：新增/编辑/切换状态/移入回收站/还原/生成分享文案。房号规则：房号前带 2- 前缀表示 2 座（如 2-1418），否则为 1 座（如 2334）。",
            "parameters": [
                "type": "object",
                "properties": [
                    "action_type": ["type": "string", "description": "add_house=新增房源；edit_field=编辑字段；change_status=切换待租/已租；delete_house=移入回收站；restore_trash=从回收站还原；share_house=生成分享文案", "enum": ["add_house", "edit_field", "change_status", "delete_house", "restore_trash", "share_house"]],
                    "room_no": ["type": "string", "description": "房号，如 2334 或 2-1418（2- 前缀=2座）"],
                    "room_nos": ["type": "array", "items": ["type": "string"], "description": "批量操作时的房号数组，如 [\"2334\",\"2325\"]"],
                    "tower": ["type": "integer", "description": "座号 1 或 2（缺省按房号规则推断）"],
                    "landlord": ["type": "string", "description": "房东/业主名"],
                    "layout": ["type": "string", "description": "户型，如 单间/一房一厅/中空复式"],
                    "price": ["type": "integer", "description": "月租金（元）"],
                    "password": ["type": "string", "description": "门锁密码"],
                    "remark": ["type": "string", "description": "备注（如 全屋定制/新换锁）"],
                    "field": ["type": "string", "description": "edit_field 要修改的字段：room_no/tower/landlord/layout/price/password/remark", "enum": ["room_no", "tower", "landlord", "layout", "price", "password", "remark"]],
                    "value": ["type": "string", "description": "edit_field 的新值（字符串形式，数字字段会自动转）"],
                    "status": ["type": "string", "description": "change_status 目标状态：available/rented 或 待租/已租", "enum": ["available", "rented", "待租", "已租"]],
                    "mode": ["type": "string", "description": "share_house 分享模式：hidden=隐藏版（不含房号/价格/房东/密码） full=完整版", "enum": ["hidden", "full"]]
                ],
                "required": ["action_type"]
            ]
        ]
    ]

    static let recordFinanceSchema: [String: Any] = [
        "type": "function",
        "function": [
            "name": "record_finance",
            "description": "收租/杂项/成交/水电域通用工具：标记收租、取消收租、改收租设置、记成交、记杂项收支、编辑删除杂项、生成水电结算文本。房号为收租合同房号（如 2-1006）。",
            "parameters": [
                "type": "object",
                "properties": [
                    "action_type": ["type": "string", "description": "record_rent=标记某月已收；unrecord_rent=取消已收恢复未收；edit_rent_setting=改收租设置字段；record_deal=记成交；record_income=记杂项收入；record_expense=记杂项支出；edit_misc=编辑杂项；delete_misc=删除杂项；utility_settle=生成水电结算文本", "enum": ["record_rent", "unrecord_rent", "edit_rent_setting", "record_deal", "record_income", "record_expense", "edit_misc", "delete_misc", "utility_settle"]],
                    "room_no": ["type": "string", "description": "收租合同房号"],
                    "year": ["type": "integer", "description": "年份，如 2026"],
                    "month": ["type": "integer", "description": "月份 1-12"],
                    "amount": ["type": "number", "description": "金额（元）"],
                    "field": ["type": "string", "description": "edit_rent_setting 字段：rent/deposit/prepayment/lease_start/lease_end/lease_duration/rent_due_day/water_meter_base/electric_meter_base", "enum": ["rent", "deposit", "prepayment", "lease_start", "lease_end", "lease_duration", "rent_due_day", "water_meter_base", "electric_meter_base"]],
                    "value": ["type": "string", "description": "edit_rent_setting 新值（字符串，数字/日期自动转换）"],
                    "unit_type": ["type": "string", "description": "户型/房型"],
                    "deposit": ["type": "number", "description": "押金"],
                    "prepayment": ["type": "number", "description": "预付金额"],
                    "lease_start": ["type": "string", "description": "租约开始（yyyy-MM-dd）"],
                    "lease_end": ["type": "string", "description": "租约结束（yyyy-MM-dd）"],
                    "lease_duration": ["type": "string", "description": "租期描述，如 一年"],
                    "agent_fee_landlord": ["type": "number", "description": "房东中介费"],
                    "agent_fee_tenant": ["type": "number", "description": "租客中介费"],
                    "total_fee": ["type": "number", "description": "中介费合计"],
                    "item": ["type": "string", "description": "杂项收支项目名，如 管理费/维修费"],
                    "notes": ["type": "string", "description": "备注"],
                    "date": ["type": "string", "description": "日期（yyyy-MM-dd，默认今天）"],
                    "type": ["type": "string", "description": "edit_misc/delete_misc 指定杂项类型 income/expense", "enum": ["income", "expense"]],
                    "old_item": ["type": "string", "description": "edit_misc 要修改的原项目名"],
                    "new_item": ["type": "string", "description": "edit_misc 新项目名"],
                    "new_amount": ["type": "number", "description": "edit_misc 新金额"],
                    "new_notes": ["type": "string", "description": "edit_misc 新备注"]
                ],
                "required": ["action_type"]
            ]
        ]
    ]

    static let manageTodoSchema: [String: Any] = [
        "type": "function",
        "function": [
            "name": "manage_todo",
            "description": "待办域通用工具：新增/完成/恢复/编辑/删除待办。",
            "parameters": [
                "type": "object",
                "properties": [
                    "action_type": ["type": "string", "description": "add=新增；complete=标记完成；reopen=恢复未办理；edit=编辑；delete=删除", "enum": ["add", "complete", "reopen", "edit", "delete"]],
                    "content": ["type": "string", "description": "待办内容（complete/reopen/edit/delete 时用于定位，支持包含匹配）"],
                    "new_content": ["type": "string", "description": "edit 的新内容"],
                    "reminder_date": ["type": "string", "description": "提醒时间（yyyy-MM-dd HH:mm 或 yyyy-MM-dd，可选）"]
                ],
                "required": ["action_type"]
            ]
        ]
    ]

    static let refreshDataSchema: [String: Any] = [
        "type": "function",
        "function": [
            "name": "refresh_data",
            "description": "刷新/备份域通用工具：刷新全部电表、按用户指定表号/房号抄表、刷新安居客、新建快速/全量备份、列出备份文件、查看同步状态。",
            "parameters": [
                "type": "object",
                "properties": [
                    "action_type": ["type": "string", "description": "refresh_meters=刷新全部电表；query_meters=只抄用户指定表号/房号的电表（未绑定表号会自动加入清单后再抄）；refresh_ajk=重新抓取安居客数据；create_quick_backup=新建快速备份；create_full_backup=新建全量备份；list_backups=列出本地备份；sync_status=查看待同步状态", "enum": ["refresh_meters", "query_meters", "refresh_ajk", "create_quick_backup", "create_full_backup", "list_backups", "sync_status"]],
                    "uids": ["type": "array", "items": ["type": "string"], "description": "query_meters 指定抄表的电表用户号数组，如 [\"012030\",\"010904\"]"],
                    "room_nos": ["type": "array", "items": ["type": "string"], "description": "query_meters 指定抄表的房号数组（按电表清单备注房号匹配），如 [\"1-2319\"]"]
                ],
                "required": ["action_type"]
            ]
        ]
    ]

    /// v1.98：教学/自定义操作工具——用户教 AI 的复合操作记录到本地规则库
    static let teachActionSchema: [String: Any] = [
        "type": "function",
        "function": [
            "name": "teach_action",
            "description": "教学/自定义操作：用户教 AI 一个由多个已有工具步骤组成的新操作时调用，把「操作名 + 步骤列表」记录到本地规则库（不修改任何业务数据）。之后用户说出该操作名，AI 会把这些步骤展开为工具调用直接执行。",
            "parameters": [
                "type": "object",
                "properties": [
                    "action_name": ["type": "string", "description": "给这个操作起的名字（用户以后叫它就会执行），如 全屋抄表并汇总"],
                    "steps": ["type": "array", "items": ["type": "object", "properties": [
                        "tool": ["type": "string", "description": "已有工具名：update_property/record_finance/manage_todo/refresh_data/manage_meter/query_report/export_data/web_search"],
                        "arguments": ["type": "string", "description": "该步骤调用工具的完整参数 JSON 字符串（英文双引号），如 {\"action_type\":\"query_meters\",\"room_nos\":[\"1-2319\"]}"],
                        "description": ["type": "string", "description": "该步骤做什么（一句话说明）"]
                    ], "required": ["tool", "arguments", "description"]]]
                ],
                "required": ["action_name", "steps"]
            ]
        ]
    ]

    static let manageMeterSchema: [String: Any] = [
        "type": "function",
        "function": [
            "name": "manage_meter",
            "description": "电表设置域通用工具：设置低电量预警、设置定时自动刷新。",
            "parameters": [
                "type": "object",
                "properties": [
                    "action_type": ["type": "string", "description": "set_low_alert=设置低电量预警阈值与开关；set_auto_refresh=设置定时自动刷新开关与间隔（分钟）", "enum": ["set_low_alert", "set_auto_refresh"]],
                    "threshold": ["type": "number", "description": "低电量预警阈值（度），如 30"],
                    "enabled": ["type": "boolean", "description": "开关"],
                    "minutes": ["type": "integer", "description": "自动刷新间隔（分钟），如 120"]
                ],
                "required": ["action_type"]
            ]
        ]
    ]

    static let queryReportSchema: [String: Any] = [
        "type": "function",
        "function": [
            "name": "query_report",
            "description": "查询/报表域通用工具：欠租清单、租约到期提醒、收租汇总、水电结算文本、生成收租账单文本。只读，不修改任何数据。",
            "parameters": [
                "type": "object",
                "properties": [
                    "action_type": ["type": "string", "description": "overdue_list=未收租金清单；lease_expiry=租约即将到期清单；rent_summary=指定年月收租汇总；utility_settle=指定房号水电结算文本；generate_rent_bill=生成指定房号指定月份收租账单文本；generate_rent_bill_image=生成指定房号指定月份收租账单图片（渲染与收租页手动生成一致的账单图，直接展示给用户）", "enum": ["overdue_list", "lease_expiry", "rent_summary", "utility_settle", "generate_rent_bill", "generate_rent_bill_image"]],
                    "year": ["type": "integer", "description": "年份（rent_summary/generate_rent_bill/generate_rent_bill_image 用，默认当前年）"],
                    "month": ["type": "integer", "description": "月份 1-12（rent_summary/generate_rent_bill/generate_rent_bill_image 用，默认当前月）"],
                    "days": ["type": "integer", "description": "lease_expiry 提前天数，默认 30"],
                    "room_no": ["type": "string", "description": "utility_settle / generate_rent_bill / generate_rent_bill_image 房号"],
                    "no_extra": ["type": "boolean", "description": "generate_rent_bill 是否无附加费（true=账单注明无附加费；缺省=false）"]
                ],
                "required": ["action_type"]
            ]
        ]
    ]

    /// v1.97：导出/文件域工具——查询结果生成 CSV 保存到 App 沙盒根目录（Documents）
    static let exportDataSchema: [String: Any] = [
        "type": "function",
        "function": [
            "name": "export_data",
            "description": "导出/文件域通用工具：把查询结果（电表余量、安居客房源、房源列表、欠租清单、收租汇总、本月杂项）生成 CSV 文件保存到 App 沙盒根目录（Documents），返回文件完整路径。只读+生成文件，不修改任何业务数据。",
            "parameters": [
                "type": "object",
                "properties": [
                    "action_type": ["type": "string", "description": "export_excel=导出CSV文件（Excel/WPS 可直接打开）", "enum": ["export_excel"]],
                    "data_type": ["type": "string", "description": "meters=电表余量；ajk=安居客房源；houses=房源列表；overdue=欠租清单；rent_summary=收租汇总；misc=本月杂项收支", "enum": ["meters", "ajk", "houses", "overdue", "rent_summary", "misc"]],
                    "year": ["type": "integer", "description": "年份（rent_summary 用，默认当前年）"],
                    "month": ["type": "integer", "description": "月份 1-12（rent_summary 用，默认当前月）"]
                ],
                "required": ["action_type", "data_type"]
            ]
        ]
    ]

    /// v1.97：联网搜索工具——必应搜索公开资料，返回标题/链接/摘要
    static let webSearchSchema: [String: Any] = [
        "type": "function",
        "function": [
            "name": "web_search",
            "description": "联网搜索：用必应搜索指定关键词，返回前几条网页结果（标题+链接+摘要），供查询公开资料使用。只读。",
            "parameters": [
                "type": "object",
                "properties": [
                    "action_type": ["type": "string", "description": "search=执行搜索", "enum": ["search"]],
                    "query": ["type": "string", "description": "搜索关键词，如 佛山租房政策 2026"]
                ],
                "required": ["action_type", "query"]
            ]
        ]
    ]

    // MARK: - 写操作判定 + 摘要（确认框展示用）

    /// 该动作是否需要用户确认（写操作 true；读/执行类 false）
    static func needsConfirm(toolName: String, actionType: String) -> Bool {
        switch toolName {
        case "update_property":
            return actionType != "share_house"
        case "record_finance":
            return actionType != "utility_settle"
        case "manage_todo":
            return true
        case "refresh_data":
            return actionType == "create_quick_backup" || actionType == "create_full_backup"
        case "manage_meter":
            return true
        case "query_report", "export_data", "web_search":
            return false
        default:
            return false
        }
    }

    /// 删除/覆盖类动作：确认框执行按钮标红警示
    static func isDangerous(toolName: String, arguments: String) -> Bool {
        let action = (try? (JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any])?["action_type"] as? String) ?? ""
        switch toolName {
        case "update_property": return action == "delete_house"
        case "record_finance": return action == "delete_misc"
        case "manage_todo": return action == "delete"
        case "refresh_data": return action == "create_full_backup"
        default: return false
        }
    }

    /// 生成人类可读的确认摘要（如「将 2334 状态改为 已租」）
    static func summary(toolName: String, arguments: [String: Any]) -> String {
        let a = arguments
        switch toolName {
        case "update_property":
            switch a["action_type"] as? String ?? "" {
            case "add_house":
                let room = a["room_no"] as? String ?? "?"
                return "新增房源 \(room)（\(a["layout"] as? String ?? "户型未填")，\(a["price"] as? Int ?? 0) 元/月，房东 \(a["landlord"] as? String ?? "未填")）"
            case "edit_field":
                return "修改房源 \(a["room_no"] as? String ?? "?") 的「\(a["field"] as? String ?? "")」为 \(a["value"] as? String ?? "")"
            case "change_status":
                let rooms = (a["room_nos"] as? [String] ?? [a["room_no"] as? String].compactMap { $0 }).joined(separator: "、")
                return "将房源 \(rooms) 状态改为「\(a["status"] as? String ?? "?")」"
            case "delete_house":
                return "将房源 \(a["room_no"] as? String ?? "?") 移入回收站（可还原）"
            case "restore_trash":
                return "从回收站还原房源 \(a["room_no"] as? String ?? "?")"
            case "share_house":
                return "生成房源 \(a["room_no"] as? String ?? "?") 的分享文案（\(a["mode"] as? String == "hidden" ? "隐藏版" : "完整版")）"
            default:
                return "执行房源操作"
            }
        case "record_finance":
            switch a["action_type"] as? String ?? "" {
            case "record_rent":
                return "将 \(a["room_no"] as? String ?? "?") 的 \(a["year"] as? Int ?? 0)年\(a["month"] as? Int ?? 0)月租金标记为已收"
            case "unrecord_rent":
                return "取消 \(a["room_no"] as? String ?? "?") 的 \(a["year"] as? Int ?? 0)年\(a["month"] as? Int ?? 0)月已收标记，恢复未收"
            case "edit_rent_setting":
                return "修改 \(a["room_no"] as? String ?? "?") 的收租设置「\(a["field"] as? String ?? "")」为 \(a["value"] as? String ?? "")"
            case "record_deal":
                return "记一笔成交：\(a["room_no"] as? String ?? "?")，租金 \(a["rent"] as? Double ?? 0) 元，押金 \(a["deposit"] as? Double ?? 0) 元"
            case "record_income":
                return "记杂项收入：\(a["item"] as? String ?? "?") \(a["amount"] as? Double ?? 0) 元"
            case "record_expense":
                return "记杂项支出：\(a["item"] as? String ?? "?") \(a["amount"] as? Double ?? 0) 元"
            case "edit_misc":
                return "编辑杂项\(a["type"] as? String == "expense" ? "支出" : "收入")「\(a["old_item"] as? String ?? "?")」"
            case "delete_misc":
                return "删除杂项\(a["type"] as? String == "expense" ? "支出" : "收入")「\(a["item"] as? String ?? "?")」"
            case "utility_settle":
                return "生成 \(a["room_no"] as? String ?? "?") 的水电结算文本（不改数据）"
            default:
                return "执行收租/杂项操作"
            }
        case "manage_todo":
            switch a["action_type"] as? String ?? "" {
            case "add": return "新增待办：\(a["content"] as? String ?? "?")"
            case "complete": return "标记待办已完成：\(a["content"] as? String ?? "?")"
            case "reopen": return "恢复待办未办理：\(a["content"] as? String ?? "?")"
            case "edit": return "编辑待办：\(a["content"] as? String ?? "?")"
            case "delete": return "删除待办：\(a["content"] as? String ?? "?")"
            default: return "执行待办操作"
            }
        case "refresh_data":
            switch a["action_type"] as? String ?? "" {
            case "refresh_meters": return "刷新全部电表数据"
            case "query_meters": return "抄表：只刷新指定的 \(((a["uids"] as? [String]) ?? (a["room_nos"] as? [String]) ?? []).joined(separator: "、")) 并返回数据（未绑定自动添加，只读不修改数据）"
            case "refresh_ajk": return "重新抓取安居客房源数据"
            case "create_quick_backup": return "新建快速备份（账本+媒体清单，自动上传云端）"
            case "create_full_backup": return "新建全量备份（账本+房源+媒体清单+诊断数据）"
            case "list_backups": return "列出本地备份文件"
            case "sync_status": return "查看待同步状态"
            default: return "执行刷新/备份操作"
            }
        case "teach_action":
            return "教学：记住新操作「\(a["action_name"] as? String ?? "?")」（\(((a["steps"] as? [[String: Any]]) ?? []).count) 步，之后可直接按名执行）"
        case "manage_meter":
            switch a["action_type"] as? String ?? "" {
            case "set_low_alert": return "设置低电量预警：阈值 \(a["threshold"] as? Double ?? 30) 度，\(a["enabled"] as? Bool == true ? "开启" : "关闭")"
            case "set_auto_refresh": return "设置定时自动刷新：\(a["enabled"] as? Bool == true ? "开启，每 \(a["minutes"] as? Int ?? 120) 分钟" : "关闭")"
            default: return "执行电表设置"
            }
        case "query_report":
            switch a["action_type"] as? String ?? "" {
            case "overdue_list": return "查询未收租金清单"
            case "lease_expiry": return "查询租约即将到期清单"
            case "rent_summary": return "查询 \(a["year"] as? Int ?? 0)年\(a["month"] as? Int ?? 0)月收租汇总"
            case "utility_settle": return "生成 \(a["room_no"] as? String ?? "?") 水电结算文本"
            case "generate_rent_bill": return "生成 \(a["room_no"] as? String ?? "?") 的 \(a["year"] as? Int ?? 0)年\(a["month"] as? Int ?? 0)月收租账单文本"
            case "generate_rent_bill_image": return "生成 \(a["room_no"] as? String ?? "?") 的 \(a["year"] as? Int ?? 0)年\(a["month"] as? Int ?? 0)月收租账单图片"
            default: return "执行查询"
            }
        case "export_data":
            return "导出「\(a["data_type"] as? String ?? "?")」数据为 CSV 文件（保存到 App 沙盒根目录）"
        case "web_search":
            return "联网搜索：\(a["query"] as? String ?? "?")"
        default:
            return "执行 \(toolName)"
        }
    }

    // MARK: - 分发入口

    /// 执行一个工具调用（参数已 JSON 解析），返回结果文本供回填 AI
    func execute(tool: AIRequestService.AIToolCall) async -> String {
        let arguments: [String: Any]
        do {
            arguments = try (JSONSerialization.jsonObject(with: Data(tool.arguments.utf8)) as? [String: Any]) ?? [:]
        } catch {
            return "工具参数解析失败：\(tool.arguments)"
        }
        switch tool.name {
        case "update_property": return await updateProperty(arguments)
        case "record_finance": return await recordFinance(arguments)
        case "manage_todo": return await manageTodo(arguments)
        case "refresh_data": return await refreshData(arguments)
        case "manage_meter": return manageMeter(arguments)
        case "query_report": return queryReport(arguments)
        case "export_data": return exportData(arguments)
        case "web_search": return await webSearch(arguments)
        case "teach_action": return teachAction(arguments)
        default: return "未知工具：\(tool.name)"
        }
    }

    // MARK: - 参数辅助

    private func s(_ a: [String: Any], _ key: String) -> String {
        if let v = a[key] as? String { return v }
        if let v = a[key] as? NSNumber { return v.stringValue }
        return ""
    }

    private func i(_ a: [String: Any], _ key: String) -> Int? {
        if let v = a[key] as? Int { return v }
        if let v = a[key] as? NSNumber { return v.intValue }
        if let v = a[key] as? String, let n = Int(v) { return n }
        return nil
    }

    private func d(_ a: [String: Any], _ key: String) -> Double? {
        if let v = a[key] as? Double { return v }
        if let v = a[key] as? Int { return Double(v) }
        if let v = a[key] as? NSNumber { return v.doubleValue }
        if let v = a[key] as? String, let n = Double(v) { return n }
        return nil
    }

    private func b(_ a: [String: Any], _ key: String) -> Bool {
        if let v = a[key] as? Bool { return v }
        if let v = a[key] as? NSNumber { return v.boolValue }
        if let v = a[key] as? String { return v == "true" || v == "1" || v == "yes" || v == "是" || v == "开" }
        return false
    }

    /// 房号 → 座号（房号前带 2- 前缀=2座，否则 1座）
    private func towerFromRoomNo(_ roomNo: String) -> Int {
        let t = roomNo.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("2-") { return 2 }
        if t.hasPrefix("1-") { return 1 }
        return 1
    }

    /// 解析日期（yyyy-MM-dd / yyyy-MM-dd HH:mm / yyyy/MM/dd）
    private func parseDate(_ text: String) -> Date? {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "zh_CN")
        let patterns = ["yyyy-MM-dd HH:mm", "yyyy-MM-dd", "yyyy/MM/dd", "yyyy年M月d日"]
        for p in patterns {
            fmt.dateFormat = p
            if let date = fmt.date(from: text) { return date }
        }
        return nil
    }

    /// 日期显示文本（yyyy-MM-dd）
    private func dateText(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: date)
    }

    // MARK: - 日志（写操作统一留痕，AI 标识；房源域走云端日志——共享数据，与手动房源操作一致）

    private func logAI(category: String, action: String, result: String, detail: String) {
        // v1.97：房源相关操作记录到云端日志（房源是共享数据，与房源板块手动操作 cloud: true 一致）
        BackupLogStore.log(category: category, action: action + "（AI）", result: result,
                           detail: detail, cloud: category == "房源")
    }

    // MARK: - 房源域（update_property）

    private func updateProperty(_ a: [String: Any]) async -> String {
        guard let houseCtx = houseModelContext else { return "房源容器不可用，无法操作房源" }
        let action = s(a, "action_type")
        switch action {
        case "add_house":
            let room = s(a, "room_no")
            guard !room.isEmpty else { return "缺少房号 room_no" }
            let tower = i(a, "tower") ?? towerFromRoomNo(room)
            let price = i(a, "price") ?? 0
            let houses = (try? houseCtx.fetch(FetchDescriptor<House>())) ?? []
            let dup = houses.first { $0.tower == tower && $0.roomNo == room && !$0.isTrashed }
            if dup != nil { return "房源 \(tower)座\(room) 已收录（\(dup?.landlord ?? "")，\(dup?.price ?? 0) 元/月），请先确认是否要改这条，不要重复新增" }
            let house = House(roomNo: room, tower: tower,
                              landlord: s(a, "landlord"), layout: s(a, "layout"),
                              price: price, password: s(a, "password"), remark: s(a, "remark"))
            houseCtx.insert(house)
            try? houseCtx.save()
            logAI(category: "房源", action: "新增房源", result: "成功", detail: "\(tower)座\(room) \(price) 元/月")
            return "已新增房源：\(tower)座\(room)，\(s(a, "layout").isEmpty ? "未填户型" : s(a, "layout"))，\(price) 元/月，房东 \(s(a, "landlord").isEmpty ? "未填" : s(a, "landlord"))，时间 \(dateText(Date()))"

        case "edit_field":
            let room = s(a, "room_no")
            guard let house = findHouse(room, in: houseCtx) else { return "未找到房源 \(room)" }
            let field = s(a, "field")
            let value = s(a, "value")
            let old: String
            switch field {
            case "room_no": old = house.roomNo; house.roomNo = value
            case "tower": old = "\(house.tower)座"; house.tower = i(a, "value") ?? towerFromRoomNo(value)
            case "landlord": old = house.landlord; house.landlord = value
            case "layout": old = house.layout; house.layout = value
            case "price": old = "\(house.price) 元"; house.price = i(a, "value") ?? 0
            case "password": old = house.password; house.password = value
            case "remark": old = house.remark; house.remark = value
            default: return "不支持的字段：\(field)"
            }
            house.updatedAt = Date()
            try? houseCtx.save()
            logAI(category: "房源", action: "编辑房源", result: "成功", detail: "\(house.tower)座\(house.roomNo) 修改 \(field)：\(old) → \(value)")
            return "已修改房源 \(house.tower)座\(house.roomNo) 的「\(field)」：\(old) → \(value)，时间 \(dateText(Date()))"

        case "change_status":
            var rooms = a["room_nos"] as? [String] ?? []
            if rooms.isEmpty, let one = a["room_no"] as? String { rooms = [one] }
            guard !rooms.isEmpty else { return "缺少房号 room_no / room_nos" }
            let raw = s(a, "status")
            let target: HouseStatus = (raw == "rented" || raw == "已租") ? .rented : .available
            var done: [String] = []
            var miss: [String] = []
            for room in rooms {
                if let house = findHouse(room, in: houseCtx) {
                    let old = house.status == .rented ? "已租" : "待租"
                    house.status = target
                    house.updatedAt = Date()
                    done.append("\(house.tower)座\(house.roomNo)（\(old) → \(target == .rented ? "已租" : "待租")）")
                } else {
                    miss.append(room)
                }
            }
            try? houseCtx.save()
            let detail = done.joined(separator: "；") + (miss.isEmpty ? "" : "；未找到：\(miss.joined(separator: "、"))")
            logAI(category: "房源", action: "切换状态", result: "成功", detail: detail)
            return "状态切换完成：\(detail)，时间 \(dateText(Date()))"

        case "delete_house":
            let room = s(a, "room_no")
            guard let house = findHouse(room, in: houseCtx) else { return "未找到房源 \(room)" }
            house.isDeleted = true
            house.deletedAt = Date()
            house.updatedAt = Date()
            try? houseCtx.save()
            logAI(category: "房源", action: "移入回收站", result: "成功", detail: "\(house.tower)座\(house.roomNo)")
            return "已将房源 \(house.tower)座\(house.roomNo) 移入回收站（可在回收站还原），时间 \(dateText(Date()))"

        case "restore_trash":
            let room = s(a, "room_no")
            let houses = (try? houseCtx.fetch(FetchDescriptor<House>())) ?? []
            guard let house = houses.first(where: { ($0.roomNo == room || displayMatch($0, room)) && $0.isTrashed }) else { return "回收站未找到房源 \(room)" }
            house.isDeleted = false
            house.deletedAt = nil
            house.updatedAt = Date()
            try? houseCtx.save()
            logAI(category: "房源", action: "还原房源", result: "成功", detail: "\(house.tower)座\(house.roomNo)")
            return "已从回收站还原房源 \(house.tower)座\(house.roomNo)，时间 \(dateText(Date()))"

        case "share_house":
            let room = s(a, "room_no")
            guard let house = findHouse(room, in: houseCtx) else { return "未找到房源 \(room)" }
            let mode = s(a, "mode")
            let text = mode == "hidden" ? house.briefShareText : house.fullShareText
            return "已生成分享文案（\(mode == "hidden" ? "隐藏版" : "完整版")）：\n\(text)\n（可在聊天中长按复制后转发微信）"

        default:
            return "未知房源动作：\(action)"
        }
    }

    private func findHouse(_ room: String, in ctx: ModelContext) -> House? {
        let houses = (try? ctx.fetch(FetchDescriptor<House>())) ?? []
        return houses.first { !$0.isTrashed && ($0.roomNo == room || displayMatch($0, room)) }
    }

    /// 房号匹配：支持 2334 与 1-2334 等价（塔座前缀容错）
    private func displayMatch(_ house: House, _ room: String) -> Bool {
        let noPrefix = room.replacingOccurrences(of: "\(house.tower)-", with: "")
        return house.roomNo == noPrefix || house.roomNo == room
    }

    // MARK: - 收租/杂项/成交域（record_finance）

    private func recordFinance(_ a: [String: Any]) async -> String {
        let action = s(a, "action_type")
        switch action {
        case "record_rent":
            guard let prop = findProperty(s(a, "room_no")) else { return "未找到收租合同房号 \(s(a, "room_no"))" }
            let year = i(a, "year") ?? Calendar.current.component(.year, from: Date())
            let month = i(a, "month") ?? Calendar.current.component(.month, from: Date())
            let records = prop.monthlyRentRecords
            if let rec = records.first(where: { $0.year == year && $0.month == month }) {
                rec.isPaid = true
                rec.paidDate = Date()
                try? modelContext.save()
                logAI(category: "收租", action: "标记已收", result: "成功", detail: "\(prop.roomNumber) \(year)年\(month)月 ¥\(Int(rec.amount))")
                return "已将 \(prop.roomNumber) 的 \(year)年\(month)月租金 ¥\(Int(rec.amount)) 标记为已收，收款时间 \(dateText(Date()))"
            }
            // 该月无记录：创建一笔
            let amount = d(a, "amount") ?? prop.rent
            let rec = RentMonthRecord(year: year, month: month, amount: amount, isPaid: true)
            rec.paidDate = Date()
            modelContext.insert(rec)
            prop.monthlyRentRecords.append(rec)
            try? modelContext.save()
            logAI(category: "收租", action: "标记已收", result: "成功", detail: "\(prop.roomNumber) \(year)年\(month)月 ¥\(Int(amount))（新建记录）")
            return "已为 \(prop.roomNumber) 创建 \(year)年\(month)月收租记录 ¥\(Int(amount)) 并标记已收，时间 \(dateText(Date()))"

        case "unrecord_rent":
            guard let prop = findProperty(s(a, "room_no")) else { return "未找到收租合同房号 \(s(a, "room_no"))" }
            let year = i(a, "year") ?? Calendar.current.component(.year, from: Date())
            let month = i(a, "month") ?? Calendar.current.component(.month, from: Date())
            guard let rec = prop.monthlyRentRecords.first(where: { $0.year == year && $0.month == month }) else {
                return "\(prop.roomNumber) 没有 \(year)年\(month)月 的收租记录"
            }
            rec.isPaid = false
            rec.paidDate = nil
            try? modelContext.save()
            logAI(category: "收租", action: "取消已收", result: "成功", detail: "\(prop.roomNumber) \(year)年\(month)月")
            return "已取消 \(prop.roomNumber) 的 \(year)年\(month)月已收标记，恢复未收，时间 \(dateText(Date()))"

        case "edit_rent_setting":
            guard let prop = findProperty(s(a, "room_no")) else { return "未找到收租合同房号 \(s(a, "room_no"))" }
            let field = s(a, "field")
            let value = s(a, "value")
            let old: String
            switch field {
            case "rent": old = "¥\(Int(prop.rent))"; prop.rent = d(a, "value") ?? 0
            case "deposit": old = "¥\(Int(prop.deposit))"; prop.deposit = d(a, "value") ?? 0
            case "prepayment": old = "¥\(Int(prop.prepayment))"; prop.prepayment = d(a, "value") ?? 0
            case "lease_start": old = prop.leaseStart; prop.leaseStart = value
            case "lease_end": old = prop.leaseEnd; prop.leaseEnd = value
            case "lease_duration": old = prop.leaseDuration; prop.leaseDuration = value
            case "rent_due_day": old = "每月\(prop.rentDueDay)日"; prop.rentDueDay = i(a, "value") ?? 1
            case "water_meter_base": old = "\(prop.waterMeterBase)"; prop.waterMeterBase = i(a, "value") ?? 0
            case "electric_meter_base": old = "\(prop.electricMeterBase)"; prop.electricMeterBase = i(a, "value") ?? 0
            default: return "不支持的收租设置字段：\(field)"
            }
            try? modelContext.save()
            logAI(category: "收租", action: "修改收租设置", result: "成功", detail: "\(prop.roomNumber) \(field)：\(old) → \(value)")
            return "已修改 \(prop.roomNumber) 的「\(field)」：\(old) → \(value)，时间 \(dateText(Date()))"

        case "record_deal":
            let deal = DealRecord(
                date: parseDate(s(a, "date")) ?? Date(),
                roomNumber: s(a, "room_no"), landlord: s(a, "landlord"),
                unitType: s(a, "unit_type"),
                leaseStart: parseDate(s(a, "lease_start")) ?? Date(),
                leaseEnd: parseDate(s(a, "lease_end")) ?? Date(),
                leaseDuration: s(a, "lease_duration"),
                rent: d(a, "rent") ?? 0, deposit: d(a, "deposit") ?? 0,
                prepayment: d(a, "prepayment") ?? 0,
                agentFeeLandlord: d(a, "agent_fee_landlord") ?? 0,
                agentFeeTenant: d(a, "agent_fee_tenant") ?? 0,
                totalFee: d(a, "total_fee") ?? 0,
                notes: s(a, "notes"))
            modelContext.insert(deal)
            try? modelContext.save()
            logAI(category: "成交", action: "新增成交", result: "成功", detail: "\(deal.roomNumber) 租金 ¥\(Int(deal.rent)) 押金 ¥\(Int(deal.deposit))")
            return "已记录成交：\(deal.roomNumber)，租金 ¥\(Int(deal.rent))，押金 ¥\(Int(deal.deposit))，租期 \(s(a, "lease_start")) 至 \(s(a, "lease_end"))，时间 \(dateText(Date()))"

        case "record_income":
            let misc = MiscIncome(date: parseDate(s(a, "date")) ?? Date(), item: s(a, "item"), amount: d(a, "amount") ?? 0, notes: s(a, "notes"))
            modelContext.insert(misc)
            try? modelContext.save()
            logAI(category: "杂项", action: "新增收入", result: "成功", detail: "\(misc.item) ¥\(Int(misc.amount))")
            return "已记录杂项收入：\(misc.item) ¥\(Int(misc.amount))（\(s(a, "notes").isEmpty ? "无备注" : s(a, "notes"))），时间 \(dateText(Date()))"

        case "record_expense":
            let misc = MiscExpense(date: parseDate(s(a, "date")) ?? Date(), item: s(a, "item"), amount: d(a, "amount") ?? 0, notes: s(a, "notes"))
            modelContext.insert(misc)
            try? modelContext.save()
            logAI(category: "杂项", action: "新增支出", result: "成功", detail: "\(misc.item) ¥\(Int(misc.amount))")
            return "已记录杂项支出：\(misc.item) ¥\(Int(misc.amount))（\(s(a, "notes").isEmpty ? "无备注" : s(a, "notes"))），时间 \(dateText(Date()))"

        case "edit_misc":
            let type = s(a, "type")
            let oldItem = s(a, "old_item")
            let date = parseDate(s(a, "date"))
            if type == "expense" {
                guard let misc = findMiscExpense(oldItem, date: date) else { return "未找到杂项支出「\(oldItem)」" }
                if let item = a["new_item"] as? String { misc.item = item }
                if let amount = d(a, "new_amount") { misc.amount = amount }
                if let notes = a["new_notes"] as? String { misc.notes = notes }
                try? modelContext.save()
                logAI(category: "杂项", action: "编辑支出", result: "成功", detail: "\(misc.item) ¥\(Int(misc.amount))")
                return "已编辑杂项支出「\(oldItem)」→「\(misc.item)」¥\(Int(misc.amount))，时间 \(dateText(Date()))"
            } else {
                guard let misc = findMiscIncome(oldItem, date: date) else { return "未找到杂项收入「\(oldItem)」" }
                if let item = a["new_item"] as? String { misc.item = item }
                if let amount = d(a, "new_amount") { misc.amount = amount }
                if let notes = a["new_notes"] as? String { misc.notes = notes }
                try? modelContext.save()
                logAI(category: "杂项", action: "编辑收入", result: "成功", detail: "\(misc.item) ¥\(Int(misc.amount))")
                return "已编辑杂项收入「\(oldItem)」→「\(misc.item)」¥\(Int(misc.amount))，时间 \(dateText(Date()))"
            }

        case "delete_misc":
            let type = s(a, "type")
            let item = s(a, "item")
            let date = parseDate(s(a, "date"))
            if type == "expense" {
                guard let misc = findMiscExpense(item, date: date) else { return "未找到杂项支出「\(item)」" }
                misc.isDeleted = true
                misc.deletedAt = Date()
                try? modelContext.save()
                logAI(category: "杂项", action: "删除支出", result: "成功", detail: "\(misc.item) ¥\(Int(misc.amount))")
                return "已删除杂项支出「\(misc.item)」¥\(Int(misc.amount))，时间 \(dateText(Date()))"
            } else {
                guard let misc = findMiscIncome(item, date: date) else { return "未找到杂项收入「\(item)」" }
                misc.isDeleted = true
                misc.deletedAt = Date()
                try? modelContext.save()
                logAI(category: "杂项", action: "删除收入", result: "成功", detail: "\(misc.item) ¥\(Int(misc.amount))")
                return "已删除杂项收入「\(misc.item)」¥\(Int(misc.amount))，时间 \(dateText(Date()))"
            }

        case "utility_settle":
            guard let prop = findProperty(s(a, "room_no")) else { return "未找到收租合同房号 \(s(a, "room_no"))" }
            let quarters = prop.quarterlyUtilityRecords
            let settled = quarters.filter { $0.isSettled }.reduce(0.0) { $0 + $1.total }
            let latest = quarters.sorted { $0.quarter > $1.quarter }.first
            var lines = ["【\(prop.roomNumber) 水电结算】"]
            lines.append("租约：\(prop.leaseStart) 至 \(prop.leaseEnd)（\(prop.leaseDuration)）")
            lines.append("水电底数：水表 \(prop.waterMeterBase) / 电表 \(prop.electricMeterBase)")
            if let q = latest {
                lines.append("最近季度（第\(q.quarter)季度）：电费 ¥\(Int(q.electricAmount)) + 水费 ¥\(Int(q.waterAmount)) = ¥\(Int(q.total))（\(q.isSettled ? "已结" : "未结")）")
            } else {
                lines.append("暂无季度结算记录（可在收租详情的水电结算计划中维护）")
            }
            lines.append("历史已结算合计：¥\(Int(settled))")
            return lines.joined(separator: "\n")

        default:
            return "未知收租动作：\(action)"
        }
    }

    private func findProperty(_ room: String) -> Property? {
        let props = (try? modelContext.fetch(FetchDescriptor<Property>())) ?? []
        return props.first { !$0.isDeleted && propertyRoomMatch($0.roomNumber, room) }
    }

    /// 房号精确匹配 + 塔座前缀容错（1006 ↔ 1-1006/2-1006），避免 1座/2座误配
    private func propertyRoomMatch(_ stored: String, _ input: String) -> Bool {
        if stored == input { return true }
        let candidates = [stored, "1-" + stored, "2-" + stored]
        return candidates.contains(input) || ["1-" + input, "2-" + input].contains(stored)
    }

    private func findMiscIncome(_ item: String, date: Date?) -> MiscIncome? {
        let list = (try? modelContext.fetch(FetchDescriptor<MiscIncome>())) ?? []
        return list.first { !$0.isDeleted && $0.item == item && (date == nil || Calendar.current.isDate($0.date, inSameDayAs: date!)) }
    }

    private func findMiscExpense(_ item: String, date: Date?) -> MiscExpense? {
        let list = (try? modelContext.fetch(FetchDescriptor<MiscExpense>())) ?? []
        return list.first { !$0.isDeleted && $0.item == item && (date == nil || Calendar.current.isDate($0.date, inSameDayAs: date!)) }
    }

    // MARK: - 待办域（manage_todo）

    private func manageTodo(_ a: [String: Any]) async -> String {
        let action = s(a, "action_type")
        switch action {
        case "add":
            let content = s(a, "content")
            guard !content.isEmpty else { return "缺少待办内容 content" }
            let todo = TodoItem(content: content, createdDate: Date(), reminderDate: parseDate(s(a, "reminder_date")))
            modelContext.insert(todo)
            try? modelContext.save()
            logAI(category: "待办", action: "新增待办", result: "成功", detail: content)
            return "已新增待办：\(content)" + (s(a, "reminder_date").isEmpty ? "" : "（提醒 \(s(a, "reminder_date"))）") + "，时间 \(dateText(Date()))"

        case "complete":
            guard let todo = findTodo(s(a, "content")) else { return "未找到待办「\(s(a, "content"))」" }
            todo.isCompleted = true
            todo.completedDate = Date()
            try? modelContext.save()
            logAI(category: "待办", action: "标记完成", result: "成功", detail: todo.content)
            return "已标记待办完成：\(todo.content)，时间 \(dateText(Date()))"

        case "reopen":
            guard let todo = findTodo(s(a, "content"), completed: true) else { return "未找到已完成的待办「\(s(a, "content"))」" }
            todo.isCompleted = false
            todo.completedDate = nil
            try? modelContext.save()
            logAI(category: "待办", action: "恢复未办理", result: "成功", detail: todo.content)
            return "已恢复待办为未办理：\(todo.content)，时间 \(dateText(Date()))"

        case "edit":
            guard let todo = findTodo(s(a, "content")) else { return "未找到待办「\(s(a, "content"))」" }
            if let nc = a["new_content"] as? String, !nc.isEmpty { todo.content = nc }
            let rd = s(a, "reminder_date")
            if !rd.isEmpty { todo.reminderDate = parseDate(rd) }
            try? modelContext.save()
            logAI(category: "待办", action: "编辑待办", result: "成功", detail: todo.content)
            return "已编辑待办：「\(s(a, "content"))」→「\(todo.content)」，时间 \(dateText(Date()))"

        case "delete":
            guard let todo = findTodo(s(a, "content")) else { return "未找到待办「\(s(a, "content"))」" }
            todo.isDeleted = true
            todo.deletedAt = Date()
            try? modelContext.save()
            logAI(category: "待办", action: "删除待办", result: "成功", detail: todo.content)
            return "已删除待办：\(todo.content)，时间 \(dateText(Date()))"

        default:
            return "未知待办动作：\(action)"
        }
    }

    private func findTodo(_ content: String, completed: Bool? = nil) -> TodoItem? {
        let list = (try? modelContext.fetch(FetchDescriptor<TodoItem>())) ?? []
        return list.first { todo in
            guard !todo.isDeleted else { return false }
            if let completed, todo.isCompleted != completed { return false }
            return todo.content == content || todo.content.contains(content) || content.contains(todo.content)
        }
    }

    // MARK: - 刷新/备份域（refresh_data）

    private func refreshData(_ a: [String: Any]) async -> String {
        let action = s(a, "action_type")
        switch action {
        case "refresh_meters":
            phase?("正在刷新全部电表…")
            let ok = await MeterStore.shared.refreshNow()
            if ok > 0 {
                return "电表刷新完成：共刷新 \(ok) 台电表，最新剩余电量已更新，时间 \(dateText(Date()))"
            }
            return "电表刷新完成（0 台成功）：可能当前无电表清单或接口暂不可用，稍后可在电表板块手动刷新重试"

        case "query_meters":
            // v1.98：AI 抄表精准化——只刷新用户指定表号/房号；未绑定表号自动添加后再抄
            return await queryMeters(a)

        case "refresh_ajk":
            let store = AjkStore.shared
            let maxPages = store.settings.maxPages
            do {
                let result = try await AjkWebViewProvider.shared.fetchAll(maxPages: maxPages)
                if result.houses.isEmpty && !result.needLogin {
                    return "安居客抓取完成，但未抓到房源（后台可能暂无房源或页面结构变化），上次数据保留"
                }
                store.applyFetch(houses: result.houses, overview: result.overview)
                return "安居客抓取完成：共 \(result.houses.count) 套房源，今日点击 \(result.overview.todayClickTotal)，神奇分 \(result.overview.score)，房产币 \(result.overview.coin)，时间 \(dateText(Date()))"
            } catch {
                return "安居客抓取失败：\(error.localizedDescription)"
            }

        case "create_quick_backup":
            guard let main = modelContext as ModelContext? else { return "主数据容器不可用" }
            guard let url = BackupV5Manager.createFastBackup(mainContext: main, houseContext: houseModelContext ?? main) else {
                return "快速备份失败（请到设置→备份数据手动重试）"
            }
            logAI(category: "备份", action: "快速备份", result: "成功", detail: url.lastPathComponent)
            return "快速备份成功：\(url.lastPathComponent)，已自动上传云端（失败会在下次打开自动重试），时间 \(dateText(Date()))"

        case "create_full_backup":
            guard let main = modelContext as ModelContext? else { return "主数据容器不可用" }
            let url = await BackupV5Manager.createFullBackup(mainContext: main, houseContext: houseModelContext ?? main)
            if let url {
                logAI(category: "备份", action: "全量备份", result: "成功", detail: url.lastPathComponent)
                return "全量备份成功：\(url.lastPathComponent)，时间 \(dateText(Date()))"
            }
            return "全量备份失败（请到设置→备份数据手动重试）"

        case "list_backups":
            let all = BackupV5Manager.listLocalBackups()
            guard !all.isEmpty else { return "暂无本地备份文件" }
            let lines = all.prefix(10).map { url -> String in
                let size = BackupV5Manager.fileSize(at: url)
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                return "• \(url.lastPathComponent)（\(String(format: "%.1f", Double(size) / 1024 / 1024)) MB，\(dateText(modified))）"
            }
            return "本地备份文件（最近 \(lines.count) 个）：\n" + lines.joined(separator: "\n") + "\n完整列表请在 设置→备份数据 查看"

        case "sync_status":
            let state = await SyncStore.shared.snapshot()
            var parts: [String] = []
            parts.append("待同步变更 \(state.pending.count) 条")
            if !state.conflicts.isEmpty { parts.append("冲突 \(state.conflicts.count) 条（需人工处理）") }
            return "同步状态：\(parts.joined(separator: "，"))。执行同步请在「工作台 → 数据同步」页面确认后发起（涉及连接校验，AI 不代为执行）"

        default:
            return "未知刷新动作：\(action)"
        }
    }

    // MARK: - v1.98 指定抄表（query_meters）
    // 只刷新用户指定的表号/房号；指定表号不在本地清单时，先拉云端绑定列表自动添加再抄，抄完汇报明细。

    private func queryMeters(_ a: [String: Any]) async -> String {
        let store = MeterStore.shared
        let uids = (a["uids"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let roomNos = (a["room_nos"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !uids.isEmpty || !roomNos.isEmpty else {
            return "缺少要抄的表号或房号：请告诉我要抄哪几个（如 抄一下 012030、010904），或指定房号"
        }
        let provider: MeterQuerying
        switch store.settings.provider {
        case .webView: provider = MeterWebViewProvider.shared
        default: provider = MeterQueryService.shared
        }

        // 1) 本地清单匹配（表号精确匹配 + 房号按备注匹配）
        var targets: [MeterLedger] = []
        var missingCandidates: [String] = []   // 本地清单里没有的（表号或房号）
        for uid in uids {
            if let m = store.meters.first(where: { $0.uid == uid }) {
                if !targets.contains(where: { $0.uid == m.uid }) { targets.append(m) }
            } else {
                missingCandidates.append(uid)
            }
        }
        for room in roomNos {
            if let m = store.meters.first(where: { $0.room == room }) {
                if !targets.contains(where: { $0.uid == m.uid }) { targets.append(m) }
            } else {
                // 房号没匹配到：也当作候选表号尝试（部分电表 room 为空、用户号即显示名）
                missingCandidates.append(room)
            }
        }

        // 2) 有缺失 → 拉云端绑定列表自动添加
        var autoAdded: [String] = []
        if !missingCandidates.isEmpty {
            phase?("正在获取绑定列表，添加 \(missingCandidates.joined(separator: "、"))…")
            do {
                let bindings = try await provider.fetchBindings(store: store)
                store.importBindings(bindings)
                for cand in missingCandidates {
                    if let m = store.meters.first(where: { $0.uid == cand }) {
                        if !targets.contains(where: { $0.uid == m.uid }) {
                            targets.append(m)
                            autoAdded.append(cand)
                        }
                    }
                }
            } catch {
                // 拉绑定失败不阻断：已匹配到的照常抄
            }
        }

        // 3) 仍未找到的
        let stillMissing = missingCandidates.filter { cand in
            !store.meters.contains(where: { $0.uid == cand })
        }

        // 4) 逐台抄表（按指定顺序，步骤上报）
        guard !targets.isEmpty else {
            var out = "没找到可查询的电表"
            if !stillMissing.isEmpty { out += "：\(stillMissing.joined(separator: "、")) 不在你的绑定列表里" }
            out += "。请核对表号/房号，或到「电表管理 → 一键导入」确认绑定后再让我抄"
            return out
        }
        var lines: [String] = []
        var failed: [String] = []
        var okCount = 0
        for (i, m) in targets.enumerated() {
            let display = m.room.isEmpty ? m.uid : "\(m.room)（\(m.uid)）"
            phase?("正在抄表 \(display)（\(i + 1)/\(targets.count)）")
            do {
                let result = try await provider.query(store: store, uid: m.uid)
                store.applyQueryResult(uid: m.uid, result: result)
                lines.append("\(display)：剩余 \(result.shengyu) 度，累计 \(result.leiji) 度，\(result.zhuangtai)，抄表时间 \(result.shijian.isEmpty ? "暂无" : result.shijian)")
                okCount += 1
            } catch {
                failed.append(display)
            }
        }
        var out = "已按你指定的 \(targets.count) 台电表抄表：\n" + lines.joined(separator: "\n")
        if !autoAdded.isEmpty { out += "\n\n注：\(autoAdded.joined(separator: "、")) 原来不在清单里，已自动加入后刷新" }
        if !failed.isEmpty { out += "\n\n以下查询失败（可稍后重试或到电表板块手动刷新）：\(failed.joined(separator: "、"))" }
        if !stillMissing.isEmpty { out += "\n\n以下不在绑定列表，未查询：\(stillMissing.joined(separator: "、"))" }
        if okCount == 0 && failed.isEmpty { out += "\n\n（本次全部表号已在绑定列表，无需新增）" }
        out += "\n抄表时间 \(dateText(Date()))"
        return out
    }

    // MARK: - v1.98 教学/自定义操作（teach_action）

    /// 记录用户教的新操作：操作名 + 步骤（步骤工具必须在白名单内），存本地规则库
    private func teachAction(_ a: [String: Any]) -> String {
        let name = s(a, "action_name").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return "缺少操作名：请给这个操作起个名字，如 全屋抄表并汇总" }
        let rawSteps = a["steps"] as? [[String: Any]] ?? []
        guard !rawSteps.isEmpty else { return "缺少步骤：请一步步告诉我先做什么、再做什么（每步=一个已有工具调用）" }
        var steps: [TaughtStep] = []
        var badTools: [String] = []
        for raw in rawSteps {
            let tool = s(raw, "tool")
            guard Self.knownToolNames.contains(tool) else {
                badTools.append(tool.isEmpty ? "空" : tool)
                continue
            }
            let args = s(raw, "arguments")
            let desc = s(raw, "description")
            // 校验 arguments 是合法 JSON（给 AI 的步骤必须是可执行的完整参数）
            if !args.isEmpty {
                guard let data = args.data(using: .utf8),
                      let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], !obj.isEmpty else {
                    return "步骤「\(desc.isEmpty ? tool : desc)」的参数不是合法 JSON 字符串，请用英文双引号重写参数再教我"
                }
            }
            steps.append(TaughtStep(tool: tool, arguments: args, description: desc))
        }
        if !badTools.isEmpty {
            return "以下步骤使用了未知工具，无法教学：\(badTools.joined(separator: "、"))。可用工具：\(Self.knownToolNames.sorted().joined(separator: "/"))"
        }
        guard !steps.isEmpty else { return "教学失败：没有可用的步骤" }
        // 覆盖同名操作（同名=更新教学）
        var actions = Self.loadTaughtActions()
        actions.removeAll { $0.name == name }
        actions.append(TaughtAction(name: name, steps: steps))
        Self.saveTaughtActions(actions)
        let stepDesc = steps.enumerated().map { "第\($0.offset + 1)步 \($0.element.tool)（\($0.element.description.isEmpty ? "见参数" : $0.element.description)）" }
        logAI(category: "AI教学", action: "记录操作 \(name)", result: "成功", detail: "\(steps.count) 步")
        return "已学会新操作「\(name)」（\(steps.count) 步）：\n" + stepDesc.joined(separator: "\n") + "\n下次你说「\(name)」，我会按这些步骤直接执行。"
    }

    // MARK: - 电表设置域（manage_meter）

    private func manageMeter(_ a: [String: Any]) -> String {
        let action = s(a, "action_type")
        switch action {
        case "set_low_alert":
            let store = MeterStore.shared
            if let th = d(a, "threshold") { store.settings.lowThreshold = th }
            if let en = a["enabled"] as? Bool { store.settings.lowAlertEnabled = en }
            store.saveSettings()
            logAI(category: "电表", action: "设置低电量预警", result: "成功", detail: "阈值 \(store.settings.lowThreshold) 度，\(store.settings.lowAlertEnabled ? "开启" : "关闭")")
            return "已设置低电量预警：低于 \(Int(store.settings.lowThreshold)) 度提醒（\(store.settings.lowAlertEnabled ? "已开启" : "已关闭")），时间 \(dateText(Date()))"

        case "set_auto_refresh":
            let store = MeterStore.shared
            if let minutes = i(a, "minutes") { store.settings.autoRefreshMinutes = minutes }
            if let en = a["enabled"] as? Bool { store.settings.autoRefreshEnabled = en }
            store.saveSettings()
            logAI(category: "电表", action: "设置定时刷新", result: "成功", detail: "\(store.settings.autoRefreshEnabled ? "开启 每 \(store.settings.autoRefreshMinutes) 分钟" : "关闭")")
            return "已设置电表定时自动刷新：\(store.settings.autoRefreshEnabled ? "每 \(store.settings.autoRefreshMinutes) 分钟一次" : "关闭")，时间 \(dateText(Date()))"

        default:
            return "未知电表动作：\(action)"
        }
    }

    // MARK: - 查询/报表域（query_report）

    private func queryReport(_ a: [String: Any]) -> String {
        let action = s(a, "action_type")
        switch action {
        case "overdue_list":
            let props = (try? modelContext.fetch(FetchDescriptor<Property>())) ?? []
            let now = Date()
            let cal = Calendar.current
            let cy = cal.component(.year, from: now)
            let cm = cal.component(.month, from: now)
            var rows: [String] = []
            for prop in props where !prop.isDeleted {
                // 最近 6 个月未收月份
                var missing: [String] = []
                for back in 0..<6 {
                    var comps = DateComponents()
                    comps.year = cy; comps.month = cm
                    if let m = cal.date(byAdding: .month, value: -back, to: now) {
                        let y = cal.component(.year, from: m)
                        let mo = cal.component(.month, from: m)
                        if !prop.monthlyRentRecords.contains(where: { $0.year == y && $0.month == mo && $0.isPaid }) {
                            missing.append("\(y)年\(mo)月")
                        }
                    }
                }
                if !missing.isEmpty {
                    rows.append("• \(prop.roomNumber)：欠 \(missing.joined(separator: "、"))，租金 ¥\(Int(prop.rent))，房东 \(prop.landlord)")
                }
            }
            if rows.isEmpty { return "当前没有欠租记录（近 6 个月均已收）" }
            return "欠租清单（近 6 个月未收）：\n" + rows.joined(separator: "\n")

        case "lease_expiry":
            let days = i(a, "days") ?? 30
            let props = (try? modelContext.fetch(FetchDescriptor<Property>())) ?? []
            let now = Date()
            var rows: [String] = []
            for prop in props where !prop.isDeleted {
                if let end = parseDate(prop.leaseEnd) {
                    let remain = calDays(from: now, to: end)
                    if remain >= 0 && remain <= days {
                        rows.append("• \(prop.roomNumber)：租约 \(prop.leaseStart) 至 \(prop.leaseEnd)（\(prop.leaseDuration)），剩 \(remain) 天，房东 \(prop.landlord)")
                    }
                }
            }
            if rows.isEmpty { return "未来 \(days) 天内没有租约到期" }
            return "租约即将到期（\(days) 天内）：\n" + rows.joined(separator: "\n")

        case "rent_summary":
            let year = i(a, "year") ?? Calendar.current.component(.year, from: Date())
            let month = i(a, "month") ?? Calendar.current.component(.month, from: Date())
            let props = (try? modelContext.fetch(FetchDescriptor<Property>())) ?? []
            var total = 0.0, paid = 0.0
            var paidRooms: [String] = [], unpaidRooms: [String] = []
            for prop in props where !prop.isDeleted {
                let rec = prop.monthlyRentRecords.first(where: { $0.year == year && $0.month == month })
                let amount = rec?.amount ?? prop.rent
                total += amount
                if rec?.isPaid == true {
                    paid += amount
                    paidRooms.append("\(prop.roomNumber)(¥\(Int(amount)))")
                } else {
                    unpaidRooms.append("\(prop.roomNumber)(¥\(Int(amount)))")
                }
            }
            let unpaid = total - paid
            return "\(year)年\(month)月收租汇总：\n应收回合计 ¥\(Int(total))\n已收 ¥\(Int(paid))（\(paidRooms.joined(separator: "、") )）\n未收 ¥\(Int(unpaid))（\(unpaidRooms.joined(separator: "、"))）"

        case "utility_settle":
            guard let prop = findProperty(s(a, "room_no")) else { return "未找到收租合同房号 \(s(a, "room_no"))" }
            let quarters = prop.quarterlyUtilityRecords
            var lines = ["【\(prop.roomNumber) 水电结算】"]
            lines.append("租约：\(prop.leaseStart) 至 \(prop.leaseEnd)（\(prop.leaseDuration)）")
            lines.append("水电底数：水表 \(prop.waterMeterBase) / 电表 \(prop.electricMeterBase)")
            if quarters.isEmpty {
                lines.append("暂无季度结算记录（可在收租详情的水电结算计划中维护）")
            } else {
                for q in quarters.sorted(by: { $0.quarter < $1.quarter }) {
                    lines.append("第\(q.quarter)季度：电费 ¥\(Int(q.electricAmount)) + 水费 ¥\(Int(q.waterAmount)) = ¥\(Int(q.total))（\(q.isSettled ? "已结" : "未结")）")
                }
            }
            return lines.joined(separator: "\n")

        case "generate_rent_bill":
            // v1.97：账单生成固有动作——AI 不再自行编造长账单文本，直接取合同数据生成结构化账单
            guard let prop = findProperty(s(a, "room_no")) else { return "未找到收租合同房号 \(s(a, "room_no"))" }
            let year = i(a, "year") ?? Calendar.current.component(.year, from: Date())
            let month = i(a, "month") ?? Calendar.current.component(.month, from: Date())
            let rec = prop.monthlyRentRecords.first(where: { $0.year == year && $0.month == month })
            let amount = rec?.amount ?? prop.rent
            let noExtra = b(a, "no_extra")
            var lines = ["【\(prop.roomNumber) 收租账单 \(year)年\(month)月】"]
            lines.append("房号：\(prop.roomNumber)（户型 \(prop.unitType.isEmpty ? "未填" : prop.unitType)）")
            lines.append("租金：¥\(Int(amount))")
            lines.append("附加费：\(noExtra ? "无" : "（未指定，如有水电等附加请单独说明）")")
            lines.append("租约：\(prop.leaseStart) 至 \(prop.leaseEnd)（\(prop.leaseDuration)）")
            lines.append("水电底数：水表 \(prop.waterMeterBase) / 电表 \(prop.electricMeterBase)")
            lines.append("收款方式：在 App「收租」页按此金额收款即可")
            return lines.joined(separator: "\n")

        case "generate_rent_bill_image":
            // v1.98：账单图片直出——复用收租页手动生成的 RentBillShareView + ImageRenderer 渲染，
            // 与手动点「生成账单」版式完全一致（360 宽 ×3 倍图），PNG 存沙盒 Documents 并返回图片路径
            guard let prop = findProperty(s(a, "room_no")) else { return "未找到收租合同房号 \(s(a, "room_no"))" }
            let year = i(a, "year") ?? Calendar.current.component(.year, from: Date())
            let month = i(a, "month") ?? Calendar.current.component(.month, from: Date())
            guard let rent = prop.monthlyRentRecords.first(where: { $0.year == year && $0.month == month }) else {
                // 该月无记录也按合同租金生成（与收租页行为一致：月账单行未建时默认合同金额）
                let rec = RentMonthRecord(year: year, month: month, amount: prop.rent + prop.prepayment, isPaid: false)
                return renderBillImage(prop: prop, rent: rec, year: year, month: month)
            }
            return renderBillImage(prop: prop, rent: rent, year: year, month: month)

        default:
            return "未知查询动作：\(action)"
        }
    }

    /// v1.98：渲染账单图为 PNG 存沙盒（v1.98 起统一存「AI产物」文件夹），返回含路径的文本（AIManager 解析【图片】标记注入气泡）
    private func renderBillImage(prop: Property, rent: RentMonthRecord, year: Int, month: Int) -> String {
        phase?("正在生成 \(prop.roomNumber) \(year)年\(month)月账单图片…")
        let utility = prop.utilitySettlementRecords.first { rec in
            guard let d = rec.dueDate else { return false }
            return Calendar.current.component(.year, from: d) == year && Calendar.current.component(.month, from: d) == month
        }
        let view = RentBillShareView(property: prop, rent: rent, utility: utility, extras: [])
        let renderer = ImageRenderer(content: view.frame(width: 360).background(Color.white))
        renderer.scale = 3
        guard let image = renderer.uiImage,
              let data = image.pngData() else {
            return "账单图片生成失败：无法渲染图片，请稍后重试"
        }
        let fm = FileManager.default
        let dir = Self.aiArtifactDir()
        let fileName = "账单_\(prop.roomNumber)_\(year)\(String(format: "%02d", month)).png"
        let fileURL = dir.appendingPathComponent(fileName)
        do {
            try data.write(to: fileURL)
        } catch {
            return "账单图片保存失败：\(error.localizedDescription)"
        }
        var lines = ["【\(prop.roomNumber) 收租账单 \(year)年\(month)月】已生成账单图片（与收租页手动生成版式一致）："]
        lines.append("租金：¥\(Int(rent.amount))")
        if prop.prepayment != 0 { lines.append("水电预存：¥\(Int(prop.prepayment))") }
        if let u = utility, u.balance != 0 { lines.append("预存结余：¥\(Int(u.balance))") }
        lines.append("收款方式：在 App「收租」页按此金额收款即可")
        lines.append("【图片】\(fileURL.path)")
        return lines.joined(separator: "\n")
    }

    /// 两个日期之间的天数差（now 到 target，正数=未来）
    private func calDays(from start: Date, to end: Date) -> Int {
        let cal = Calendar.current
        let s = cal.startOfDay(for: start)
        let e = cal.startOfDay(for: end)
        return cal.dateComponents([.day], from: s, to: e).day ?? 0
    }

    // MARK: - 导出/文件域（export_data，v1.97）

    private func exportData(_ a: [String: Any]) -> String {
        let dataType = s(a, "data_type")
        guard dataType != "" else { return "缺少 data_type（meters/ajk/houses/overdue/rent_summary/misc）" }
        guard let hc = houseModelContext else {
            return "数据容器不可用，请重新打开 AI 助手"
        }
        let mc = modelContext
        var header: [String] = []
        var rows: [[String]] = []
        let stamp = Self.stampFormatter.string(from: Date())
        var prefix = ""

        switch dataType {
        case "meters":
            prefix = "电表余量"
            header = ["用户号", "房号", "剩余电量(度)", "累计用量(度)", "状态", "抄表时间"]
            let meters = MeterStore.shared.meters.sorted { $0.shengyu < $1.shengyu }
            for m in meters {
                rows.append([m.uid, m.room, Self.num(m.shengyu), Self.num(m.leiji), m.zhuangtai, m.shijian])
            }
        case "ajk":
            prefix = "安居客房源"
            header = ["编号", "标题", "小区", "户型", "楼层", "租金", "今日点击", "累计点击", "推广状态", "平台", "房态天数", "核验状态"]
            let houses = AjkStore.shared.houses.sorted { $0.todayClick > $1.todayClick }
            for h in houses {
                rows.append([h.number, h.title, h.community, h.layout, h.floor, h.price,
                             "\(h.todayClick)", "\(h.totalClick)",
                             h.promotions.joined(separator: "/"), h.platforms.joined(separator: "/"),
                             "\(h.houseStateDays)", h.verified])
            }
        case "houses":
            prefix = "房源列表"
            header = ["座", "房号", "户型", "租金(元)", "房东", "状态", "备注"]
            let houses = (try? hc.fetch(FetchDescriptor<House>())) ?? []
            let active = houses.filter { !($0.isDeleted ?? false) }.sorted { $0.roomNo < $1.roomNo }
            for h in active {
                rows.append(["\(h.tower)", h.roomNo, h.layout, "\(h.price)", h.landlord,
                             h.status == .rented ? "已租" : "待租", h.remark])
            }
        case "overdue":
            prefix = "欠租清单"
            header = ["房号", "欠租月份", "租金(元)", "房东"]
            let props = (try? mc.fetch(FetchDescriptor<Property>())) ?? []
            let now = Date()
            let cal = Calendar.current
            let cy = cal.component(.year, from: now)
            let cm = cal.component(.month, from: now)
            for prop in props where !prop.isDeleted {
                var missing: [String] = []
                for back in 0..<6 {
                    var comps = DateComponents()
                    comps.year = cy; comps.month = cm
                    if let m = cal.date(byAdding: .month, value: -back, to: now) {
                        let y = cal.component(.year, from: m)
                        let mo = cal.component(.month, from: m)
                        if !prop.monthlyRentRecords.contains(where: { $0.year == y && $0.month == mo && $0.isPaid }) {
                            missing.append("\(y)-\(mo)")
                        }
                    }
                }
                if !missing.isEmpty {
                    rows.append([prop.roomNumber, missing.joined(separator: "、"), "\(Int(prop.rent))", prop.landlord])
                }
            }
        case "rent_summary":
            prefix = "收租汇总"
            let year = i(a, "year") ?? Calendar.current.component(.year, from: Date())
            let month = i(a, "month") ?? Calendar.current.component(.month, from: Date())
            header = ["房号", "\(year)-\(month)租金(元)", "是否已收", "房东", "收款时间"]
            let props = (try? mc.fetch(FetchDescriptor<Property>())) ?? []
            for prop in props where !prop.isDeleted {
                let rec = prop.monthlyRentRecords.first(where: { $0.year == year && $0.month == month })
                let amount = rec?.amount ?? prop.rent
                rows.append([prop.roomNumber, "\(Int(amount))", rec?.isPaid == true ? "已收" : "未收",
                             prop.landlord, rec?.paidDate.map { Self.dayStr($0) } ?? ""])
            }
        case "misc":
            prefix = "本月杂项"
            let now = Date()
            let cal = Calendar.current
            header = ["类型", "日期", "金额(元)", "备注"]
            let incs = (try? mc.fetch(FetchDescriptor<MiscIncome>(predicate: #Predicate { !$0.isDeleted }))) ?? []
            let exps = (try? mc.fetch(FetchDescriptor<MiscExpense>(predicate: #Predicate { !$0.isDeleted }))) ?? []
            for inc in incs where cal.isDate(inc.date, equalTo: now, toGranularity: .month) {
                rows.append(["收入", Self.dayStr(inc.date), "\(Int(inc.amount))", inc.item + (inc.notes.isEmpty ? "" : "（\(inc.notes)）")])
            }
            for exp in exps where cal.isDate(exp.date, equalTo: now, toGranularity: .month) {
                rows.append(["支出", Self.dayStr(exp.date), "\(Int(exp.amount))", exp.item + (exp.notes.isEmpty ? "" : "（\(exp.notes)）")])
            }
        default:
            return "未知导出类型：\(dataType)"
        }

        let fileName = "\(prefix)_\(stamp).csv"
        let dir = Self.aiArtifactDir()
        let url = dir.appendingPathComponent(fileName)
        var csv = header.map { Self.esc($0) }.joined(separator: ",")
        for r in rows {
            csv += "\n" + r.map { Self.esc($0) }.joined(separator: ",")
        }
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            return "已导出 \(rows.count) 行：\(fileName)（已保存到 App 沙盒根目录「AI产物」文件夹，可通过「文件」App 查看或转发；也可在 App 对应板块内分享）"
        } catch {
            return "导出失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 联网搜索域（web_search，v1.97 / v1.98 稳定通道）

    /// v1.98 返修：主通道改为百度（国内主搜索引擎，HTML 轻量解析，真实可用）；
    /// 备用通道 Bing RSS（format=rss 轻量 XML）→ DuckDuckGo HTML，百度搜不到/被拦时才降级。
    /// 三条通道都失败才报错，AI 拿到的始终是结构化 title/link/snippet。
    private func webSearch(_ a: [String: Any]) async -> String {
        let query = s(a, "query")
        guard !query.isEmpty else { return "缺少搜索关键词 query" }
        let q = (query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)

        // 主通道：百度
        if let items = await fetchBaidu(q) {
            return Self.formatSearchResults(items, query: query, source: "百度")
        }
        // 备用通道：必应 RSS
        if let items = await fetchBingRSS(q) {
            return Self.formatSearchResults(items, query: query, source: "必应")
        }
        // 备用通道：DuckDuckGo HTML
        if let items = await fetchDuckDuckGo(q) {
            return Self.formatSearchResults(items, query: query, source: "DuckDuckGo")
        }
        return "联网搜索失败：百度、必应、DuckDuckGo 通道均不可用，请稍后重试，或换更简短的关键词。"
    }

    private struct SearchItem { let title: String; let link: String; let snippet: String }

    /// 拉取百度搜索结果并解析（新版 h3.t>a 标题块 + content-right/c-abstract 摘要）；失败返回 nil
    private func fetchBaidu(_ q: String) async -> [SearchItem]? {
        guard let url = URL(string: "https://www.baidu.com/s?wd=\(q)&ie=utf-8&rn=10") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
                     forHTTPHeaderField: "User-Agent")
        req.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        req.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else { return nil }
        var items: [SearchItem] = []
        // 按 <h3 切结果块（百度新旧版均为 h3 承载标题链接）
        for chunk in html.components(separatedBy: "<h3").dropFirst().prefix(10) {
            guard let aRange = chunk.range(of: #"<a[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#, options: .regularExpression) else { continue }
            let full = String(chunk[aRange])
            guard let hrefOpen = full.range(of: #"href=""#) else { continue }
            let afterHref = full[hrefOpen.upperBound...]
            guard let hrefClose = afterHref.range(of: "\"") else { continue }
            let href = String(afterHref[..<hrefClose.lowerBound])
            guard let titleStart = full.range(of: #">([^<]+)</a>"#, options: .regularExpression) else { continue }
            let title = String(full[titleStart]).dropFirst().dropLast(4)
            if href.isEmpty || title.isEmpty { continue }
            // 摘要：新版 content-right_xxx；旧版 c-abstract
            var snippet = ""
            if let sRange = chunk.range(of: #"content-right_[A-Za-z0-9_]+[^>]*>(.*?)</span>"#, options: .regularExpression) {
                snippet = Self.stripTags(String(chunk[sRange]))
            } else if let sRange = chunk.range(of: #"class="c-abstract[^"]*"[^>]*>(.*?)</"#, options: .regularExpression) {
                snippet = Self.stripTags(String(chunk[sRange]))
            }
            items.append(SearchItem(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                    link: href, snippet: snippet.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return items.isEmpty ? nil : items
    }

    /// 拉取 Bing RSS 并解析；失败返回 nil
    private func fetchBingRSS(_ q: String) async -> [SearchItem]? {
        guard let url = URL(string: "https://www.bing.com/search?q=\(q)&format=rss&mkt=zh-CN&setlang=zh-hans") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
                     forHTTPHeaderField: "User-Agent")
        req.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        req.timeoutInterval = 20
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let xml = String(data: data, encoding: .utf8) else { return nil }
        let items = Self.parseRSSItems(xml)
        return items.isEmpty ? nil : items
    }

    /// 拉取 DuckDuckGo HTML 并解析；失败返回 nil
    private func fetchDuckDuckGo(_ q: String) async -> [SearchItem]? {
        guard let url = URL(string: "https://html.duckduckgo.com/html/?q=\(q)") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
                     forHTTPHeaderField: "User-Agent")
        req.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        req.timeoutInterval = 20
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else { return nil }
        var items: [SearchItem] = []
        let blocks = html.components(separatedBy: #"class="result results_links""#)
        for block in blocks.dropFirst().prefix(8) {
            // 完整匹配 <a class="result__a" href="...">标题</a>，再分别抠出 href 与标题文本
            guard let aRange = block.range(of: #"result__a[^>]*href="[^"]+"[^>]*>[^<]+</a>"#, options: .regularExpression) else { continue }
            let full = String(block[aRange])
            guard let hrefOpen = full.range(of: #"href=""#) else { continue }
            let afterHref = full[hrefOpen.upperBound...]
            guard let hrefClose = afterHref.range(of: "\"") else { continue }
            let href = String(afterHref[..<hrefClose.lowerBound])
            guard let titleStart = full.range(of: #">([^<]+)</a>"#, options: .regularExpression) else { continue }
            let title = String(full[titleStart]).dropFirst().dropLast(4)
            var snippet = ""
            if let sRange = block.range(of: #"class="result__snippet"[^>]*>(.*?)</a>"#, options: .regularExpression) {
                snippet = Self.stripTags(String(block[sRange]))
            }
            if !href.isEmpty && !title.isEmpty {
                items.append(SearchItem(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                        link: href, snippet: snippet.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
        return items.isEmpty ? nil : items
    }

    /// 解析 RSS XML 的 <item> 块（title/link/description）
    private static func parseRSSItems(_ xml: String) -> [SearchItem] {
        var items: [SearchItem] = []
        let blocks = xml.components(separatedBy: "<item>")
        for block in blocks.dropFirst() {
            let title = extractTag(block, "title")
            let link = extractTag(block, "link")
            var snippet = extractTag(block, "description")
            if snippet.hasPrefix("<") { snippet = stripTags(snippet) }
            if !title.isEmpty && !link.isEmpty {
                items.append(SearchItem(title: title, link: link, snippet: snippet))
            }
        }
        return items
    }

    /// 提取单个 XML/HTML 标签内容（只取第一处）
    private static func extractTag(_ s: String, _ tag: String) -> String {
        guard let open = s.range(of: "<\(tag)>"), let close = s.range(of: "</\(tag)>", range: open.upperBound..<s.endIndex) else { return "" }
        return String(s[open.upperBound..<close.lowerBound])
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 统一格式化搜索结果
    private static func formatSearchResults(_ items: [SearchItem], query: String, source: String) -> String {
        guard !items.isEmpty else { return "搜索完成但未解析到结果（\(source) 通道异常），建议换关键词重试" }
        var lines = ["搜索结果（\(source)，关键词：\(query)）："]
        for (idx, it) in items.prefix(8).enumerated() {
            lines.append("\(idx + 1). \(it.title)")
            lines.append("   链接：\(it.link)")
            if !it.snippet.isEmpty { lines.append("   摘要：\(it.snippet)") }
        }
        return lines.joined(separator: "\n")
    }

    private static func stripTags(_ s: String) -> String {
        var t = s
        while let r = t.range(of: #"<[^>]+>"#, options: .regularExpression) {
            t.replaceSubrange(r, with: "")
        }
        return t.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func esc(_ v: String) -> String {
        if v.contains(",") || v.contains("\"") || v.contains("\n") {
            return "\"\(v.replacingOccurrences(of: "\"", with: "\"\"") )\""
        }
        return v
    }

    private static func num(_ v: Double) -> String {
        v.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(v)) : String(format: "%.1f", v)
    }

    private static var stampFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmm"
        return f
    }

    private static func dayStr(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}
