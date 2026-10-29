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
        case .http(let code, let msg): return "请求失败（\(code)）：\(msg)"
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
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                ?? String(String(data: data, encoding: .utf8)?.prefix(200) ?? "")
            throw AIRequestError.http(http.statusCode, msg)
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
}
