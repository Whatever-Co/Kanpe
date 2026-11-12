import Foundation

/// 会議の言語（設定ウィンドウで選ぶ）。値は Soniox の言語コード。
/// 相手 = システム音声、マイク = 自分（オンライン）と同じ部屋の人（ハイブリッド・対面）。
struct MeetingLanguages: Equatable {
    var remote: String
    var mic: String
    /// 訳す先。この言語で話された部分は Soniox が訳さない（トークンごとに判定する）。
    var target: String

    static let choices: [(code: String, label: String)] = [
        ("ja", "日本語"), ("en", "英語"), ("zh", "中国語"), ("ko", "韓国語"),
        ("es", "スペイン語"), ("fr", "フランス語"), ("de", "ドイツ語"), ("pt", "ポルトガル語"),
        ("it", "イタリア語"), ("vi", "ベトナム語"), ("th", "タイ語"), ("id", "インドネシア語"),
    ]

    func source(for speaker: Speaker) -> String {
        speaker == .remote ? remote : mic
    }

    /// 翻訳するか。複数人の音源だけ（自分の発言は訳さない）。マイクの言語が訳す先と同じでも、
    /// ハイブリッドでは隣の人が別の言語で話すことがあるので切らない。
    func translates(_ speaker: Speaker) -> Bool {
        speaker.isGroup
    }

    /// Soniox の `language_hints`：その音源の言語を先頭に、設定したほかの言語も混ざりうるので後ろに。
    func hints(for speaker: Speaker) -> [String] {
        var hints: [String] = []
        for code in [source(for: speaker), remote, mic, target] where !hints.contains(code) { hints.append(code) }
        return hints
    }

    static var stored: MeetingLanguages {
        let d = UserDefaults.standard
        return MeetingLanguages(remote: d.string(forKey: "remoteLanguage") ?? "en",
                                mic: d.string(forKey: "micLanguage") ?? "ja",
                                target: d.string(forKey: "targetLanguage") ?? "ja")
    }

    func store() {
        let d = UserDefaults.standard
        d.set(remote, forKey: "remoteLanguage")
        d.set(mic, forKey: "micLanguage")
        d.set(target, forKey: "targetLanguage")
    }
}
