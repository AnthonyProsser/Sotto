//
//  HistoryTests.swift
//  SottoTests
//
//  Slice 5. Audio entries and the retention ring.
//

import AVFoundation
import Foundation
import Testing
@testable import Sotto

struct HistoryTests {

    // MARK: - Audio entries

    @Test func saveWritesOpusAndInspectableEntry() throws {
        let root = scratch()
        // A quarter-second of Opus is smaller than its CAF cookie; two seconds
        // is long enough for 24 kbps to beat uncompressed 16 kHz float.
        let buffer = sine(seconds: 2)
        let draft = Transcription.Draft(
            text: "hello there how are you",
            words: [
                .init(text: "hello", start: 0.10),
                .init(text: "there", start: 0.40),
                .init(text: "how", start: 1.30),
                .init(text: "are", start: 1.45),
                .init(text: "you", start: 1.60),
            ],
            pauses: [.init(start: 0.70, duration: 0.50)]
        )

        let url = try #require(try AudioHistory.save(
            draft: draft,
            buffers: [buffer],
            format: buffer.format,
            to: root
        ))

        let opus = url.appendingPathComponent("audio.caf")
        let sidecar = url.appendingPathComponent("entry.json")
        #expect(FileManager.default.fileExists(atPath: opus.path))
        #expect(FileManager.default.fileExists(atPath: sidecar.path))

        let wavBytes = Int(buffer.frameLength) * MemoryLayout<Float>.size
        let opusBytes = try FileManager.default.attributesOfItem(atPath: opus.path)[.size] as? Int ?? 0
        #expect(opusBytes > 0)
        #expect(opusBytes < wavBytes)
        let written = try AVAudioFile(forReading: opus)
        #expect(written.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatOpus)

        let entry = try AudioHistory.load(from: url)
        #expect(entry.raw.contains("[pause 500ms]"))
        #expect(entry.raw.contains("hello"))
        #expect(entry.cleaned == nil)
        #expect(entry.profile == nil)
        #expect(entry.locales.isEmpty)
        #expect(entry.pinned == false)
        #expect(entry.words.map(\.text) == ["hello", "there", "how", "are", "you"])
        #expect(entry.pauses.count == 1)
        #expect(abs(entry.pauses[0].duration - 0.50) < 0.000_1)
    }

    /// **Regression, 2026-09-18.** Every sidecar written before the `languages` →
    /// `locales` rename has no `locales` key, and a synthesized decoder throws
    /// `keyNotFound` on it rather than falling back to the property's `= []` —
    /// which emptied the Audio pane with every recording still on disk. The
    /// second half is the amplifier: one unreadable folder used to take the whole
    /// list with it.
    @Test func preRenameSidecarDecodesAndOneBadFolderDoesNotEmptyTheList() throws {
        let root = scratch()
        let folder = root.appendingPathComponent("20260913T014638Z-28C854", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
        {
          "created" : "2026-09-13T01:46:38Z",
          "id" : "20260913T014638Z-28C854",
          "languages" : [],
          "pauses" : [],
          "pinned" : false,
          "raw" : "before the rename",
          "words" : [{ "start" : 0.48, "text" : "before" }]
        }
        """.write(to: folder.appendingPathComponent("entry.json"), atomically: true, encoding: .utf8)

        let entry = try AudioHistory.load(from: folder)
        #expect(entry.locales.isEmpty)
        #expect(entry.raw == "before the rename")

        let broken = root.appendingPathComponent("broken", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try "{".write(to: broken.appendingPathComponent("entry.json"), atomically: true, encoding: .utf8)
        #expect(try AudioHistory.entries(in: root).map(\.id) == [entry.id])
    }

    @Test func disabledStoreWritesNothing() throws {
        let root = scratch()
        let buffer = sine(seconds: 0.1)
        let url = try AudioHistory.save(
            draft: .init(text: "hi", words: [], pauses: []),
            buffers: [buffer],
            format: buffer.format,
            to: root,
            enabled: false
        )
        #expect(url == nil)
        #expect(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).isEmpty)
    }

    @Test func ringEvictsOldestUnpinned() throws {
        let root = scratch()
        let buffer = sine(seconds: 0.05)
        var ids: [String] = []
        for i in 0..<9 {
            let url = try AudioHistory.save(
                draft: .init(text: "n\(i)", words: [], pauses: []),
                buffers: [buffer],
                format: buffer.format,
                to: root,
                ringLimit: 8,
                now: Date(timeIntervalSince1970: 1_000 + Double(i))
            )
            ids.append(url!.lastPathComponent)
        }
        let remaining = Set(try AudioHistory.entries(in: root).map(\.id))
        #expect(remaining.count == 8)
        #expect(!remaining.contains(ids[0]))
        #expect(remaining.contains(ids[8]))
    }

    @Test func pinSurvivesRingEviction() throws {
        let root = scratch()
        let buffer = sine(seconds: 0.05)
        let first = try AudioHistory.save(
            draft: .init(text: "keep", words: [], pauses: []),
            buffers: [buffer],
            format: buffer.format,
            to: root,
            ringLimit: 8,
            now: Date(timeIntervalSince1970: 1_000)
        )!
        try AudioHistory.setPinned(true, id: first.lastPathComponent, in: root)

        for i in 1...8 {
            _ = try AudioHistory.save(
                draft: .init(text: "n\(i)", words: [], pauses: []),
                buffers: [buffer],
                format: buffer.format,
                to: root,
                ringLimit: 8,
                now: Date(timeIntervalSince1970: 1_000 + Double(i))
            )
        }

        let remaining = try AudioHistory.entries(in: root)
        #expect(remaining.contains(where: { $0.id == first.lastPathComponent && $0.pinned }))
        #expect(remaining.count == 8)
        #expect(!remaining.contains(where: { $0.raw == "n1" }))
    }

    @Test func neverDeleteKeepsEverything() throws {
        let root = scratch()
        let buffer = sine(seconds: 0.05)
        for i in 0..<10 {
            _ = try AudioHistory.save(
                draft: .init(text: "n\(i)", words: [], pauses: []),
                buffers: [buffer],
                format: buffer.format,
                to: root,
                ringLimit: 0,
                now: Date(timeIntervalSince1970: 1_000 + Double(i))
            )
        }
        #expect(try AudioHistory.entries(in: root).count == 10)
    }

    @Test func pauseMarkersSitBetweenWords() {
        let marked = AudioHistory.mark(
            "hello there how are you",
            words: [
                .init(text: "hello", start: 0.10),
                .init(text: "there", start: 0.40),
                .init(text: "how", start: 1.30),
                .init(text: "are", start: 1.45),
                .init(text: "you", start: 1.60),
            ],
            pauses: [.init(start: 0.70, duration: 0.50)]
        )
        #expect(marked == "hello there [pause 500ms] how are you")
    }

    /// Slice 11 fills the two slots slice 5 left empty: the cleaned text and
    /// the profile that produced it round-trip through the sidecar.
    @Test func saveStoresCleanedAndProfile() throws {
        let root = scratch()
        let buffer = sine(seconds: 2)
        let draft = Transcription.Draft(
            text: "hello there",
            words: [.init(text: "hello", start: 0.10), .init(text: "there", start: 0.40)],
            pauses: []
        )
        let url = try #require(try AudioHistory.save(
            draft: draft,
            buffers: [buffer],
            format: buffer.format,
            to: root,
            cleaned: "Hello there.",
            profile: "Writing"
        ))
        let entry = try AudioHistory.load(from: url)
        #expect(entry.cleaned == "Hello there.")
        #expect(entry.profile == "Writing")
    }

    // MARK: - Pause markers

    private static func words(_ pairs: [(String, TimeInterval)]) -> [Transcription.Draft.Word] {
        pairs.map { .init(text: $0.0, start: $0.1) }
    }

    @Test func shortPausesAreNotMarked() {
        let words = Self.words([("a", 0), ("b", 1)])
        // Under 80 ms is a detector flap; exactly 80 ms is the first that counts.
        #expect(AudioHistory.mark("a b", words: words, pauses: [.init(start: 0.5, duration: 0.079)]) == "a b")
        #expect(AudioHistory.mark("a b", words: words, pauses: [.init(start: 0.5, duration: 0.080)]) == "a [pause 80ms] b")
    }

    @Test func durationRoundsToWholeMilliseconds() {
        let words = Self.words([("a", 0), ("b", 1)])
        #expect(AudioHistory.mark("a b", words: words, pauses: [.init(start: 0.5, duration: 0.2496)]) == "a [pause 250ms] b")
    }

    @Test func trailingAndMultiplePausesAreMarkedInOrder() {
        let words = Self.words([("one", 0), ("two", 1), ("three", 2)])
        let marked = AudioHistory.mark(
            "one two three",
            words: words,
            pauses: [.init(start: 0.5, duration: 0.3), .init(start: 1.5, duration: 1.2), .init(start: 2.5, duration: 0.9)]
        )
        #expect(marked == "one [pause 300ms] two [pause 1200ms] three [pause 900ms]")
    }

    @Test func repeatedWordsKeepTheirPositions() {
        // A stutter: the same word text three times, pause after the second.
        let words = Self.words([("I", 0.0), ("I", 0.2), ("I", 1.5), ("think", 1.7)])
        let marked = AudioHistory.mark(
            "I I I think", words: words, pauses: [.init(start: 0.8, duration: 0.5)]
        )
        #expect(marked == "I I [pause 500ms] I think")
    }

    @Test func noWordsOrNoPausesLeavesTheTextAlone() {
        #expect(AudioHistory.mark("hi", words: [], pauses: [.init(start: 0, duration: 1)]) == "hi")
        #expect(AudioHistory.mark("hi", words: Self.words([("hi", 0)]), pauses: []) == "hi")
    }

    @Test func unmarkInvertsMarkIncludingALeadingPause() {
        let text = "hello there how are you"
        let words = Self.words([("hello", 0.5), ("there", 0.9), ("how", 2.0), ("are", 2.2), ("you", 2.4)])
        for pauses: [Transcription.Draft.Pause] in [
            [.init(start: 0.1, duration: 0.4)], // before the first word
            [.init(start: 1.2, duration: 0.7), .init(start: 2.6, duration: 0.3)],
        ] {
            #expect(AudioHistory.unmark(AudioHistory.mark(text, words: words, pauses: pauses)) == text)
        }
        #expect(AudioHistory.unmark("a [pause 100ms] b [pause 2000ms] c") == "a b c")
    }

    // MARK: - Sidecar fields

    @Test func cleanedProfileAndLocalesRoundTripThroughEntryJSON() throws {
        let root = scratch()
        let buffer = sine(seconds: 2)
        var draft = Transcription.Draft(
            text: "hello there", words: [.init(text: "hello", start: 0.1)], pauses: []
        )
        draft.locales = ["en_US"]
        let url = try #require(try AudioHistory.save(
            draft: draft, buffers: [buffer], format: buffer.format, to: root,
            cleaned: "Hello there.", profile: "Writing"
        ))

        // On disk in plain JSON, not merely equal after a round trip.
        let json = try String(contentsOf: url.appendingPathComponent("entry.json"), encoding: .utf8)
        #expect(json.contains("\"cleaned\" : \"Hello there.\""))
        #expect(json.contains("\"profile\" : \"Writing\""))
        #expect(json.contains("\"en_US\""))

        let entry = try AudioHistory.load(from: url)
        #expect(entry.cleaned == "Hello there.")
        #expect(entry.profile == "Writing")
        #expect(entry.locales == ["en_US"])
        #expect(try AudioHistory.entries(in: root).first == entry)
    }

    /// An entry from before slice 11: no `cleaned`, `profile`, `locales` or
    /// `languages` keys at all.
    @Test func entryWrittenBeforeTheOptionalFieldsExistedStillDecodes() throws {
        let root = scratch()
        let folder = root.appendingPathComponent("20260820T000000Z-AAAAAA", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
        {
          "created" : "2026-08-20T00:00:00Z",
          "id" : "20260820T000000Z-AAAAAA",
          "pauses" : [],
          "pinned" : true,
          "raw" : "old entry",
          "words" : [{ "start" : 0.1, "text" : "old" }]
        }
        """.write(to: folder.appendingPathComponent("entry.json"), atomically: true, encoding: .utf8)

        let entry = try AudioHistory.load(from: folder)
        #expect(entry.cleaned == nil)
        #expect(entry.profile == nil)
        #expect(entry.locales.isEmpty)
        #expect(entry.pinned)
        #expect(try AudioHistory.entries(in: root).map(\.id) == [entry.id])
    }
}

// MARK: - Fixtures

private func scratch() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("sotto-history-\(UUID().uuidString)", isDirectory: true)
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
