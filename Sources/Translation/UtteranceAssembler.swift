import Foundation

enum Speaker: Hashable, CaseIterable {
    /// 会議の相手（システム音声）。
    case remote
    /// 自分（マイク）。
    case me
    /// ハイブリッド・対面の会議で、マイクに入る複数人。
    case room

    var label: String {
        switch self {
        case .remote: "相手"
        case .me: "自分"
        case .room: "話者"
        }
    }
    /// 1 人とは限らない音源。話者分離と翻訳をかける。
    var isGroup: Bool { self != .me }
    var recordingName: String {
        switch self {
        case .remote: "remote"
        case .me: "me"
        case .room: "room"
        }
    }
}

/// 原文と訳文の 1 組。字幕の 1 行。
struct SubtitleLine: Identifiable, Equatable {
    let id = UUID()
    var original: String
    var translation: String
    var speaker: Speaker = .remote
    /// 話者分離のラベル（"1", "2", ...）。分離していない音源では nil。
    var voice: String?
    var startedAt = Date()

    /// 会議中につけた名前（「話者 2」→「田中さん」）。
    var name: String?

    var label: String {
        if let name { return name }
        guard speaker.isGroup, let voice else { return speaker.label }
        return "\(speaker.label) \(voice)"
    }
}

/// Soniox のトークン列を字幕行に組み立てる。
///
/// - 確定トークンは今の発話に足していく。暫定トークンはレスポンスごとに置き換わる。
/// - `<end>`（endpoint）か、確定した原文の話者が変わったところで、今の発話を 1 行として確定する。
/// - 確定後に届いた訳文は、直前の行の訳の続きとして扱う（訳文は原文より遅れて届くため）。
///   訳文に話者が付いていればそれで判定し、付いていなければ「次の原文がまだ来ていない」ことで判定する。
struct UtteranceAssembler {
    enum Event {
        /// 行が確定した。
        case commit(SubtitleLine)
        /// 直前に確定した行の訳文に続きが届いた。
        case appendToLast(translation: String)
    }

    private var finalOriginal = ""
    private var finalTranslation = ""
    /// 直前の確定から、まだ新しい原文が来ていない。
    private var justCommitted = false
    /// 今の発話の最初の原文トークンが届いた時刻。
    private var startedAt: Date?
    /// 1 人が話し続けても行が伸び続けないよう、この長さを超えたら文の終わりで区切る。
    /// endpoint 検出を切っている音源（話者分離あり）では `<end>` が来ないため（2026-10-21、
    /// 数分ぶんが 1 行のまま確定しなかった）。`hardLimit` に達したら文の途中でも区切る。
    private let softLimit = 120
    private let hardLimit = 300
    private static let sentenceEnds: Set<Character> = ["。", "？", "！", "?", "!", "."]

    /// 今の発話の話者と、直前に確定した行の話者。
    private var currentVoice: String?
    private var lastCommittedVoice: String?

    /// 今の発話（確定＋暫定）。UI のライブ行に出す。
    private(set) var live = SubtitleLine(original: "", translation: "")

    mutating func consume(_ tokens: [SonioxResponse.Token]) -> [Event] {
        var events: [Event] = []
        var volatileOriginal = ""
        var volatileTranslation = ""

        for token in tokens {
            if token.isEndpoint {
                if let line = commitPending() { events.append(.commit(line)) }
                continue
            }
            if token.isFinal {
                if token.isTranslation {
                    if belongsToLastLine(token) {
                        events.append(.appendToLast(translation: token.text))
                    } else {
                        finalTranslation += token.text
                    }
                } else {
                    if let voice = token.speaker, let current = currentVoice, voice != current,
                       let line = commitPending() {
                        events.append(.commit(line))
                    }
                    if let voice = token.speaker { currentVoice = voice }
                    justCommitted = false
                    if startedAt == nil { startedAt = Date() }
                    finalOriginal += token.text
                    if isLongEnough, let line = commitPending() {
                        events.append(.commit(line))
                        // 同じ人が続けて話すので、次の行も同じ話者として始める。
                        currentVoice = token.speaker ?? lastCommittedVoice
                    }
                }
            } else if token.isTranslation {
                volatileTranslation += token.text
            } else {
                if startedAt == nil { startedAt = Date() }
                volatileOriginal += token.text
            }
        }

        live = SubtitleLine(
            original: (finalOriginal + volatileOriginal).trimmingCharacters(in: .whitespaces),
            translation: (finalTranslation + volatileTranslation).trimmingCharacters(in: .whitespaces),
            voice: currentVoice
        )
        return events
    }

    private var isLongEnough: Bool {
        let length = finalOriginal.count
        if length >= hardLimit { return true }
        guard length >= softLimit, let last = finalOriginal.trimmingCharacters(in: .whitespaces).last else { return false }
        return Self.sentenceEnds.contains(last)
    }

    private func belongsToLastLine(_ token: SonioxResponse.Token) -> Bool {
        if let voice = token.speaker, let last = lastCommittedVoice {
            return voice == last && voice != currentVoice
        }
        return justCommitted && finalOriginal.isEmpty
    }

    /// 残っている確定分を 1 行として吐き出す。停止時にも使う。
    mutating func commitPending() -> SubtitleLine? {
        let original = finalOriginal.trimmingCharacters(in: .whitespacesAndNewlines)
        let translation = finalTranslation.trimmingCharacters(in: .whitespacesAndNewlines)
        finalOriginal = ""
        finalTranslation = ""
        live = SubtitleLine(original: "", translation: "")
        let lineStart = startedAt ?? Date()
        let voice = currentVoice
        startedAt = nil
        currentVoice = nil
        guard !original.isEmpty || !translation.isEmpty else { return nil }
        justCommitted = true
        lastCommittedVoice = voice
        return SubtitleLine(original: original, translation: translation, voice: voice, startedAt: lineStart)
    }
}
