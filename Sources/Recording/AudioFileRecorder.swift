import AVFoundation
import os

private let log = Logger(subsystem: "co.whatever.Kanpe", category: "AudioFileRecorder")

/// 音源のバッファをそのままの形式で AAC (.m4a) に書き出す。
/// 書き込みは専用キューで行う（呼び出し元はリアルタイム音声スレッド）。
/// 途中で入力形式が変わったら（デバイス切替など）、`name-2.m4a` のように新しいファイルに分ける。
final class AudioFileRecorder {
    private let folder: URL
    private let name: String
    private let queue: DispatchQueue
    private var file: AVAudioFile?
    private var fileFormat: AVAudioFormat?
    private var part = 0
    /// finish 後に届いたバッファで新しいファイルを開かないための印（音源の停止は非同期なので遅れて届く）。
    private var closed = false
    /// 開けない・書けないときに 1 度だけ呼ぶ（書き込みキューから）。録音が失われていることを画面に出すため。
    var onError: ((String) -> Void)?
    private var reported = false
    private var lastOpenFailure = Date.distantPast

    init(folder: URL, name: String) {
        self.folder = folder
        self.name = name
        self.queue = DispatchQueue(label: "co.whatever.Kanpe.recorder.\(name)")
    }

    /// バッファはコピーしてから書き込みキューに渡す（呼び出し元が再利用しうるため）。
    /// `silent`：中身を無音にして書く（ミュート中）。飛ばすとファイルの時間が縮み、
    /// 再文字起こしの時刻がずれるので、長さだけは保つ。
    func append(_ buffer: AVAudioPCMBuffer, silent: Bool = false) {
        guard let copy = Self.copy(buffer) else { return }
        if silent {
            for audio in UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList) {
                if let data = audio.mData { memset(data, 0, Int(audio.mDataByteSize)) }
            }
        }
        queue.async { [self] in write(copy) }
    }

    /// 書き込み待ちを流しきってファイルを閉じる。閉じ終わるまで待つ：m4a は閉じるときに目次（moov）を
    /// 書くので、閉じる前にプロセスが終わると再生できないファイルが残る（2026-10-21 に実際に起きた）。
    func finish() {
        queue.sync {
            closed = true
            file = nil
            fileFormat = nil
        }
    }

    private func write(_ buffer: AVAudioPCMBuffer) {
        guard !closed else { return }
        // 開けなかったときは 5 秒おきに開き直す（毎バッファだとログとファイル名が埋まる）。
        if fileFormat != buffer.format || (file == nil && Date().timeIntervalSince(lastOpenFailure) >= 5) {
            openFile(for: buffer.format)
        }
        guard let file else { return }
        do {
            try file.write(from: buffer)
        } catch {
            report("書き込み失敗: \(error.localizedDescription)")
        }
    }

    private func openFile(for format: AVAudioFormat) {
        let next = part + 1
        let filename = next == 1 ? "\(name).m4a" : "\(name)-\(next).m4a"
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
        ]
        do {
            file = try AVAudioFile(
                forWriting: folder.appendingPathComponent(filename),
                settings: settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
            fileFormat = format
            part = next
        } catch {
            report("\(filename) を開けない: \(error.localizedDescription)")
            file = nil
            fileFormat = format
            lastOpenFailure = Date()
        }
    }

    private func report(_ message: String) {
        log.error("[\(self.name, privacy: .public)] \(message, privacy: .public)")
        guard !reported else { return }
        reported = true
        onError?("録音 \(name): \(message)")
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }
        copy.frameLength = buffer.frameLength
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in 0..<min(src.count, dst.count) {
            if let s = src[index].mData, let d = dst[index].mData {
                memcpy(d, s, Int(src[index].mDataByteSize))
            }
            dst[index].mDataByteSize = src[index].mDataByteSize
        }
        return copy
    }
}
