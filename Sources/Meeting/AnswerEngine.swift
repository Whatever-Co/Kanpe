import Foundation

/// 会議で出た質問への「カンペ」。
struct KanpeAnswer: Identifiable, Equatable {
    enum Status: Equatable {
        case searching
        /// Claude Code（`claude -p`）で Slack・Notion・Drive などを探している。
        case deepSearching
        case answered
        case notFound
        case failed(String)
    }

    let id = UUID()
    let question: String
    /// 質問が出た行（自分で聞いたときは nil）。
    let lineID: UUID?
    let askedAt: Date
    var status = Status.searching
    /// 日本語の答え。
    var answer = ""
    /// そのまま口に出せる英語の一文（相手が英語のとき用）。
    var sayEnglish = ""
    /// 根拠にした記憶の抜粋。
    var sources: [String] = []
    /// 深掘り検索（Slack・Notion・Drive など）をもう済ませたか。
    var deepSearched = false
    /// 記憶（Cognee・Anthropic）を探せなかった理由。深掘りでも見つからなかったときに出す。
    var memoryError: String?
    /// 会議で見つかった質問への自動の答え（自分で聞いたものではない）。
    var auto = false
}

/// 質問に、Cognee の記憶だけを根拠に答える（直近の会話は質問の意図を汲むため）。記憶にないことは推測で答えさせない。
struct AnswerEngine {
    let apiKey: String
    let project: String?

    struct Result {
        let found: Bool
        let answer: String
        let sayEnglish: String
        let sources: [String]
    }

    private static let system = """
    あなたは会議中のユーザーの横にいるアシスタントです。会議で出た質問に対して、\
    ユーザーがすぐ答えられるよう「カンペ」を作ります。

    - 根拠は「記憶」に書かれていることだけ。記憶にないこと・推測は書かない。記憶で答えられなければ found を false にする
    - answer：日本語で 1〜3 文。数字・固有名詞・決めたことを優先し、結論から書く
    - say_en：会議が英語のとき、そのまま口に出せる自然な英語の一文。日本語だけの会議なら空文字
    - sources：根拠にした記憶の番号（0 始まり）
    - 文字起こしは自動認識なので誤字や話者の取り違えがある。質問の意図を汲んで答える
    """

    func answer(question: String, topic: Topic?, recent: [SubtitleLine]) async throws -> Result {
        var query = question
        if let project { query = "\(project) \(query)" }
        if let topic { query += " \(topic.title)" }
        let memories = try await CogneeClient().recall(query)
        guard !memories.isEmpty else { return Result(found: false, answer: "", sayEnglish: "", sources: []) }

        var prompt = ""
        if let project { prompt += "## プロジェクト\n\(project)\n\n" }
        if let topic { prompt += "## いまの話題\n\(topic.title)：\(topic.summary)\n\n" }
        prompt += "## 直近の会話\n"
        for line in recent.suffix(20) {
            var text = "\(line.label): \(line.original)"
            if !line.translation.isEmpty { text += "（訳: \(line.translation)）" }
            prompt += text + "\n"
        }
        prompt += "\n## 質問\n\(question)\n\n## 記憶\n"
        for (i, memory) in memories.enumerated() {
            prompt += "[\(i)] \(memory.prefix(1500))\n\n"
        }

        struct Output: Decodable {
            let found: Bool
            let answer: String
            let sayEn: String
            let sources: [Int]
            enum CodingKeys: String, CodingKey {
                case found, answer, sources
                case sayEn = "say_en"
            }
        }
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "found": ["type": "boolean"],
                "answer": ["type": "string"],
                "say_en": ["type": "string"],
                "sources": ["type": "array", "items": ["type": "integer"]],
            ],
            "required": ["found", "answer", "say_en", "sources"],
            "additionalProperties": false,
        ]
        let output = try await AnthropicClient(apiKey: apiKey)
            .structured(Output.self, system: Self.system, prompt: prompt, schema: schema)
        let sources = output.sources.filter { memories.indices.contains($0) }.map { String(memories[$0].prefix(300)) }
        return Result(found: output.found, answer: output.answer, sayEnglish: output.sayEn, sources: sources)
    }
}
