import AVFoundation
import CoreAudio
import os
import os.lock

private let log = Logger(subsystem: "co.whatever.Kanpe", category: "SystemAudioCaptureSource")

enum SystemAudioCaptureError: LocalizedError {
    case tapCreationFailed(OSStatus)
    case tapUIDUnavailable(OSStatus)
    case tapFormatUnavailable(OSStatus)
    case aggregateCreationFailed(OSStatus)
    case ioProcCreationFailed(OSStatus)
    case deviceStartFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .tapCreationFailed(let s): return "process tap 作成失敗 (\(s))"
        case .tapUIDUnavailable(let s): return "tap UID 取得失敗 (\(s))"
        case .tapFormatUnavailable(let s): return "tap フォーマット取得失敗 (\(s))"
        case .aggregateCreationFailed(let s): return "aggregate device 作成失敗 (\(s))"
        case .ioProcCreationFailed(let s): return "IO proc 作成失敗 (\(s))"
        case .deviceStartFailed(let s): return "デバイス開始失敗 (\(s))"
        }
    }
}

/// Captures all system audio output (e.g. remote meeting participants) using a
/// Core Audio process tap fed into a private aggregate device.
///
/// Tap/aggregate setup and teardown can block for over a second, so all of it runs on
/// `queue`. `stop()` and the watchdog's rebuilds don't wait; `start` does (it must throw).
final class SystemAudioCaptureSource: AudioCaptureSource {
    private let queue = DispatchQueue(label: "co.whatever.Kanpe.systemAudio", qos: .userInitiated)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var format: AVAudioFormat?
    private var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onFailure: ((String) -> Void)?
    /// 立て直しの失敗を 1 回だけ知らせるための印（3 秒ごとに再試行するので）。
    private var reportedFailure = false
    private var watchdog: DispatchSourceTimer?
    /// IOProc が音声を運んだことを watchdog に伝えるフラグ。IOProc（RT スレッド）と
    /// `queue` 上の watchdog の両方から触るので OSAllocatedUnfairLock で保護する。
    /// os_unfair_lock は audio-thread から呼び出し可能。
    private let sawRecentBuffer = OSAllocatedUnfairLock<Bool>(initialState: false)
    /// (objectID, address, block) triples registered for diagnostic logging — used to
    /// see which property change correlates with IOProc going silent.
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        log.info("start")
        try queue.sync {
            self.onBuffer = onBuffer
            do {
                try startCapture()
            } catch {
                // 途中まで作った tap と aggregate device を残さない。
                stopCapture()
                self.onBuffer = nil
                throw error
            }
            installPropertyListeners()
            startWatchdog()
        }
    }

    /// Returns immediately; teardown finishes on `queue` (which keeps self alive until then).
    func stop() {
        log.info("stop")
        queue.async { [self] in
            stopWatchdog()
            removePropertyListeners()
            stopCapture()
            onBuffer = nil
        }
    }

    private func startCapture() throws {
        // 1. Global tap of all output, leaving the audio audible (unmuted).
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(tapDescription, &tap)
        guard tapStatus == noErr, tap != kAudioObjectUnknown else {
            throw SystemAudioCaptureError.tapCreationFailed(tapStatus)
        }
        tapID = tap

        // 2. Read the tap's UID and stream format.
        let tapUID = try readTapUID(tap)
        let asbd = try readTapFormat(tap)
        var mutableASBD = asbd
        guard let avFormat = AVAudioFormat(streamDescription: &mutableASBD) else {
            throw SystemAudioCaptureError.tapFormatUnavailable(noErr)
        }
        format = avFormat

        // 3. Private aggregate device that contains the tap.
        let aggregateUID = UUID().uuidString
        let aggregateDict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Kanpe System Tap",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(aggregateDict as CFDictionary, &aggregate)
        guard aggregateStatus == noErr, aggregate != kAudioObjectUnknown else {
            throw SystemAudioCaptureError.aggregateCreationFailed(aggregateStatus)
        }
        aggregateID = aggregate

        // 4. IO proc pulls captured audio off the aggregate device.
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregate, nil) {
            [weak self] _, inputData, _, _, _ in
            self?.handle(inputData: inputData)
        }
        guard ioStatus == noErr, ioProcID != nil else {
            throw SystemAudioCaptureError.ioProcCreationFailed(ioStatus)
        }

        let startStatus = AudioDeviceStart(aggregateID, ioProcID)
        guard startStatus == noErr else {
            throw SystemAudioCaptureError.deviceStartFailed(startStatus)
        }
    }

    private func stopCapture() {
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        format = nil
    }

    // MARK: - Watchdog

    /// macOS sometimes invalidates the aggregate device or the process tap when
    /// the default output device changes or audio routing reconfigures, and the
    /// IOProc silently stops firing with no notification. Poll every 3 s and
    /// rebuild the capture chain if no buffer was seen in the prior window.
    private func startWatchdog() {
        sawRecentBuffer.withLock { $0 = true }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 3, repeating: 3)
        timer.setEventHandler { [weak self] in self?.watchdogTick() }
        timer.resume()
        watchdog = timer
    }

    private func stopWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }

    private func watchdogTick() {
        guard onBuffer != nil else { return }
        let alive = sawRecentBuffer.withLock { (state: inout Bool) -> Bool in
            let was = state
            state = false
            return was
        }
        guard !alive else { return }
        log.warning("no audio for ≥3s, restarting. defaultOut=\(self.currentDefaultOutputDevice(), privacy: .public) aggregate.isAlive=\(self.aggregateIsAlive(), privacy: .public) aggregate.isRunning=\(self.aggregateIsRunning(), privacy: .public)")
        removePropertyListeners()
        stopCapture()
        do {
            try startCapture()
            installPropertyListeners()
            sawRecentBuffer.withLock { $0 = true }
            reportedFailure = false
            log.info("restarted")
        } catch {
            log.error("restart failed: \(error.localizedDescription, privacy: .public)")
            if !reportedFailure {
                reportedFailure = true
                onFailure?("システム音声を立て直せない: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Property listeners (diagnostic)

    /// Watches the audio properties most likely to correlate with IOProc
    /// going silent: system default output (route change), the aggregate's
    /// liveness/running/sample-rate, and the aggregate's sub-device list.
    /// Every fire is logged with a timestamp so we can correlate with the
    /// watchdog's "no audio" message.
    private func installPropertyListeners() {
        addListener(
            object: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultOutputDevice,
            label: "system.defaultOutputDevice"
        )
        addListener(
            object: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDevices,
            label: "system.devices"
        )
        guard aggregateID != kAudioObjectUnknown else { return }
        addListener(object: aggregateID, selector: kAudioDevicePropertyDeviceIsAlive,        label: "aggregate.isAlive")
        addListener(object: aggregateID, selector: kAudioDevicePropertyDeviceIsRunning,      label: "aggregate.isRunning")
        addListener(object: aggregateID, selector: kAudioDevicePropertyNominalSampleRate,    label: "aggregate.sampleRate")
        addListener(object: aggregateID, selector: kAudioAggregateDevicePropertyFullSubDeviceList, label: "aggregate.subDeviceList")
        addListener(object: aggregateID, selector: kAudioAggregateDevicePropertyActiveSubDeviceList, label: "aggregate.activeSubDeviceList")
        if tapID != kAudioObjectUnknown {
            addListener(object: tapID, selector: kAudioTapPropertyFormat, label: "tap.format")
        }
    }

    private func removePropertyListeners() {
        for (object, address, block) in listeners {
            var addr = address
            AudioObjectRemovePropertyListenerBlock(object, &addr, queue, block)
        }
        listeners.removeAll()
    }

    private func addListener(object: AudioObjectID, selector: AudioObjectPropertySelector, label: String) {
        let address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            log.notice("property changed: \(label, privacy: .public)")
        }
        var addr = address
        let status = AudioObjectAddPropertyListenerBlock(object, &addr, queue, block)
        guard status == noErr else {
            log.error("failed to listen on \(label, privacy: .public): \(status)")
            return
        }
        listeners.append((object, address, block))
    }

    private func currentDefaultOutputDevice() -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }

    private func aggregateIsAlive() -> UInt32 { readUInt32(object: aggregateID, selector: kAudioDevicePropertyDeviceIsAlive) }
    private func aggregateIsRunning() -> UInt32 { readUInt32(object: aggregateID, selector: kAudioDevicePropertyDeviceIsRunning) }

    private func readUInt32(object: AudioObjectID, selector: AudioObjectPropertySelector) -> UInt32 {
        guard object != kAudioObjectUnknown else { return UInt32.max }
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        return value
    }

    // MARK: - IO

    private func handle(inputData: UnsafePointer<AudioBufferList>) {
        sawRecentBuffer.withLock { $0 = true }
        guard let format, let onBuffer else { return }
        let sourceList = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        )
        let bytesPerFrame = format.streamDescription.pointee.mBytesPerFrame
        guard bytesPerFrame > 0, sourceList.count > 0 else { return }
        let frames = sourceList[0].mDataByteSize / bytesPerFrame
        guard frames > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { return }
        copy.frameLength = AVAudioFrameCount(frames)

        let destinationList = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in 0..<min(sourceList.count, destinationList.count) {
            if let src = sourceList[index].mData, let dst = destinationList[index].mData {
                memcpy(dst, src, Int(sourceList[index].mDataByteSize))
            }
            destinationList[index].mDataByteSize = sourceList[index].mDataByteSize
            destinationList[index].mNumberChannels = sourceList[index].mNumberChannels
        }
        onBuffer(copy)
    }

    // MARK: - Property reads

    private func readTapUID(_ tap: AudioObjectID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString>.size)
        var uid: CFString = "" as CFString
        let status = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(tap, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { throw SystemAudioCaptureError.tapUIDUnavailable(status) }
        return uid as String
    }

    private func readTapFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd)
        guard status == noErr else { throw SystemAudioCaptureError.tapFormatUnavailable(status) }
        return asbd
    }
}
