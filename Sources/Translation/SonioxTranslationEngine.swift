import AVFoundation
import Foundation
import os

/// Soniox リアルタイム STT + 翻訳。WebSocket に PCM(16k/mono/Int16) を流し、
/// 受け取ったトークンを生のまま onTokens に渡す（行への組み立ては呼び出し側）。
/// 切断時は指数バックオフで再接続。
final class SonioxTranslationEngine: TranscriptionEngine {
    private let endpoint = URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!
    private let model = "stt-rt-v5"
    private let apiKey: String
    private let languageHints: [String]
    private let targetLanguage: String
    private let diarization: Bool
    private let translate: Bool
    /// Soniox の `context` オブジェクト（用語・訳語・話題）。nil なら送らない。
    private let context: [String: Any]?
    let usesEndpointDetection: Bool

    private let converter = PCMConverter(targetSampleRate: 16000)

    /// 接続の状態。main・URLSession のキュー・再接続のタイマー・音声スレッドから触るので、まとめてロックで守る。
    private struct State {
        var session: URLSession?
        var task: URLSessionWebSocketTask?
        /// 接続ごとの番号。古い接続から遅れて届く callback を見分けて無視する。
        var generation = 0
        var stopped = true
        /// サーバが致命的エラー（残高切れ・認証失敗・不正 config）を返したか。
        /// 再接続しても解決しないので、立ったら再接続しない。
        var fatal = false
        var reconnectDelay: TimeInterval = 0.5
        var onTokens: (([SonioxResponse.Token]) -> Void)?
        var onError: ((String) -> Void)?
    }
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    /// 一時停止中（Meet でミュート中など）。音声を送らず、接続が切れないよう keepalive を送る。
    /// 音声スレッドからも読むのでロックで守る。
    private let paused = OSAllocatedUnfairLock(initialState: false)
    private var keepalive: DispatchSourceTimer?
    private let maxReconnectDelay: TimeInterval = 8

    init(apiKey: String, languageHints: [String], targetLanguage: String,
         diarization: Bool = false, translate: Bool = true, context: [String: Any]? = nil,
         endpointDetection: Bool = true) {
        self.apiKey = apiKey
        self.languageHints = languageHints
        self.targetLanguage = targetLanguage
        self.diarization = diarization
        self.translate = translate
        self.context = context
        self.usesEndpointDetection = endpointDetection
    }

    func start(
        onTokens: @escaping ([SonioxResponse.Token]) -> Void,
        onError: @escaping (String) -> Void
    ) throws {
        guard !apiKey.isEmpty else {
            throw NSError(domain: "Soniox", code: 401,
                          userInfo: [NSLocalizedDescriptionKey: "Soniox API Key 未設定"])
        }
        state.withLockUnchecked { s in
            s.onTokens = onTokens
            s.onError = onError
            s.stopped = false
            s.fatal = false
            s.reconnectDelay = 0.5
        }
        connect()
    }

    private func connect() {
        // 前の接続は閉じてから張り直す（残すと Soniox は接続時間を課金し続ける）。
        // 閉じる処理はロックの外で（feed が音声スレッドから同じロックを取るため）。
        let reserved: (Int, URLSessionWebSocketTask?, URLSession?)? = state.withLockUnchecked { s in
            guard !s.stopped, !s.fatal else { return nil }
            let old = (s.task, s.session)
            s.task = nil
            s.session = nil
            s.generation += 1
            return (s.generation, old.0, old.1)
        }
        guard let (generation, oldTask, oldSession) = reserved else { return }
        oldTask?.cancel(with: .goingAway, reason: nil)
        oldSession?.invalidateAndCancel()
        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: endpoint)
        task.resume()

