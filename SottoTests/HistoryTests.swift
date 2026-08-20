//
//  HistoryTests.swift
//  SottoTests
//
//  Slice 5. Audio entries, the retention ring, and the chat-folder writer.
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
        #expect(entry.languages.isEmpty)
        #expect(entry.pinned == false)
        #expect(entry.words.map(\.text) == ["hello", "there", "how", "are", "you"])
        #expect(entry.pauses.count == 1)
        #expect(abs(entry.pauses[0].duration - 0.50) < 0.000_1)
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

    // MARK: - Chat folders

    @Test func chatWriterDropsMarkdownAndAttachments() throws {
        let root = scratch()
        let url = try ChatFolder.write(
            slug: "2026-08-19-sample",
            markdown: "---\ncreated: 2026-08-19\n---\n\nhello\n",
            attachments: ["note.txt": Data("hi".utf8)],
            to: root
        )
        #expect(url.lastPathComponent == "2026-08-19-sample")
        #expect(try String(contentsOf: url.appendingPathComponent("chat.md"), encoding: .utf8).contains("hello"))
        #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent("attachments").path))
        #expect(try String(contentsOf: url.appendingPathComponent("attachments/note.txt"), encoding: .utf8) == "hi")
    }

    @Test func chatWriterCreatesEmptyAttachmentsDirectory() throws {
        let root = scratch()
        let url = try ChatFolder.write(slug: "empty-chat", markdown: "hi\n", to: root)
        var isDir: ObjCBool = false
        let attachments = url.appendingPathComponent("attachments")
        #expect(FileManager.default.fileExists(atPath: attachments.path, isDirectory: &isDir) && isDir.boolValue)
        #expect(try FileManager.default.contentsOfDirectory(at: attachments, includingPropertiesForKeys: nil).isEmpty)
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
