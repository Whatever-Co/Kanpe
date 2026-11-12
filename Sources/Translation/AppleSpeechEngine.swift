import AVFoundation
import Foundation
import Speech
import os

/// macOS 26 の SpeechAnalyzer + SpeechTranscriber によるオンデバイス文字起こし。翻訳と話者分離はしない。
/// 途中の結果（volatile）は暫定トークン、確定した結果は確定トークン＋`<end>` にして渡すので、
/// 行の組み立ては Soniox と同じ `UtteranceAssembler` がそのまま受け持つ。
final class AppleSpeechEngine: TranscriptionEngine {
    let usesEndpointDetection = true
    private let localeID: String
    private let converter = PCMConverter()

    /// 音声スレッドと main から触る。
    private struct Input {
        var continuation: AsyncStream<AnalyzerInput>.Continuation?
        var format: AVAudioFormat?
    }
    private let input = OSAllocatedUnfairLock(uncheckedState: Input())
    private let paused = OSAllocatedUnfairLock(initialState: false)
    private var analyzer: SpeechAnalyzer?
    private var results: Task<Void, Never>?

    struct EngineError: LocalizedError {
        let errorDescription: String?
    }

    /// `language` は Soniox と同じ言語コード（"en"、"ja" など）。
    init(language: String) {
        localeID = Self.regions[language].map { "\(language)-\($0)" } ?? language
    }

    /// 言語コードだけでは地域が決まらないので、よく使う地域を補う。
    private static let regions = [
        "en": "US", "ja": "JP", "zh": "CN", "ko": "KR", "es": "ES", "fr": "FR", "de": "DE",
        "pt": "BR", "it": "IT", "vi": "VN", "th": "TH", "id": "ID",
    ]

    func start(onTokens: @escaping ([SonioxResponse.Token]) -> Void,
               onError: @escaping (String) -> Void) async throws {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeID)) else {
            throw EngineError(errorDescription: "この Mac は \(localeID) のオンデバイス文字起こしに対応していない")
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [.volatileResults], attributeOptions: [])
        // 言語モデルが入っていなければここでダウンロードする（初回だけ。開始が遅れる）。
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw EngineError(errorDescription: "オンデバイス文字起こしの音声形式を決められない")
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        try await analyzer.start(inputSequence: stream)
        self.analyzer = analyzer
        input.withLockUnchecked { $0 = Input(continuation: continuation, format: format) }
        results = Task {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    if result.isFinal {
                        guard !text.isEmpty else { continue }
                        onTokens([.init(text: text, isFinal: true), .init(text: "<end>", isFinal: true)])
                    } else {
                        onTokens([.init(text: text, isFinal: false)])
                    }
                }
            } catch is CancellationError {
            } catch {
                onError("文字起こし（Mac 内）: \(error.localizedDescription)")
            }
        }
    }

    var isPaused: Bool { paused.withLock { $0 } }

    /// 止める直前の言葉が途中経過のまま残らないよう、止めるときに確定させる。
    func setPaused(_ value: Bool) {
        paused.withLock { $0 = value }
        guard value, let analyzer else { return }
        Task { try? await analyzer.finalize(through: nil) }
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard !paused.withLock({ $0 }) else { return }
        let (continuation, format) = input.withLockUnchecked { ($0.continuation, $0.format) }
        guard let continuation, let format, let converted = converter.buffer(from: buffer, to: format) else { return }
        continuation.yield(AnalyzerInput(buffer: converted))
    }

    func stop() {
        let continuation = input.withLockUnchecked { s in
            defer { s = Input() }
            return s.continuation
        }
        continuation?.finish()
        let analyzer = self.analyzer
        let results = self.results
        self.analyzer = nil
        self.results = nil
        Task {
            try? await analyzer?.finalizeAndFinishThroughEndOfInput()
            results?.cancel()
        }
    }
}
