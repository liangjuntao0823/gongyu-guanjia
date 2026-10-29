//
//  AIRequestService.swift
//  公寓管家 · 火山方舟（豆包）对话请求（v1.88）
//  约束：API Key 仅存本地钥匙串；端点/模型可在设置页修改，不写死
//  v1.88：支持多轮对话（history）+ 图片多模态（image_url data URL）
//

import Foundation

enum AIRequestError: LocalizedError {
    case noKey
    case http(Int, String)
    case parse
    var errorDescription: String? {
        switch self {
        case .noKey: return "请先在 AI 助手设置里填写 API Key"
        case .http(let code, let rawMsg):
            // v1.93：火山方舟常见错误码中文化，不再直接甩英文 JSON
            let msg = rawMsg
            if msg.contains("ModelNotOpen") || msg.contains("has not activated") {
                return "模型未开通：该模型还没在火山方舟开通服务。请到火山方舟控制台「开通管理」页开通后重试，或先在设置里切换回已开通的模型（如 turbo）。"
            }
            if msg.contains("QuotaExhausted") || msg.contains("FreeTrialQuotaExhausted") || msg.contains("InsufficientBalance") || code == 402 || code == 429 {
                return "额度不足或请求过于频繁：免费额度可能已用完，请到火山方舟控制台「开通管理」确认额度与计费，稍后再试。"
            }
            if msg.contains("InvalidApiKey") || msg.contains("AccessDenied") || code == 401 || code == 403 {
                return "API Key 无效或没有权限：请到设置页检查 Key 是否正确（只保存在本机钥匙串）。"
            }
            if msg.contains("ModelOverloaded") || msg.contains("RequestLimit") || msg.contains("TooManyRequests") {
                return "模型服务繁忙，请稍后再试。"
            }
            if msg.contains("ModelNotFound") || msg.contains("EndpointNotFound") || msg.contains("does not exist") {
                return "模型不存在或无权访问：请确认设置里的模型 ID 正确，或切换到已开通模型。"
            }
            // 兜底：截断原始内容，避免整屏英文 JSON
            let trimmed = String(msg.prefix(120))
            return "请求失败（\(code)）：\(trimmed.isEmpty ? "未知错误" : trimmed)"
        case .parse: return "返回内容解析失败"
        }
    }
}

struct AIRequestService {

    /// 默认端点（火山方舟 OpenAI 兼容接口）；设置页可改
    static let defaultBaseURL = "https://ark.cn-beijing.volces.com/api/v3/chat/completions"

    /// 一轮对话里的历史消息（只传文本，历史图片不重传，控制 token）
    struct ChatTurn {
        let role: String          // "user" / "assistant"
        let text: String
    }

    /// 发送多轮对话（支持图片多模态），返回助手文本
    /// - Parameters:
    ///   - history: 之前的历史轮次（user/assistant 交替，不含 system）
    ///   - userText: 本轮用户文本
    ///   - userImages: 本轮附带图片的 data URL（data:image/jpeg;base64,...），空则不传图
    static func send(apiKey: String, baseURL: String, model: String,
                     systemPrompt: String,
                     history: [ChatTurn],
                     userText: String,
                     userImages: [String]) async throws -> String {
        guard let url = URL(string: baseURL) else { throw AIRequestError.parse }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        var messages: [[String: Any]] = [["role": "system", "content": systemPrompt]]
        for turn in history {
            messages.append(["role": turn.role, "content": turn.text])
        }
        // 本轮 user 消息：无图传纯文本，有图传多模态 content 数组
        let userContent: Any
        if userImages.isEmpty {
            userContent = userText
        } else {
            var parts: [[String: Any]] = [["type": "text", "text": userText]]
            for img in userImages {
                parts.append(["type": "image_url", "image_url": ["url": img]])
            }
            userContent = parts
        }
        messages.append(["role": "user", "content": userContent])

        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "temperature": 0.7
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 90

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw AIRequestError.parse }
        guard (200..<300).contains(http.statusCode) else {
            // v1.93：解析 error 对象（code+message），供中文化映射识别（如 ModelNotOpen）
            var raw = String(String(data: data, encoding: .utf8)?.prefix(300) ?? "")
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = obj["error"] as? [String: Any] {
                let code = err["code"] as? String ?? ""
                let message = err["message"] as? String ?? ""
                raw = code.isEmpty ? message : "\(code) \(message)"
            }
            throw AIRequestError.http(http.statusCode, raw)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AIRequestError.parse
        }
        return content
    }

    /// 便捷重载：单轮对话
    static func send(apiKey: String, baseURL: String, model: String,
                     systemPrompt: String, userText: String) async throws -> String {
        try await send(apiKey: apiKey, baseURL: baseURL, model: model,
                       systemPrompt: systemPrompt, history: [], userText: userText, userImages: [])
    }

    // MARK: - v1.96 AI 工具调用（function calling）

    /// AI 返回的一次工具调用（结构化参数 JSON 字符串）
    struct AIToolCall: Codable, Equatable {
        let id: String
        let name: String
        let arguments: String
    }

    /// 一次补全结果：content 可为 nil（纯工具调用轮），toolCalls 可同时多个
    struct AICompletion {
        let content: String?
        let toolCalls: [AIToolCall]
    }

    /// 通用请求：消息与工具由调用方构造，支持工具循环（assistant 带 tool_calls / tool 结果消息逐轮追加后重发）
    static func sendMessages(apiKey: String, baseURL: String, model: String,
                             messages: [[String: Any]],
                             tools: [[String: Any]] = []) async throws -> AICompletion {
        guard let url = URL(string: baseURL) else { throw AIRequestError.parse }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "temperature": 0.4
        ]
        if !tools.isEmpty {
            body["tools"] = tools
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 240 // v1.97：工具定义多+回复长，120s 易超时（用户实测生成账单超时）；提到 240s

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw AIRequestError.parse }
        guard (200..<300).contains(http.statusCode) else {
            var raw = String(String(data: data, encoding: .utf8)?.prefix(300) ?? "")
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = obj["error"] as? [String: Any] {
                let code = err["code"] as? String ?? ""
                let message = err["message"] as? String ?? ""
                raw = code.isEmpty ? message : "\(code) \(message)"
            }
            throw AIRequestError.http(http.statusCode, raw)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any] else {
            throw AIRequestError.parse
        }
        // content 可为 null（纯工具调用轮），NSNull 转 nil
        let content: String?
        if let c = message["content"] as? String {
            content = c
        } else {
            content = nil
        }
        // 解析 tool_calls（可为多个）
        var calls: [AIToolCall] = []
        if let rawCalls = message["tool_calls"] as? [[String: Any]] {
            for raw in rawCalls {
                if let id = raw["id"] as? String,
                   let fn = raw["function"] as? [String: Any],
                   let name = fn["name"] as? String,
                   let arguments = fn["arguments"] as? String {
                    calls.append(AIToolCall(id: id, name: name, arguments: arguments))
                }
            }
        }
        return AICompletion(content: content, toolCalls: calls)
    }
}
