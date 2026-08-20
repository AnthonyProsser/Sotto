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

    /// The meter's follower. Raw RMS at ~12 Hz makes the bars snap between
    /// syllables; an envelope that rises almost immediately and falls over a few
    /// buffers reads as a voice rather than as a strobe. Fast attack because a
    /// waveform that lags the first word is the one thing the HUD must not do.
    private var smoothed: Double = 0

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

    /// Start the engine and hand back the buffers. The stream finishes when
    /// `stop()` is called, which is what `Transcription.finish()` waits on.
    ///
    /// `analyzerFormat` is whatever `SpeechAnalyzer` asked for; `nil` means it had
    /// no preference and the device's own format goes through untouched.
    func start(analyzerFormat: AVAudioFormat?) throws -> AsyncStream<AnalyzerInput> {
        try checkPermission()
        guard let device = selectedDevice?.id ?? Self.defaultInputDevice() else {
            throw Failure.noInputDevice
        }
        // Written before the format is read: changing the current device changes
        // the input node's format, and a tap installed against the old one fails
        // at `engine.start()` rather than at the mismatch.
        try pin(device)

        let input = engine.inputNode
        let captureFormat = input.outputFormat(forBus: 0)
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
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = continuation

        // 4096 frames ≈ 85 ms at 48 kHz: enough that the level meter is not
        // reading a single syllable's worth of samples, short enough that the
        // waveform still moves with the voice.
        input.installTap(onBus: 0, bufferSize: 4096, format: captureFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let level = Self.level(of: buffer)
            smoothed = level > smoothed ? level : smoothed * 0.6 + level * 0.4
            onLevel?(smoothed)
            guard let converted = convert(buffer) else { return }
            continuation.yield(AnalyzerInput(buffer: converted))
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            continuation.finish()
            self.continuation = nil
            throw error
        }
        isRunning = true
        log.notice("Capture started on device \(device, privacy: .public).")
        return stream
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        continuation?.finish()
        continuation = nil
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
