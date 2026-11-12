import Foundation

/// API キーが実際に使えるかの確認結果。
enum KeyCheck: Equatable {
    case missing
    case checking
    case ok
    case failed(String)
}

/// 料金のかからない API を 1 回呼んで、キーが使えるかを確かめる。
enum KeyValidator {
    /// Soniox：ファイル一覧（GET /v1/files）。
    static func soniox(_ key: String) async -> KeyCheck {
        var request = URLRequest(url: URL(string: "https://api.soniox.com/v1/files?limit=1")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return await check(request)
    }

    /// Anthropic：モデル一覧（GET /v1/models）。
    static func anthropic(_ key: String) async -> KeyCheck {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=1")!)
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        return await check(request)
    }

    private static func check(_ request: URLRequest) async -> KeyCheck {
        var request = request
        request.timeoutInterval = 15
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200..<300: return .ok
            case 401, 403: return .failed("キーが無効（HTTP \(status)）")
            default: return .failed("確認できない（HTTP \(status)）")
            }
        } catch {
            return .failed("接続できない：\(error.localizedDescription)")
        }
    }
}
