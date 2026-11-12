import Foundation

/// 会議ごとに Soniox へ渡す context（用語・訳語・話題）の置き場。
/// `~/Documents/Kanpe/Contexts/<名前>.json` の中身は Soniox の `context` オブジェクトそのまま
/// （`general` / `text` / `terms` / `translation_terms`）。
enum ContextLibrary {
    static let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Kanpe")
        .appendingPathComponent("Contexts")

    static func names() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    /// Kanpe 自身の設定（`"kanpe": {"project": "ghostline"}`）。Soniox には送らない。
    static let kanpeKey = "kanpe"

    /// 読み込んだ context を、Soniox に送る部分とプロジェクト名に分ける。
    static func split(_ context: [String: Any]?) -> (soniox: [String: Any]?, project: String?) {
        guard var context else { return (nil, nil) }
        let project = (context[kanpeKey] as? [String: Any])?["project"] as? String
        context.removeValue(forKey: kanpeKey)
        return (context.isEmpty ? nil : context, project)
    }

    static func load(_ name: String) throws -> [String: Any] {
        let url = folder.appendingPathComponent(name).appendingPathExtension("json")
        let data = try Data(contentsOf: url)
        guard let context = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "Kanpe", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "\(name).json が JSON オブジェクトではない"])
        }
        return context
    }
}
