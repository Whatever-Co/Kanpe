import Foundation

/// 自前の Cognee（記憶の検索サーバー）に問い合わせる。
/// CHUNKS 検索はベクトル類似だけなので速い（実測 0.8 秒）。
struct CogneeClient {
    /// `defaults write co.whatever.Kanpe cogneeURL <url>` で設定する。未設定なら記憶は探さない。
    /// Tailscale 上のサーバーは IP ではなく MagicDNS の名前で指す：アプリの ATS 例外は `ts.net` の
    /// ドメインにしかかけておらず、Tailscale の 100.x アドレスへの http は止められるため。
    static var baseURL: URL? {
        UserDefaults.standard.string(forKey: "cogneeURL").flatMap(URL.init(string:))
    }

    /// 未設定なら空（記憶にない扱い → 深掘り検索へ）。
    func recall(_ query: String, topK: Int = 8) async throws -> [String] {
        guard let baseURL = Self.baseURL else { return [] }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/recall"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": query,
            "datasets": ["main_dataset"],
            "searchType": "CHUNKS",
            "topK": topK,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw NSError(domain: "Cognee", code: status, userInfo: [NSLocalizedDescriptionKey: "Cognee HTTP \(status)"])
        }
        struct Item: Decodable { let text: String? }
        return try JSONDecoder().decode([Item].self, from: data).compactMap(\.text)
    }
}
