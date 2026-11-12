import AVFoundation
import Foundation

/// 音源 1 本ぶんの文字起こし。結果は Soniox 形のトークンで返し、行への組み立ては `UtteranceAssembler` が受け持つ。
protocol TranscriptionEngine: AnyObject {
    /// `<end>` で行を区切るか。区切らないエンジンでは、間が空いたら行を確定する（`MeetingSession.idleCommit`）。
    var usesEndpointDetection: Bool { get }
    var isPaused: Bool { get }
    func start(onTokens: @escaping ([SonioxResponse.Token]) -> Void,
               onError: @escaping (String) -> Void) async throws
    /// リアルタイム音声スレッドから呼ばれる。一時停止中は捨てる。
    func feed(_ buffer: AVAudioPCMBuffer)
    func setPaused(_ value: Bool)
    func stop()
}

/// 会議中の文字起こしをどこでするか（設定ウィンドウで選ぶ）。
enum TranscriptionBackend: String, CaseIterable {
    /// Soniox（クラウド）。翻訳と話者分離あり。API キーが要る。
    case soniox
    /// macOS 26 の SpeechAnalyzer。キー不要・音声が Mac の外に出ない。翻訳と話者分離はしない。
    case onDevice

    var label: String {
        switch self {
        case .soniox: "Soniox"
        case .onDevice: "Mac 内（オンデバイス）"
        }
    }

    static var stored: Self {
        UserDefaults.standard.string(forKey: "transcriptionBackend").flatMap(Self.init) ?? .soniox
    }
}
