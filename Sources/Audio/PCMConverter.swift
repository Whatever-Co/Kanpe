import AVFoundation

/// 任意フォーマットの PCM を Soniox 向けの target(既定 16kHz)/mono Int16(LE) に変換する。
/// AVAudioConverter を内部で使い回す。
final class PCMConverter {
    private let targetSampleRate: Double
    private var int16Converter: AVAudioConverter?
    private var int16InputFormat: AVAudioFormat?

    private lazy var int16Format = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: targetSampleRate, channels: 1, interleaved: true
    )!

    private var bufferConverter: AVAudioConverter?

    init(targetSampleRate: Double = 16000) { self.targetSampleRate = targetSampleRate }

    /// 任意の形式への変換（オンデバイス文字起こしが求める形式へ）。失敗時 nil。
    func buffer(from buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if bufferConverter?.inputFormat != buffer.format || bufferConverter?.outputFormat != format {
            bufferConverter = AVAudioConverter(from: buffer.format, to: format)
        }
        return convert(buffer, with: bufferConverter, to: format)
    }

    /// Soniox 送信用: 16kHz / mono / Int16 little-endian の Data。失敗時 nil。
    func int16Data(from buffer: AVAudioPCMBuffer) -> Data? {
        if int16Converter == nil || int16InputFormat != buffer.format {
            int16Converter = AVAudioConverter(from: buffer.format, to: int16Format)
            int16InputFormat = buffer.format
        }
        guard let out = convert(buffer, with: int16Converter, to: int16Format),
              let ch = out.int16ChannelData else { return nil }
        return Data(bytes: ch[0], count: Int(out.frameLength) * MemoryLayout<Int16>.size)
    }

    private func convert(
        _ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter?, to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        guard let converter else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if let error {
            NSLog("[PCMConverter] convert error: \(error)")
            return nil
        }
        return output
    }
}
