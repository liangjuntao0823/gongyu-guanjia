//
//  AIRequestService.swift
//  公寓管家 · 火山方舟（豆包）对话请求（v1.85）
//  约束：API Key 仅存本地钥匙串；端点/模型可在设置页修改，不写死
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

    /// 发送一轮对话，返回助手文本
    static func send(apiKey: String, baseURL: String, model: String,
                     systemPrompt: String, userText: String) async throws -> String {
        guard let url = URL(string: baseURL) else { throw AIRequestError.parse }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userText]
            ],
            "temperature": 0.7
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 60

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
}
