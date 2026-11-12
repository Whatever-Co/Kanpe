import Foundation
import os

private let log = Logger(subsystem: "co.whatever.Kanpe", category: "TopicTracker")

/// 会議の話題。`startedAt` はその話題が始まった行の時刻。
struct Topic: Equatable {
    var title: String
    var summary: String
    var startedAt: Date
}

/// 文字起こしを Claude に読ませて、今の話題を割り出す。話題が変わったら新しい `Topic` を足す。
///
/// 呼ぶのは「新しく確定した文字が `minNewChars` 以上たまり、前回から `minInterval` 以上たった」とき。
/// 同時に投げるのは 1 本だけ。
@MainActor
final class TopicTracker {
    private(set) var topics: [Topic] = []
    var onChange: (() -> Void)?
    /// 新しく見つかった質問（質問文と、質問が出た行）。同じ行は二度渡さない。
    var onQuestions: (([(question: String, lineID: UUID)]) -> Void)?
    private var reportedQuestionLines = Set<UUID>()
    /// 問い合わせの失敗（キー無効・残高切れなど）。続けて失敗しても 1 回だけ呼ぶ。
    var onError: ((String) -> Void)?
    private var reportedError = false

    private let apiKey: String
    private let context: [String: Any]?
    private var inFlight = false
    private var lastRequestAt = Date.distantPast
    private var charsAtLastRequest = 0

    // 質問を見つけるのも兼ねるので、間隔は短め。
    private let minNewChars = 200
    private let minInterval: TimeInterval = 15
    /// Claude に渡す直近の行数。
    private let windowLines = 40

    /// `topics`：会議の途中で作り直したとき、それまでの話題を引き継ぐ。
    init(apiKey: String, context: [String: Any]?, topics: [Topic] = []) {
        self.apiKey = apiKey
        self.context = context
        self.topics = topics
    }

    /// 行が増えるたびに呼ぶ。条件を満たしたら裏で問い合わせる。
    func linesDidChange(_ lines: [SubtitleLine]) {
        let chars = lines.reduce(0) { $0 + $1.original.count }
        guard !inFlight,
              chars - charsAtLastRequest >= minNewChars,
              Date().timeIntervalSince(lastRequestAt) >= minInterval else { return }
        inFlight = true
        lastRequestAt = Date()
        charsAtLastRequest = chars
        let window = Array(lines.suffix(windowLines))
        Task {
            defer { inFlight = false }
            do {
                let result = try await analyze(window)
                reportedError = false
                apply(result, window: window)
            } catch {
                log.error("topic analysis failed: \(error.localizedDescription, privacy: .public)")
                if !reportedError {
                    reportedError = true
                    onError?("話題・質問の割り出し失敗: \(error.localizedDescription)")
                }
            }
        }
    }

    private struct Result: Decodable {
        let topic: String
        let summary: String
        let changed: Bool
        /// 新しい話題が始まった行の番号（プロンプトで振った 0 始まりの番号）。変わっていなければ -1。
        let changedAtLine: Int
        let questions: [Question]

        struct Question: Decodable {
            let question: String
            let line: Int
        }

        enum CodingKeys: String, CodingKey {
            case topic, summary, changed, questions
            case changedAtLine = "changed_at_line"
        }
    }

    private func apply(_ result: Result, window: [SubtitleLine]) {
        let questions = result.questions.compactMap { q -> (question: String, lineID: UUID)? in
            guard window.indices.contains(q.line), !q.question.isEmpty else { return nil }
            let id = window[q.line].id
            guard reportedQuestionLines.insert(id).inserted else { return nil }
            return (q.question, id)
        }
        if !questions.isEmpty { onQuestions?(questions) }

        if let current = topics.last, !result.changed {
            // 同じ話題のまま：名前と要約だけ更新する。
            topics[topics.count - 1].title = result.topic
            topics[topics.count - 1].summary = result.summary
            if current != topics.last { onChange?() }
            return
        }
        // 新しい話題は今の話題より後に始まる。Claude が今の話題の開始より前の行を指したら
        // （2026-10-21 の会議で、空の見出しと順番の入れ替わりが出た）、今の話題の次の行まで後ろにずらす。
        var lowerBound = 0
        if let last = topics.last {
            guard let after = window.firstIndex(where: { $0.startedAt > last.startedAt }) else { return }
            lowerBound = after
        }
        var index = window.indices.contains(result.changedAtLine) ? result.changedAtLine : lowerBound
        index = max(index, lowerBound)
        guard window.indices.contains(index) else { return }
        let startedAt = window[index].startedAt
        topics.append(Topic(title: result.topic, summary: result.summary, startedAt: startedAt))
        onChange?()
    }

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static let system = """
    あなたは会議の書記です。リアルタイムの文字起こし（自動認識なので誤字や話者の取り違えがあります）を読み、\
    いま話されている話題を割り出します。

    - topic: いまの話題を短い日本語の名詞句で（20 字以内）。会議全体の主題ではなく、直近で話している具体的な話題にする
    - summary: その話題でいま何が話されているかを日本語で 1 文（60 字以内）
    - changed: 「これまでの話題」の最後のものから話題が移ったなら true。同じ話題の続き・言い換え・細部なら false。\
    まだ話題がなければ true
    - changed_at_line: changed が true のとき、新しい話題が始まった行の番号。「ここから話題」の目印より後の行から選ぶ。\
    false なら -1

    - questions: 直近の会話で出た、答えのある質問（情報・数字・事実・経緯・方針を尋ねるもの）。\
    question は日本語で、文脈を補って単独で意味が通る文にする。line はその質問が出た行の番号。\
    挨拶・相づち・「聞こえますか」のような確認・修辞的な問いは含めない。なければ空配列

    相づちや雑談の一言だけで話題を変えたと判断しないこと。
    """

    private func analyze(_ window: [SubtitleLine]) async throws -> Result {
        var prompt = ""
        if let context, let data = try? JSONSerialization.data(withJSONObject: context),
           let json = String(data: data, encoding: .utf8) {
            prompt += "## 会議の前提（用語セット）\n\(json)\n\n"
        }
        prompt += "## これまでの話題\n"
        prompt += topics.isEmpty ? "（まだない）\n" : topics.map { "- \($0.title)：\($0.summary)" }.joined(separator: "\n") + "\n"
        prompt += "\n## 直近の文字起こし\n"
        let currentStart = topics.last.flatMap { last in window.firstIndex { $0.startedAt >= last.startedAt } }
        for (i, line) in window.enumerated() {
            if i == currentStart, let current = topics.last {
                prompt += "--- ここから話題「\(current.title)」 ---\n"
            }
            var text = "[\(i)] \(Self.timeFormat.string(from: line.startedAt)) \(line.label): \(line.original)"
            if !line.translation.isEmpty { text += "（訳: \(line.translation)）" }
            prompt += text + "\n"
        }

        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "topic": ["type": "string"],
                "summary": ["type": "string"],
                "changed": ["type": "boolean"],
                "changed_at_line": ["type": "integer"],
                "questions": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "question": ["type": "string"],
                            "line": ["type": "integer"],
                        ],
                        "required": ["question", "line"],
                        "additionalProperties": false,
                    ],
                ],
            ],
            "required": ["topic", "summary", "changed", "changed_at_line", "questions"],
            "additionalProperties": false,
        ]
        return try await AnthropicClient(apiKey: apiKey)
            .structured(Result.self, system: Self.system, prompt: prompt, schema: schema)
    }
}
