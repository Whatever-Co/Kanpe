import Foundation

/// Claude Messages API を 1 回呼び、JSON スキーマで固定した出力をデコードして返す。
/// Swift には公式 SDK がないので raw HTTP。
struct AnthropicClient {
    let apiKey: String
    var model = "claude-sonnet-5-5"

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    func structured<T: Decodable>(_ type: T.Type, system: String, prompt: String,
                                  schema: [String: Any], maxTokens: Int = 4000) async throws -> T {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "output_config": [
                "effort": "low",
                "format": ["type": "json_schema", "schema": schema],
            ],
            // 安全分類器に断られたとき、サーバ側で別モデルにやり直させる。
            "fallbacks": "default",
            "messages": [["role": "user", "content": prompt]],
        ]

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "Anthropic", code: status,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(status): \(detail.prefix(300))"])
        }
        let message = try JSONDecoder().decode(Message.self, from: data)
        guard message.stopReason != "refusal" else {
            throw NSError(domain: "Anthropic", code: 0, userInfo: [NSLocalizedDescriptionKey: "refusal"])
        }
        guard let text = message.content.first(where: { $0.type == "text" })?.text,
              let json = text.data(using: .utf8) else {
            throw NSError(domain: "Anthropic", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "no text block (stop_reason: \(message.stopReason ?? "-"))"])
        }
        return try JSONDecoder().decode(T.self, from: json)
    }
}

/// Messages API の応答のうち、ここで使う部分。
private struct Message: Decodable {
    struct Block: Decodable {
        let type: String
        let text: String?
    }
    let content: [Block]
    let stopReason: String?
    enum CodingKeys: String, CodingKey {
        case content
        case stopReason = "stop_reason"
    }
}
