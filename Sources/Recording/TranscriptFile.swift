import Foundation
import os

private let log = Logger(subsystem: "co.whatever.Kanpe", category: "TranscriptFile")

/// 会議の文字起こしを Markdown で保存する。行が確定・更新されるたびに全体を書き直す
/// （遅れて届いた訳文で前の行が変わるため、追記ではなく上書き）。
struct TranscriptFile {
    let url: URL
    let startedAt: Date

    private static let titleFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    func save(_ lines: [SubtitleLine], topics: [Topic] = [], notes: [String] = []) {
        var text = "# Kanpe \(Self.titleFormat.string(from: startedAt))\n\n"
        for note in notes { text += "> \(note)\n" }
        if !notes.isEmpty { text += "\n" }
        var pending = topics[...]
        for line in lines {
            // 話題が変わった行の直前に見出しを入れる。
            while let topic = pending.first, topic.startedAt <= line.startedAt {
                text += "\n## \(Self.timeFormat.string(from: topic.startedAt)) \(topic.title)\n\n\(topic.summary)\n\n"
                pending = pending.dropFirst()
            }
            text += "- \(Self.timeFormat.string(from: line.startedAt)) \(line.label): \(line.original)\n"
            if !line.translation.isEmpty {
                text += "  - \(line.translation)\n"
            }
        }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            log.error("save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
