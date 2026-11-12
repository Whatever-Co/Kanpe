import AVFoundation

/// A source of raw PCM audio buffers. Lets streams treat mic and system
/// capture uniformly so either can be started/stopped independently.
protocol AudioCaptureSource: AnyObject {
    /// Called (on any thread) when capture dies mid-meeting and a restart failed.
    var onFailure: ((String) -> Void)? { get set }
    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws
    func stop()
}
