import Foundation

/// 会議が終わったあとで、文字起こし全体を一度に Claude に読ませて話題に区切る。
/// 会議中の `TopicTracker` と違い、前後の文脈を全部見て区切れる。
struct TopicSummarizer {
    let apiKey: String
    let context: [String: Any]?

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static let system = """
    あなたは会議の書記です。会議全体の文字起こし（自動認識なので誤字や話者の取り違えがあります）を読み、\
    話題ごとに区切ります。

    - 各話題に title（20 字以内の日本語の名詞句）、summary（そこで話されたことや決まったことを日本語で 1〜2 文）、\
    start_line（その話題が始まる行の番号）をつける
    - 話題は時間の順に並べ、start_line は前の話題より大きくする。最初の話題の start_line は 0
    - 相づちや一言の脱線で区切らない。会議の長さに対して多すぎない数にする（30 分で 5〜10 個が目安）
    """

    func topics(for lines: [SubtitleLine]) async throws -> [Topic] {
        guard !lines.isEmpty else { return [] }
        var prompt = ""
        if let context, let data = try? JSONSerialization.data(withJSONObject: context),
           let json = String(data: data, encoding: .utf8) {
            prompt += "## 会議の前提（用語セット）\n\(json)\n\n"
        }
        prompt += "## 文字起こし\n"
        for (i, line) in lines.enumerated() {
            var text = "[\(i)] \(Self.timeFormat.string(from: line.startedAt)) \(line.label): \(line.original)"
            if !line.translation.isEmpty { text += "（訳: \(line.translation)）" }
            prompt += text + "\n"
        }

        struct Result: Decodable {
            struct Item: Decodable {
                let title: String
                let summary: String
                let startLine: Int
                enum CodingKeys: String, CodingKey {
                    case title, summary
                    case startLine = "start_line"
                }
            }
            let topics: [Item]
        }
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "topics": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "title": ["type": "string"],
                            "summary": ["type": "string"],
                            "start_line": ["type": "integer"],
                        ],
                        "required": ["title", "summary", "start_line"],
                        "additionalProperties": false,
                    ],
                ],
            ],
            "required": ["topics"],
            "additionalProperties": false,
        ]
        let result = try await AnthropicClient(apiKey: apiKey)
            .structured(Result.self, system: Self.system, prompt: prompt, schema: schema, maxTokens: 16000)

        // 範囲外・逆順の start_line は捨てる（見出しが空になったり順番が入れ替わったりしないように）。
        var topics: [Topic] = []
        var previous = -1
        for item in result.topics where lines.indices.contains(item.startLine) && item.startLine > previous {
            topics.append(Topic(title: item.title, summary: item.summary, startedAt: lines[item.startLine].startedAt))
            previous = item.startLine
        }
        return topics
    }
}
