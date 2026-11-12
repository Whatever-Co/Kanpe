import AudioToolbox
import AVFoundation
import os

private let log = Logger(subsystem: "co.whatever.Kanpe", category: "MicCaptureSource")

/// Captures microphone input via AVAudioEngine and forwards raw PCM buffers.
/// `preferredDeviceID` selects a specific input device (nil = system default).
final class MicCaptureSource: AudioCaptureSource {
    var preferredDeviceID: AudioDeviceID?
    var onFailure: ((String) -> Void)?

    private var engine: AVAudioEngine?
    private var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private var configChangeObserver: NSObjectProtocol?
    /// engine を触る処理はすべてここで順に行う（start は main 以外から呼ばれ、stop は main から呼ばれる）。
    private let queue = DispatchQueue(label: "co.whatever.Kanpe.mic", qos: .userInitiated)

    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        try queue.sync { try startOnQueue(onBuffer: onBuffer) }
    }

    private func startOnQueue(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        self.onBuffer = onBuffer
        // observer は engine.start の前に登録：起動直後のサンプルレート確定など、
        // 早期に発火しうる configuration-change 通知を取りこぼさないため。
        // engine 起動が失敗したら observer も破棄する。
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil, // engine は作り直すたびに変わるので、相手を絞らない
            queue: nil
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
        do {
            try startEngine()
        } catch {
            if let observer = configChangeObserver {
                NotificationCenter.default.removeObserver(observer)
                configChangeObserver = nil
            }
            self.onBuffer = nil
            throw error
        }
    }

    func stop() {
        queue.async { [self] in
            if let observer = configChangeObserver {
                NotificationCenter.default.removeObserver(observer)
                configChangeObserver = nil
            }
            teardownEngine()
            onBuffer = nil
        }
    }

    private func startEngine() throws {
        let engine = AVAudioEngine()
        self.engine = engine

        let input = engine.inputNode
        if let preferredDeviceID {
            try setInputDevice(preferredDeviceID, on: input)
        }

        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.onBuffer?(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    private func teardownEngine() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    /// AVAudioEngine sends this when audio config changes mid-session (device
    /// switch, sample-rate change, sleep/wake). Without recovery the tap goes
    /// silent and never resumes; restart on `queue`.
    private func handleConfigurationChange() {
        queue.async { [weak self] in
            guard let self, self.onBuffer != nil else { return }
            self.teardownEngine()
            do {
                try self.startEngine()
                log.info("restarted after configuration change")
            } catch {
                log.error("restart failed: \(error.localizedDescription, privacy: .public)")
                self.onFailure?("マイクを再開できない: \(error.localizedDescription)")
            }
        }
    }

    private func setInputDevice(_ deviceID: AudioDeviceID, on input: AVAudioInputNode) throws {
        guard let unit = input.audioUnit else { return }
        var device = deviceID
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &device,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw NSError(
                domain: "MicCaptureSource",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "入力デバイス設定失敗 (\(status))"]
            )
        }
    }
}