        var config: [String: Any] = [
            "api_key": apiKey,
            "model": model,
            "audio_format": "pcm_s16le", // pcm_ 接頭辞が必須（s16le 単体は不可）
            "sample_rate": 16000,
            "num_channels": 1,
            // 会議では日英が混ざる（相手も自分も）。主の言語を先頭に、両方をヒントに入れる。
            "language_hints": languageHints,
            "enable_endpoint_detection": usesEndpointDetection, // true なら <end> で発話を区切る
            "enable_speaker_diarization": diarization,
        ]
        if translate {
            config["translation"] = ["type": "one_way", "target_language": targetLanguage]
        }
        if let context { config["context"] = context }
        if let data = try? JSONSerialization.data(withJSONObject: config),
           let json = String(data: data, encoding: .utf8) {
            task.send(.string(json)) { [weak self] error in
                if let error {
                    NSLog("[Soniox] config send error: \(error)")
                    self?.connectionFailed(generation)
                }
            }
        }
        // config を送ってから音声スレッドに見せる（音声が先に届くと Soniox はエラーを返す）。
        let published = state.withLockUnchecked { s in
            guard s.generation == generation, !s.stopped, !s.fatal else { return false }
            s.session = session
            s.task = task
            return true
        }
        guard published else {
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
            return
        }
        receive(on: task, generation: generation)
    }

    private func isCurrent(_ generation: Int) -> Bool {
        state.withLockUnchecked { !$0.stopped && $0.generation == generation }
    }

    private func receive(on task: URLSessionWebSocketTask, generation: Int) {
        task.receive { [weak self] result in
            guard let self, self.isCurrent(generation) else { return }
            switch result {
            case .failure(let error):
                NSLog("[Soniox] receive error: \(error)")
                self.connectionFailed(generation)
            case .success(let message):
                if case let .string(text) = message, let data = text.data(using: .utf8) {
                    self.handle(data)
                }
                self.receive(on: task, generation: generation)
            }
        }
    }

    private func handle(_ data: Data) {
        guard let response = try? JSONDecoder().decode(SonioxResponse.self, from: data) else { return }
        if response.isError {
            let message = response.errorMessage ?? "Soniox エラー (code \(response.errorCode ?? -1))"
            NSLog("[Soniox] server error: \(message)")
            let onError = state.withLockUnchecked { s in
                s.fatal = true
                s.task?.cancel(with: .goingAway, reason: nil)
                return s.onError
            }
            onError?("Soniox: \(message)")
            return
        }
        let onTokens = state.withLockUnchecked { s in
            s.reconnectDelay = 0.5 // 受信できた = 健全。バックオフをリセット
            return s.onTokens
        }
        onTokens?(response.tokens)
    }

    /// 1 つの接続の失敗は送信側と受信側の両方から届くので、最初の 1 回だけ再接続を予約する。
    private func connectionFailed(_ generation: Int) {
        let failed: (TimeInterval, URLSessionWebSocketTask?, URLSession?)? = state.withLockUnchecked { s in
            guard s.generation == generation, !s.stopped, !s.fatal else { return nil }
            s.generation += 1
            // 張り直すまでの間、死んだ接続に音声や keepalive を送らない。
            let dead = (s.task, s.session)
            s.task = nil
            s.session = nil
            let delay = s.reconnectDelay
            s.reconnectDelay = min(s.reconnectDelay * 2, maxReconnectDelay)
            return (delay, dead.0, dead.1)
        }
        guard let (delay, deadTask, deadSession) = failed else { return }
        deadTask?.cancel(with: .goingAway, reason: nil)
        deadSession?.invalidateAndCancel()
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            NSLog("[Soniox] reconnecting after \(delay)s")
            self?.connect()
        }
    }

    private var currentTask: URLSessionWebSocketTask? {
        state.withLockUnchecked { $0.stopped || $0.fatal ? nil : $0.task }
    }

    var isPaused: Bool { paused.withLock { $0 } }

    /// 一時停止の切り替え。Soniox は 20 秒音声も keepalive も来ないと切断するので、停止中は 8 秒ごとに送る。
    /// 料金は接続している時間ずっとかかる（停止中も）。
    func setPaused(_ value: Bool) {
        paused.withLock { $0 = value }
        keepalive?.cancel()
        keepalive = nil
        guard value else { return }
        // 止める直前の言葉が途中経過のまま残らないよう、確定させる（Soniox のおすすめどおり、
        // 0.2 秒の無音を送ってから finalize）。確定したトークンと `<fin>` が返ってきて行になる。
        // 2026-10-21：ミュート直前の一言が確定しないまま残った。
        let silence = Data(count: 16000 * 2 / 5) // 16 kHz・16 bit・0.2 秒
        let task = currentTask
        task?.send(.data(silence)) { _ in }
        task?.send(.string("{\"type\": \"finalize\"}")) { error in
            if let error { NSLog("[Soniox] finalize error: \(error)") }
        }
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 8, repeating: 8)
        timer.setEventHandler { [weak self] in
            self?.currentTask?.send(.string("{\"type\": \"keepalive\"}")) { error in
                if let error { NSLog("[Soniox] keepalive error: \(error)") }
            }
        }
        timer.resume()
        keepalive = timer
    }

    /// リアルタイム音声スレッドから呼ばれる。
    func feed(_ buffer: AVAudioPCMBuffer) {
        guard !paused.withLock({ $0 }) else { return }
        guard let task = currentTask, let data = converter.int16Data(from: buffer) else { return }
        task.send(.data(data)) { error in
            if let error { NSLog("[Soniox] send error: \(error)") }
        }
    }

    func stop() {
        keepalive?.cancel()
        keepalive = nil
        state.withLockUnchecked { s in
            s.stopped = true
            s.generation += 1
            s.task?.cancel(with: .goingAway, reason: nil)
            s.task = nil
            s.session?.invalidateAndCancel()
            s.session = nil
            s.onTokens = nil
            s.onError = nil
        }
    }
}
