//
//  AudioWorkspaceTests.swift
//  SottoTests
//
//  Slice 6. The pure parts of the audio workspace: what the sidebar orders and
//  filters, what the pane displays, and what the waveform is drawn from. The
//  parts that are not pure — playback, click-to-seek — were checked against the
//  running app instead, which is the only place they exist.
//

import AVFoundation
import Foundation
import Testing
@testable import Sotto

struct AudioWorkspaceTests {

    // MARK: - Sidebar order and search

    @Test func orderPutsPinnedFirstThenNewest() {
        let old = recording(id: "old", text: "one", created: .distantPast)
        let new = recording(id: "new", text: "two", created: .distantFuture)
        let pinnedOld = recording(id: "pin", text: "three", created: .distantPast, pinned: true)

        let order = AudioLibrary.ordered([old, new, pinnedOld], matching: "").map(\.id)
        #expect(order == ["pin", "new", "old"])
    }

    @Test func searchIsCaseInsensitiveAndReadsBothSides() {
        let raw = recording(id: "raw", text: "Welcome to my dictation app")
        var withCleaned = recording(id: "cleaned", text: "unrelated words")
        withCleaned.entry.cleaned = "Punctuated ChatGPT sentence."

        #expect(AudioLibrary.ordered([raw, withCleaned], matching: "DICTATION").map(\.id) == ["raw"])
        #expect(AudioLibrary.ordered([raw, withCleaned], matching: "chatgpt").map(\.id) == ["cleaned"])
        // An empty query is not a filter — every recording survives it.
        #expect(AudioLibrary.ordered([raw, withCleaned], matching: "").count == 2)
        #expect(AudioLibrary.ordered([raw, withCleaned], matching: "qqqq").isEmpty)
    }

    // MARK: - What the pane displays

    @Test func pauseMarkersAreStrippedForDisplayButKeptOnDisk() {
        let marked = AudioHistory.mark(
            "hello there",
            words: [.init(text: "hello", start: 0.0), .init(text: "there", start: 0.8)],
            pauses: [.init(start: 0.2, duration: 0.5)]
        )
        #expect(marked.contains("[pause 500ms]"))
        // The inverse: what the transcript body shows carries no markers, and the
        // words either side of one are not run together.
        #expect(AudioHistory.unmark(marked) == "hello there")
        // Text that never had a marker is returned untouched.
        #expect(AudioHistory.unmark("nothing to strip") == "nothing to strip")
    }

    @Test func titleFallsBackWhenTheTranscriptIsBlank() {
        #expect(recording(id: "a", text: "  spoken words  ").title == "spoken words")
        #expect(recording(id: "b", text: "   ").title == String(localized: "Recording"))
    }

    @Test func clockSwitchesPatternPastAnHourAndClampsBelowZero() {
        #expect(AudioLibrary.clock(0) == "0:00")
        #expect(AudioLibrary.clock(9) == "0:09")
        #expect(AudioLibrary.clock(-5) == "0:00")
        // An import can be hours long; a bare minute:second pattern would report
        // a ninety-minute file as 30:00.
        #expect(AudioLibrary.clock(5400).contains("1:30"))
    }

    // MARK: - Duration and the waveform

    @Test func durationComesFromTheCafHeaderNotTheSidecar() throws {
        let root = scratch()
        let buffer = sine(seconds: 2)
        let url = try #require(try AudioHistory.save(
            draft: .init(text: "two seconds", words: [], pauses: []),
            buffers: [buffer],
            format: buffer.format,
            to: root
        ))

        // The claim `Recording.duration` rests on: the Opus stream's header
        // reports the length without decoding a packet, so no fourth field has
        // to be added to slice 5's frozen `AudioEntry`.
        let file = try AVAudioFile(forReading: url.appendingPathComponent("audio.caf"))
        let seconds = Double(file.length) / file.processingFormat.sampleRate
        #expect(abs(seconds - 2) < 0.1)

        let entry = try AudioHistory.load(from: url)
        let mirror = Mirror(reflecting: entry).children.compactMap(\.label)
        #expect(!mirror.contains("duration"))
    }

    @Test func envelopeFillsEveryBucketAndNormalisesToTheLoudestMoment() throws {
        let root = scratch()
        let buffer = sine(seconds: 2)
        let url = try #require(try AudioHistory.save(
            draft: .init(text: "tone", words: [], pauses: []),
            buffers: [buffer],
            format: buffer.format,
            to: root
        ))

        let peaks = AudioPlayback.envelope(of: url.appendingPathComponent("audio.caf"), buckets: 64)
        #expect(peaks.count == 64)
        #expect(peaks.allSatisfy { $0 >= 0 && $0 <= 1 })
        // Normalised against the file's own loudest bucket, so a quiet recording
        // still draws full height rather than a flat line.
        #expect(peaks.max() ?? 0 > 0.99)
        // A steady tone has no silent stretch; nothing should be floored at zero.
        #expect(peaks.filter { $0 > 0.1 }.count > 32)
    }

    @Test func envelopeOfAMissingFileIsEmptyRatherThanACrash() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("sotto-absent-\(UUID().uuidString).caf")
        #expect(AudioPlayback.envelope(of: missing, buckets: 64).isEmpty)
    }

    // MARK: - Load failure

    @Test @MainActor func loadDoesNotCommitIdWhenThePlayerCannotOpen() {
        let playback = AudioPlayback.shared
        playback.stop()
        defer { playback.stop() }

        let missing = recording(id: "missing-\(UUID().uuidString)", text: "gone")
        playback.load(missing)
        #expect(playback.id == nil)

        // Selecting the same row again has to retry. Committing the id on a
        // failed open would make this a no-op and leave Play dead.
        playback.load(missing)
        #expect(playback.id == nil)
    }
}

// MARK: - Fixtures

private func recording(
    id: String,
    text: String,
    created: Date = Date(),
    pinned: Bool = false
) -> AudioLibrary.Recording {
    AudioLibrary.Recording(
        entry: AudioEntry(
            id: id,
            created: created,
            pinned: pinned,
            raw: text,
            cleaned: nil,
            profile: nil,
            languages: [],
            words: [],
            pauses: []
        ),
        folder: URL(fileURLWithPath: "/tmp/\(id)"),
        duration: 1
    )
}

private func scratch() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("sotto-slice6-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func sine(seconds: Double, sampleRate: Double = 16_000) -> AVAudioPCMBuffer {
    let frames = AVAudioFrameCount((seconds * sampleRate).rounded())
    let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: false
    )!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    let samples = buffer.floatChannelData![0]
    let twoPi = Float.pi * 2
    for i in 0..<Int(frames) {
        samples[i] = sinf(twoPi * 440 * Float(i) / Float(sampleRate)) * 0.2
    }
    return buffer
}
