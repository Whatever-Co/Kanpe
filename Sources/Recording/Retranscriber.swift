import AVFoundation
import Foundation
import os

private let log = Logger(subsystem: "co.whatever.Kanpe", category: "Retranscriber")

/// 会議の後で、保存した録音を Soniox の非同期モデル（`stt-async-v5`）にかけ直す。
/// 非同期は録音全体を見られるので、話者分離がリアルタイムよりずっと正確（Soniox のドキュメントによる）。
///
/// 複数の会議フォルダを渡すと 1 本にまとめ、いちばん古いフォルダに `transcript-final.md` と
/// 読む用の `transcript-final.html` を書く。
/// 各 m4a の作成時刻を録音の開始時刻とみなし、トークンの `start_ms` を足して全行を時刻順に並べる。
struct Retranscriber {
    let sonioxKey: String
    let anthropicKey: String?
    let context: [String: Any]?
    let languages: MeetingLanguages
    /// 進み具合（画面の表示用）。
    var progress: (String) -> Void = { _ in }

    private static let base = URL(string: "https://api.soniox.com/v1")!

    /// 書き出したファイルを返す。
    func run(folders: [URL]) async throws -> URL {
        let folders = folders.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard let outputFolder = folders.first else { throw failure("フォルダが選ばれていない") }

        var recordings: [(url: URL, speaker: Speaker)] = []
        for folder in folders {
            let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension == "m4a" {
                let name = file.deletingPathExtension().lastPathComponent
                let speaker: Speaker = name.hasPrefix("remote") ? .remote : name.hasPrefix("room") ? .room : .me
                recordings.append((file, speaker))
            }
        }
        guard !recordings.isEmpty else { throw failure("録音ファイルがない") }

        var lines: [SubtitleLine] = []
        var notes: [String] = []
        for (i, recording) in recordings.enumerated() {
            progress("文字起こし \(i + 1)/\(recordings.count)")
            // 録音中にアプリが終わると m4a の目次（moov）が書かれず、開けないファイルが残る。それは飛ばす。
            guard (try? AVAudioFile(forReading: recording.url)) != nil else {
                let path = recording.url.deletingLastPathComponent().lastPathComponent + "/" + recording.url.lastPathComponent
                notes.append("開けない録音を飛ばした: \(path)")
                continue
            }
            let start = try recording.url.resourceValues(forKeys: [.creationDateKey]).creationDate ?? Date()
            let tokens = try await transcribe(recording.url, speaker: recording.speaker)
            lines += Self.lines(from: tokens, speaker: recording.speaker, start: start)
        }
        lines.sort { $0.startedAt < $1.startedAt }
        lines = Self.collapsingBackchannels(lines)

        var topics: [Topic] = []
        if let anthropicKey {
            progress("話題を整理中")
            do {
                topics = try await TopicSummarizer(apiKey: anthropicKey, context: context).topics(for: lines)
            } catch {
                log.error("topic summary failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        let startedAt = lines.first?.startedAt ?? Date()
        TranscriptFile(url: outputFolder.appendingPathComponent("transcript-final.md"), startedAt: startedAt)
            .save(lines, topics: topics, notes: notes)
        let html = TranscriptHTML.render(title: "会議記録", startedAt: startedAt, lines: lines, topics: topics, notes: notes)
        let url = outputFolder.appendingPathComponent("transcript-final.html")
        try html.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Soniox async API

    private struct Token: Decodable {
        let text: String
        let startMs: Int?
        let speaker: String?
        let translationStatus: String?

        enum CodingKeys: String, CodingKey {
            case text, speaker
            case startMs = "start_ms"
            case translationStatus = "translation_status"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            text = try c.decode(String.self, forKey: .text)
            startMs = try c.decodeIfPresent(Int.self, forKey: .startMs)
            translationStatus = try c.decodeIfPresent(String.self, forKey: .translationStatus)
            if let s = try? c.decodeIfPresent(String.self, forKey: .speaker) {
                speaker = s
            } else if let n = try? c.decodeIfPresent(Int.self, forKey: .speaker) {
                speaker = String(n)
            } else {
                speaker = nil
            }
        }
    }

    /// アップロード → 文字起こし → 完了待ち → 取得。終わったら Soniox 上のファイルと結果を消す。
    private func transcribe(_ file: URL, speaker: Speaker) async throws -> [Token] {
        let fileID = try await upload(file)
        defer { Task { try? await request("DELETE", "files/\(fileID)") } }

        var config: [String: Any] = [
            "model": "stt-async-v5",
            "file_id": fileID,
            "language_hints": languages.hints(for: speaker),
            "enable_speaker_diarization": speaker.isGroup,
        ]
        if languages.translates(speaker) {
            config["translation"] = ["type": "one_way", "target_language": languages.target]
        }
        if let context { config["context"] = context }

        let created = try await request("POST", "transcriptions", json: config)
        guard let id = created["id"] as? String else { throw failure("transcription id がない") }
        defer { Task { try? await request("DELETE", "transcriptions/\(id)") } }

        // 終わらない状態のまま待ち続けると、再文字起こしのボタンが戻らなくなる。
        let deadline = Date().addingTimeInterval(3600)
        while true {
            let status = try await request("GET", "transcriptions/\(id)")
            switch status["status"] as? String {
            case "completed":
                let data = try await requestData("GET", "transcriptions/\(id)/transcript")
                struct Transcript: Decodable { let tokens: [Token] }
                return try JSONDecoder().decode(Transcript.self, from: data).tokens
            case "error":
                throw failure("Soniox: \(status["error_message"] as? String ?? "error")")
            default:
                guard Date() < deadline else {
                    throw failure("Soniox の文字起こしが 1 時間たっても終わらない（\(status["status"] as? String ?? "status なし")）")
                }
                try await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func upload(_ file: URL) async throws -> String {
        let boundary = "kanpe-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(file.lastPathComponent)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/mp4\r\n\r\n".data(using: .utf8)!)
        body.append(try Data(contentsOf: file))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: Self.base.appendingPathComponent("files"))
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue("Bearer \(sonioxKey)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let json = try object(from: try await send(req))
        guard let id = json["id"] as? String else { throw failure("file id がない") }
        return id
    }

    @discardableResult
    private func request(_ method: String, _ path: String, json: [String: Any]? = nil) async throws -> [String: Any] {
        let data = try await requestData(method, path, json: json)
        return data.isEmpty ? [:] : try object(from: data)
    }

    private func requestData(_ method: String, _ path: String, json: [String: Any]? = nil) async throws -> Data {
        var req = URLRequest(url: Self.base.appendingPathComponent(path))
        req.httpMethod = method
        req.timeoutInterval = 120
        req.setValue("Bearer \(sonioxKey)", forHTTPHeaderField: "Authorization")
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        return try await send(req)
    }

    private func send(_ req: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw failure("Soniox HTTP \(status): \(String(data: data, encoding: .utf8)?.prefix(300) ?? "")")
        }
        return data
    }

    private func object(from data: Data) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw failure("JSON オブジェクトではない応答")
        }
        return json
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "Retranscriber", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: - Backchannels

    /// 相づちの語（句読点・空白を除き小文字にした形）。これらの組み合わせだけでできた行を相づちとみなす。
    private static let backchannels = [
        "うん", "はい", "ええ", "そう", "そうそう", "そうですね", "なるほど", "うーん", "へー", "ふーん", "あー", "おー",
        "mmhm", "mmhmm", "mhm", "uhhuh", "yeah", "yes", "ok", "okay", "right", "sure",
    ]

    static func isBackchannel(_ text: String) -> Bool {
        let normalized = String(text.lowercased().unicodeScalars.filter {
            !CharacterSet.punctuationCharacters.union(.whitespaces).union(.symbols).contains($0)
        })
        guard !normalized.isEmpty else { return false }
        // 先頭から相づちの語で区切っていき、最後まで区切れたら相づち（「はいはいはいうん」も可）。
        let chars = Array(normalized)
        var reachable = Array(repeating: false, count: chars.count + 1)
        reachable[0] = true
        for i in 0..<chars.count where reachable[i] {
            for base in backchannels {
                let end = i + base.count
                if end <= chars.count, String(chars[i..<end]) == base { reachable[end] = true }
            }
        }
        return reachable[chars.count]
    }

    /// 同じ人の相づちだけの行が続いたら 1 行にまとめ、回数を添える（「Mm-hm.（×7）」）。
    /// 話を聞きながらの相づちが 1 つずつ行になって、記録が読みにくくなるため。
    static func collapsingBackchannels(_ lines: [SubtitleLine]) -> [SubtitleLine] {
        var result: [SubtitleLine] = []
        var run: [SubtitleLine] = []

        func flush() {
            guard let first = run.first else { return }
            if run.count == 1 {
                result.append(first)
            } else {
                var merged = first
                var texts: [String] = []
                for line in run where !texts.contains(line.original) { texts.append(line.original) }
                merged.original = texts.joined(separator: " ") + "（×\(run.count)）"
                merged.translation = ""
                result.append(merged)
            }
            run = []
        }

        for line in lines {
            if isBackchannel(line.original),
               run.isEmpty || (run[0].speaker == line.speaker && run[0].voice == line.voice) {
                run.append(line)
            } else {
                flush()
                if isBackchannel(line.original) { run.append(line) } else { result.append(line) }
            }
        }
        flush()
        return result
    }

    // MARK: - Tokens → lines

    /// 話者が変わるか、原文トークンの間が `pauseMs` 以上空いたら行を分ける。
    /// 訳文トークンには時刻がなく、対応する原文のすぐ後に並んでくるので、直前の行の訳として足す。
    private static let pauseMs = 1500

    private static func lines(from tokens: [Token], speaker: Speaker, start: Date) -> [SubtitleLine] {
        var lines: [SubtitleLine] = []
        var lastStartMs: Int?
        var lastVoice: String?
        for token in tokens where token.text != "<end>" && token.text != "<fin>" {
            if token.translationStatus == "translation" {
                guard !lines.isEmpty else { continue }
                lines[lines.count - 1].translation += token.text
                continue
            }
            let ms = token.startMs ?? lastStartMs ?? 0
            let newLine = lines.isEmpty
                || token.speaker != lastVoice
                || ms - (lastStartMs ?? ms) >= pauseMs
            if newLine {
                var line = SubtitleLine(original: "", translation: "", speaker: speaker,
                                        startedAt: start.addingTimeInterval(Double(ms) / 1000))
                line.voice = speaker.isGroup ? token.speaker : nil
                lines.append(line)
            }
            lines[lines.count - 1].original += token.text
            lastStartMs = ms
            lastVoice = token.speaker
        }
        return lines.map { line in
            var line = line
            line.original = line.original.trimmingCharacters(in: .whitespaces)
            line.translation = line.translation.trimmingCharacters(in: .whitespaces)
            return line
        }.filter { !$0.original.isEmpty }
    }
}
