import Foundation

/// Soniox リアルタイム WebSocket の受信メッセージ（翻訳あり）。
/// 各 token は is_final=true（確定/不変）か false（暫定/次のレスポンスで置き換わる）。
/// translation_status は "original"（翻訳される発話）/ "translation"（訳文）/
/// "none"（ターゲット言語の発話で訳さない）。
struct SonioxResponse: Decodable {
    struct Token: Decodable {
        let text: String
        let isFinal: Bool
        let translationStatus: String?
        /// 話者分離が有効なときの話者ラベル（"1", "2", ...）。
        let speaker: String?

        enum CodingKeys: String, CodingKey {
            case text, speaker
            case isFinal = "is_final"
            case translationStatus = "translation_status"
        }

        init(text: String, isFinal: Bool, translationStatus: String? = nil, speaker: String? = nil) {
            self.text = text
            self.isFinal = isFinal
            self.translationStatus = translationStatus
            self.speaker = speaker
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            text = try c.decode(String.self, forKey: .text)
            isFinal = try c.decodeIfPresent(Bool.self, forKey: .isFinal) ?? false
            translationStatus = try c.decodeIfPresent(String.self, forKey: .translationStatus)
            // 文字列でも数値でも受ける（型違いでレスポンスごと捨てないため）。
            if let s = try? c.decodeIfPresent(String.self, forKey: .speaker) {
                speaker = s
            } else if let n = try? c.decodeIfPresent(Int.self, forKey: .speaker) {
                speaker = String(n)
            } else {
                speaker = nil
            }
        }

        var isTranslation: Bool { translationStatus == "translation" }
        /// サーバが挿入する区切りマーカー（本文テキストではない）。`<end>` は endpoint 検出、`<fin>` は finalize の完了。
        var isEndpoint: Bool { text == "<end>" || text == "<fin>" }
    }

    let tokens: [Token]
    let finished: Bool?
    let errorCode: Int?
    let errorMessage: String?

    enum CodingKeys: String, CodingKey {
        case tokens, finished
        case errorCode = "error_code"
        case errorMessage = "error_message"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tokens = try c.decodeIfPresent([Token].self, forKey: .tokens) ?? []
        finished = try c.decodeIfPresent(Bool.self, forKey: .finished)
        errorCode = try c.decodeIfPresent(Int.self, forKey: .errorCode)
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
    }

    /// サーバがエラーを返したか（残高切れ・認証失敗・不正 config など）。
    /// 再接続しても解決しないので、再接続を止める判断に使う。
    var isError: Bool { errorMessage != nil || errorCode != nil }
}
