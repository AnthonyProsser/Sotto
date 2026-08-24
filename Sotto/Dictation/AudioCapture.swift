//
//  AudioCapture.swift
//  Sotto
//
//  Slice 3. Microphone capture and the level meter — sotto-spec.md §4.5, §4.8.
//

@preconcurrency import AVFoundation
import CoreAudio
import Speech
import os

/// `AVAudioEngine`, the input device, and the two things that come off the
/// microphone: `AnalyzerInput` buffers for `Transcription`, and an RMS level for
/// the HUD.
///
/// **The level is not ASR** (§4.5). It is the mean square of the capture buffer,
/// computed before any conversion, and it is what makes latched mode safe to
/// leave running — a latched session with no visual feedback is a footgun.
///
/// **The device is pinned for the length of a recording** (§4.8). Resolved once
/// at `start()` and written to the input unit explicitly, so the system default
/// moving underneath — a headset unplugged in another app — cannot take the
/// engine with it. A selection made while recording is held in `pending` and
/// applied at the next `start()`.
///
/// Not main-actor: `start()`/`stop()` are called from the main actor, and the
/// tap block runs on a real-time audio thread. Nothing here touches UI.
nonisolated final class AudioCapture: @unchecked Sendable {
    static let shared = AudioCapture()

    private let log = Logger(subsystem: "com.anthonyprosser.Sotto", category: "audio")
    private let engine = AVAudioEngine()

    /// Called on the audio thread, once per buffer, with 0…1.
    var onLevel: (@Sendable (Double) -> Void)?

    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: AVAudioConverter?
    private var isRunning = false

    /// The device and device format the installed tap was built against.
    /// **Install once per device, not once ever** — pinning a different device
    /// changes the input node's format, and a tap left on the old one fails at
    /// `engine.start()` rather than at the mismatch.
    private var tapDevice: AudioDeviceID?
    private var tapFormat: AVAudioFormat?

    /// Copies of the converted buffers, kept until `takeRecording()` or
    /// `discardRecording()`. The tap's own buffer is reused by the engine, so
    /// retaining it without a copy would alias later frames.
    private var retained: [AVAudioPCMBuffer] = []
    private var retainedFormat: AVAudioFormat?

    /// The meter's follower. Raw RMS at ~12 Hz makes the bars snap between
    /// syllables; an envelope that rises almost immediately and falls over a few
    /// buffers reads as a voice rather than as a strobe. Fast attack because a
    /// waveform that lags the first word is the one thing the HUD must not do.
    private var smoothed: Double = 0

    /// **The engine ignores this, and the number is kept only because something
    /// has to be passed.** Measured 2026-08-24: 4096, 1024, 512 and 256 all
    /// deliver 4800-frame buffers — 100 ms at 48 kHz — and the device's own IO
    /// buffer is 512 frames, so the 4800 is `AVAudioEngine`'s tap buffering rather
    /// than the hardware's. The 100 ms it costs between the microphone going live
    /// and the first sample in hand is not reachable from here; it would take
    /// capturing from an `AudioUnit` directly instead of from `AVAudioEngine`.
    ///
    /// The earlier reasoning here — that 4096 kept the level meter off "a single
    /// syllable's worth of samples" — is deleted rather than corrected. It argued
    /// for a number that turns out not to be honoured, and it had the direction
    /// wrong anyway: 100 ms *is* most of a syllable, and it is the envelope
    /// follower below that stops the bars strobing.
    static let requestedBufferFrames: AVAudioFrameCount = 4096

    private init() {}

    // MARK: - Devices

    /// One input device, as the menu bar lists it (§10.1).
    struct Device: Identifiable, Equatable {
        let id: AudioDeviceID
        let name: String
    }

    /// `nil` means "whatever the system default is at the moment a recording
    /// starts", which is the default and the only value that survives the user
    /// changing their mind in System Settings.
    private static let selectionKey = "InputDeviceUID"

    /// Stored as the device's UID rather than its `AudioDeviceID`: the numeric ID
    /// is assigned per boot and would point at a different device next launch.
    var selectedDevice: Device? {
        get {
            guard let uid = UserDefaults.standard.string(forKey: Self.selectionKey) else { return nil }
            return Self.inputDevices().first { Self.uid(of: $0.id) == uid }
        }
        set {
            let uid = newValue.flatMap { Self.uid(of: $0.id) }
            UserDefaults.standard.set(uid, forKey: Self.selectionKey)
        }
    }

    /// Every device with at least one input stream. A device with no input
    /// streams is an output and cannot be dictated into, so it is not offered.
    static func inputDevices() -> [Device] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return [] }

        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }

        return ids.compactMap { id in
            guard hasInput(id), let name = name(of: id) else { return nil }
            return Device(id: id, name: name)
        }
    }

    static func defaultInputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
        )
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else {
            return false
        }
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer) == noErr else {
            return false
        }
        let list = UnsafeMutableAudioBufferListPointer(
            buffer.assumingMemoryBound(to: AudioBufferList.self)
        )
        return list.contains { $0.mNumberChannels > 0 }
    }

    private static func name(of id: AudioDeviceID) -> String? {
        string(id, kAudioObjectPropertyName)
    }

    private static func uid(of id: AudioDeviceID) -> String? {
        string(id, kAudioDevicePropertyDeviceUID)
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        return status == noErr ? value as String : nil
    }

    // MARK: - Capture

    enum Failure: LocalizedError {
        case noInputDevice
        case unconvertibleFormat
        /// The system prompt is on screen. Not an error the user needs told
        /// about — they are looking at the question right now.
        case permissionPending
        case permissionDenied

        var errorDescription: String? {
            switch self {
            case .noInputDevice, .unconvertibleFormat: "Microphone unavailable"
            case .permissionPending: nil
            case .permissionDenied: "Microphone access is off"
            }
        }
    }

    /// Whether the grant is already held. **Never asks** — the two callers that
    /// use it (`warm()`, and the armed window in `Dictation.arm()`) are both
    /// speculative, and §2.4 asks at first use of the feature.
    static var isAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// **`engine.start()` blocks its caller until the TCC prompt is answered** —
    /// measured at 45 s on the first run of this build, and the caller is the main
    /// actor, so the menu bar and the HUD freeze with it. §2.4 still asks at first
    /// use of the feature; it just asks without holding the main thread while the
    /// user reads the dialog. The gesture that triggered the prompt is spent, and
    /// the next one records.
    private func checkPermission() throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            throw Failure.permissionPending
        default:
            throw Failure.permissionDenied
        }
    }

    /// Resolve the input device and instantiate the input node at launch.
    ///
    /// **This does not open the microphone.** No IO is started, so the system
    /// records no use of the device and draws no indicator; only `engine.start()`
    /// does that. What it buys is the two first-touch costs measured cold —
    /// ~50 ms to reach CoreAudio for the default device and ~259 ms to bring the
    /// input node up — both of which the first gesture pays today.
    ///
    /// **Guarded on the grant Sotto already has**, never on one it could ask for:
    /// §2.4 asks at first use of the feature, so a first run warms nothing and the
    /// first gesture still raises the prompt. Every launch after that is warm.
    func warm() {
        guard Self.isAuthorized else { return }
        // `arm()` re-resolves and re-pins at the next gesture; this is the same
        // call made early, not a substitute for it.
        _ = try? arm()
    }

    /// Start the engine and hand back the buffers. The stream finishes when
    /// `stop()` is called, which is what `Transcription.finish()` waits on.
    ///
    /// `analyzerFormat` is whatever `SpeechAnalyzer` asked for; `nil` means it had
    /// no preference and the device's own format goes through untouched.
    func start(analyzerFormat: AVAudioFormat?) throws -> AsyncStream<AnalyzerInput> {
        try checkPermission()
        let device = try arm()
        let captureFormat = tapFormat ?? engine.inputNode.outputFormat(forBus: 0)
        if let analyzerFormat, analyzerFormat != captureFormat {
            guard let converter = AVAudioConverter(from: captureFormat, to: analyzerFormat) else {
                throw Failure.unconvertibleFormat
            }
            // The analyzer wants one contiguous timeline, and `AVAudioConverter`
            // is stateful across calls when the sample rate changes.
            converter.primeMethod = .none
            self.converter = converter
        } else {
            converter = nil
        }

        smoothed = 0
        retained = []
        retainedFormat = nil
        // Replacing a live continuation without finishing it strands whatever is
        // reading the old stream, and `SpeechAnalyzer` reading it would then never
        // see end-of-input. Nothing should reach here with one open; ending it is
        // one line and removes the possibility.
        self.continuation?.finish()
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = continuation

        isRunning = true
        do {
            try engine.start()
        } catch {
            isRunning = false
            continuation.finish()
            self.continuation = nil
            throw error
        }
        log.notice("Capture started on device \(device, privacy: .public).")
        return stream
    }

    func stop() {
        // **Ending the stream is unconditional; stopping the engine is not.**
        // `finalizeAndFinishThroughEndOfInput()` returns only when the sequence
        // handed to `analyzer.start` ends, and this is the only thing that ends
        // it. Behind the `isRunning` guard, any caller arriving after the engine
        // had already been stopped left the analyzer waiting on a stream nobody
        // would ever finish — an unbounded `await` holding `pipeline`, which is
        // the whole of the stuck-HUD state (2026-08-24).
        continuation?.finish()
        continuation = nil
        guard isRunning else { return }
        isRunning = false
        engine.stop()
        // `stop()` releases what `prepare()` allocated, so re-preparing here is
        // what keeps the next `start()` from paying for the graph again. On the
        // stop path, which is off the latency path entirely.
        engine.prepare()
        converter = nil
    }

    /// Move the retained PCM out. Slice 5 encodes it; abort discards it.
    func takeRecording() -> (format: AVAudioFormat, buffers: [AVAudioPCMBuffer])? {
        defer {
            retained = []
            retainedFormat = nil
        }
        guard let retainedFormat, !retained.isEmpty else { return nil }
        return (retainedFormat, retained)
    }

    func discardRecording() {
        retained = []
        retainedFormat = nil
    }

    /// Resolve the input device, pin it, and make sure the capture tap and the
    /// graph are ready for it. **Idempotent while the device holds still**, which
    /// is what takes the tap install and `prepare()` off every recording — they
    /// were 27 ms and 14 ms of the gesture's path, paid again for a graph that had
    /// not changed since the last one.
    ///
    /// It is install-once-*per-device*, not install-once. `pin` writes the device
    /// onto the input unit, which changes the node's output format, so the format
    /// is read after the pin and the tap is rebuilt whenever either has moved.
    @discardableResult
    private func arm() throws -> AudioDeviceID {
        guard let device = selectedDevice?.id ?? Self.defaultInputDevice() else {
            throw Failure.noInputDevice
        }
        try pin(device)
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        if tapDevice == device, let tapFormat, tapFormat == format { return device }

        if tapFormat != nil { input.removeTap(onBus: 0) }
        input.installTap(onBus: 0, bufferSize: Self.requestedBufferFrames, format: format) { [weak self] buffer, _ in
            guard let self, isRunning else { return }
            let level = Self.level(of: buffer)
            smoothed = level > smoothed ? level : smoothed * 0.6 + level * 0.4
            onLevel?(smoothed)
            guard let converted = convert(buffer) else { return }
            if retainedFormat == nil { retainedFormat = converted.format }
            if let copy = Self.copy(converted) { retained.append(copy) }
            continuation?.yield(AnalyzerInput(buffer: converted))
        }
        tapDevice = device
        tapFormat = format
        engine.prepare()
        return device
    }

    /// Write the device onto the input unit rather than leaving the engine on
    /// "whatever the system default is". §4.8's rule that a device change must not
    /// drop an in-flight recording is this line: once pinned, the engine no longer
    /// follows the default.
    private func pin(_ device: AudioDeviceID) throws {
        guard let unit = engine.inputNode.audioUnit else { throw Failure.noInputDevice }
        var id = device
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else { throw Failure.noInputDevice }
    }

    /// Runs on the audio thread. Returns `nil` when the converter had nothing to
    /// emit yet, which is normal on a sample-rate change and not an error.
    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter else { return buffer }

        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
        guard capacity > 0,
              let out = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity)
        else { return nil }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0 else {
            if let error { log.error("Conversion failed: \(error.localizedDescription, privacy: .public)") }
            return nil
        }
        return out
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }
        out.frameLength = buffer.frameLength
        let srcList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let dstList = UnsafeMutableAudioBufferListPointer(out.mutableAudioBufferList)
        for (src, dst) in zip(srcList, dstList) {
            guard let srcBytes = src.mData, let dstBytes = dst.mData else { continue }
            dstBytes.copyMemory(from: srcBytes, byteCount: Int(src.mDataByteSize))
        }
        return out
    }

    /// Root mean square over the first channel, mapped to 0…1.
    ///
    /// The mapping is a decibel floor rather than a linear scale: linear RMS on
    /// speech sits in the bottom tenth of its range almost all the time, so a
    /// waveform driven by it barely moves. −50 dBFS is the floor because that is
    /// roughly where a quiet room reads on the reference machine's built-in mic.
    private static func level(of buffer: AVAudioPCMBuffer) -> Double {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<count { sum += channel[i] * channel[i] }
        let rms = (sum / Float(count)).squareRoot()
        guard rms > 0 else { return 0 }

        let floorDB = -50.0
        let db = 20 * log10(Double(rms))
        return max(0, min(1, (db - floorDB) / -floorDB))
    }
}
