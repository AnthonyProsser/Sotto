//
//  AudioHistory.swift
//  Sotto
//
//  Slice 5. Persist a dictation: Opus audio plus an inspectable sidecar.
//

import AudioToolbox
import AVFoundation
import Foundation
import os

/// One folder per dictation under Application Support. The sidecar is JSON
/// because it has to be loaded back; it is pretty-printed because a text
/// editor is the viewer. Obsidian is not a feature (`DECISIONS.md`, 2026-08-19).
///
/// **Empty slots are deliberate.** `cleaned`, `profile`, and `languages` exist
/// so slice 11 can fill them without changing the on-disk shape. See
/// `rules/slices.md` §5.
nonisolated enum AudioHistory {

    static let defaultRingLimit = 8
    static let enabledKey = "AudioHistoryEnabled"
    static let ringLimitKey = "AudioHistoryRingLimit"

    private static let log = Logger(subsystem: "com.anthonyprosser.Sotto", category: "history")

    /// Application Support/Sotto/audio. Created on first use.
    static var root: URL {
        let url = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sotto/audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// App-facing write. Failures stay off the HUD — history is not the work
    /// the gesture started, and a failed save must not take the transcript with it.
    static func record(
        draft: Transcription.Draft,
        buffers: [AVAudioPCMBuffer],
        format: AVAudioFormat
    ) {
        let enabled = (UserDefaults.standard.object(forKey: enabledKey) as? Bool) ?? true
        let limit = (UserDefaults.standard.object(forKey: ringLimitKey) as? Int) ?? defaultRingLimit
        Task.detached {
            do {
                _ = try save(
                    draft: draft,
                    buffers: buffers,
                    format: format,
                    to: root,
                    enabled: enabled,
                    ringLimit: limit
                )
                await MainActor.run {
                    NotificationCenter.default.post(name: .audioHistoryDidChange, object: nil)
                }
            } catch {
                log.error("History save failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Testable write. `ringLimit` of 0 is "never delete."
    @discardableResult
    static func save(
        draft: Transcription.Draft,
        buffers: [AVAudioPCMBuffer],
        format: AVAudioFormat,
        to root: URL,
        enabled: Bool = true,
        ringLimit: Int = defaultRingLimit,
        now: Date = Date()
    ) throws -> URL? {
        guard enabled else { return nil }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let id = stamp(now)
        let folder = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        try writeOpus(buffers, format: format, to: folder.appendingPathComponent("audio.caf"))

        let entry = AudioEntry(
            id: id,
            created: now,
            pinned: false,
            raw: mark(draft.text, words: draft.words, pauses: draft.pauses),
            cleaned: nil,
            profile: nil,
            languages: [],
            words: draft.words,
            pauses: draft.pauses
        )
        try writeSidecar(entry, to: folder)
        try evict(in: root, ringLimit: ringLimit)
        return folder
    }

    static func load(from folder: URL) throws -> AudioEntry {
        let data = try Data(contentsOf: folder.appendingPathComponent("entry.json"))
        return try decoder.decode(AudioEntry.self, from: data)
    }

    static func entries(in root: URL) throws -> [AudioEntry] {
        let dirs = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        ).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        return try dirs.map(load(from:)).sorted { $0.created < $1.created }
    }

    static func setPinned(_ pinned: Bool, id: String, in root: URL) throws {
        let folder = root.appendingPathComponent(id, isDirectory: true)
        var entry = try load(from: folder)
        entry.pinned = pinned
        try writeSidecar(entry, to: folder)
    }

    /// Insert `[pause Nms]` after the last word that started before the pause.
    /// Cleanup (§4.6) reads these; the structured `pauses` array is what seek and
    /// calibration will use, so the inline form is allowed to be lossy.
    static func mark(
        _ text: String,
        words: [Transcription.Draft.Word],
        pauses: [Transcription.Draft.Pause]
    ) -> String {
        let useful = pauses.filter { $0.duration >= 0.08 }
        guard !useful.isEmpty else { return text }
        guard !words.isEmpty else { return text }

        var ranges: [(start: TimeInterval, end: String.Index)] = []
        var cursor = text.startIndex
        for word in words {
            guard let range = text.range(of: word.text, range: cursor..<text.endIndex) else { continue }
            ranges.append((word.start, range.upperBound))
            cursor = range.upperBound
        }

        var insertions: [(String.Index, String)] = []
        for pause in useful {
            let after = ranges.last { $0.start <= pause.start }?.end ?? text.startIndex
            insertions.append((after, " \(tag(pause))"))
        }

        var result = text
        for (index, token) in insertions.sorted(by: { $0.0 > $1.0 }) {
            result.insert(contentsOf: token, at: index)
        }
        return result
    }

    /// The inverse of `mark`, and it lives beside it so the two forms of the
    /// pause marker cannot drift apart.
    ///
    /// **Markers are cleanup's input, not the user's text** (§4.6). They go on
    /// disk because the sidecar has to be able to reproduce what cleanup saw, and
    /// they come off for display because the Audio pane is §14.4's one long-form
    /// reading surface — `[pause 240ms]` in the middle of a sentence is a machine
    /// token in a place a person is reading. Nothing is lost: `pauses` carries the
    /// same information structured, which is what seek and §4.3's calibration
    /// read anyway.
    static func unmark(_ text: String) -> String {
        text.replacing(/\s*\[pause [0-9]+ms\]/, with: "")
    }

    // MARK: -

    private static func evict(in root: URL, ringLimit: Int) throws {
        guard ringLimit > 0 else { return }
        var items = try entries(in: root)
        while items.count > ringLimit {
            guard let index = items.firstIndex(where: { !$0.pinned }) else { break }
            let victim = items.remove(at: index)
            try FileManager.default.removeItem(at: root.appendingPathComponent(victim.id))
        }
    }

    private static func writeSidecar(_ entry: AudioEntry, to folder: URL) throws {
        let data = try encoder.encode(entry)
        try data.write(to: folder.appendingPathComponent("entry.json"), options: .atomic)
    }

    /// Opus @ 24 kbps in a CAF wrapper. Apple's encoder does not write a raw
    /// `.opus` (Ogg) file; the codec is what §9.2 asked for, not the container.
    ///
    /// `AVAudioFile` accepted Opus settings and still wrote linear PCM
    /// (~242 KB for 0.25 s). ExtAudioFile is the encoder that actually compresses.
    private static func writeOpus(
        _ buffers: [AVAudioPCMBuffer],
        format: AVAudioFormat,
        to url: URL
    ) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        // Opus's internal rate. 20 ms packets at 48 kHz are 960 frames.
        let client = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: true
        )!
        var output = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 960,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 0,
            mReserved: 0
        )

        var ext: ExtAudioFileRef?
        var status = ExtAudioFileCreateWithURL(
            url as CFURL,
            kAudioFileCAFType,
            &output,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &ext
        )
        guard status == noErr, let ext else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        defer { ExtAudioFileDispose(ext) }

        var clientASBD = client.streamDescription.pointee
        status = ExtAudioFileSetProperty(
            ext,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            &clientASBD
        )
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }

        var converterSize = UInt32(MemoryLayout<AudioConverterRef>.size)
        var converter: AudioConverterRef?
        if ExtAudioFileGetProperty(ext, kExtAudioFileProperty_AudioConverter, &converterSize, &converter) == noErr,
           let converter {
            var bitrate: UInt32 = 24_000
            AudioConverterSetProperty(
                converter,
                kAudioConverterEncodeBitRate,
                UInt32(MemoryLayout<UInt32>.size),
                &bitrate
            )
        }

        for buffer in buffers {
            let converted = try convert(buffer, to: client)
            status = ExtAudioFileWrite(ext, converted.frameLength, converted.audioBufferList)
            guard status == noErr else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            }
        }
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if buffer.format == format { return buffer }
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else {
            return buffer
        }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(capacity, 1)) else {
            return buffer
        }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if let error { throw error }
        return out
    }

    private static func tag(_ pause: Transcription.Draft.Pause) -> String {
        "[pause \(Int((pause.duration * 1000).rounded()))ms]"
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return "\(formatter.string(from: date))-\(UUID().uuidString.prefix(6))"
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// On-disk shape of one dictation. Slice 11 fills `cleaned`, `profile`, and
/// `languages`; until then they travel as empty slots so the schema does not
/// change under the Audio pane.
nonisolated struct AudioEntry: Sendable, Codable, Equatable {
    var id: String
    var created: Date
    var pinned: Bool
    var raw: String
    var cleaned: String?
    var profile: String?
    var languages: [String]
    var words: [Transcription.Draft.Word]
    var pauses: [Transcription.Draft.Pause]
}


extension Notification.Name {
    /// Posted on the main queue after a dictation lands on disk, and after the
    /// Audio workspace pins or deletes one (slice 6).
    ///
    /// **A notification rather than an observable on `AudioHistory`** because the
    /// writer is a `nonisolated enum` reached from a detached task, and giving it
    /// main-actor state to publish would put the storage layer on the main actor
    /// to serve a window that is usually closed. `CLAUDE.md` §2's "nothing is a
    /// notification" is about the user-facing kind — this one is `NotificationCenter`.
    static let audioHistoryDidChange = Notification.Name("SottoAudioHistoryDidChange")
}
