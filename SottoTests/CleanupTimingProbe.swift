//
//  CleanupTimingProbe.swift — THROWAWAY, deleted after the benchmark run.
//  Times cleanup and file transcription over every stored recording.
//

import AVFoundation
import Foundation
import FoundationModels
import Testing
@testable import Sotto

/// Manual probe, not a test: it walks the real recordings folder and writes to
/// /tmp. Runs only with `TEST_RUNNER_SOTTO_PROBES=1` in the environment.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SOTTO_PROBES"] != nil,
                             "manual probe; set TEST_RUNNER_SOTTO_PROBES=1"))
struct CleanupTimingProbe {
    @Test
    func probeReportAvailability() async throws {
        let availability = SystemLanguageModel(
            useCase: .general,
            guardrails: .permissiveContentTransformations
        ).availability
        let out = "availability=\(String(describing: availability))\n"
        try out.write(to: URL(fileURLWithPath: "/tmp/cleanup-availability.txt"), atomically: true, encoding: .utf8)
    }

    @Test(.enabled(if: liveCleanupAvailable()))
    @MainActor
    func probeCleanupLatencyVsSize() async throws {
        let root = AudioHistory.root
        let entries = try AudioHistory.entries(in: root)
            .filter { !$0.raw.isEmpty }
            .sorted { $0.words.count < $1.words.count }
        let csv = URL(fileURLWithPath: "/tmp/cleanup-timing.csv")
        try "id,words,raw_chars,ms\n".write(to: csv, atomically: true, encoding: .utf8)
        let handle = try FileHandle(forWritingTo: csv)
        defer { try? handle.close() }
        try handle.seekToEnd()
        let profile = DictationProfile(name: "Probe", cleanupEnabled: true)
        // One warm-up pass off the clock, so the first measured row is not the cold one.
        if let first = entries.first {
            _ = try? await Cleanup.shared.clean(first.raw, profile: profile)
        }
        for entry in entries {
            let clock = ContinuousClock()
            let start = clock.now
            _ = try? await Cleanup.shared.clean(entry.raw, profile: profile)
            let elapsed = clock.now - start
            let ms = Double(elapsed.components.seconds * 1_000_000_000 + elapsed.components.attoseconds / 1_000_000_000) / 1_000_000.0
            try handle.write(contentsOf: Data("\(entry.id),\(entry.words.count),\(entry.raw.count),\(Int(ms))\n".utf8))
        }
    }

    @Test
    func probeTranscribeLatencyVsLength() async throws {
        let root = AudioHistory.root
        let dirs = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]
        ).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        await Transcription.shared.prepare()
        let csv = URL(fileURLWithPath: "/tmp/transcribe-timing.csv")
        try "id,audio_sec,wall_ms,rtfx,words\n".write(to: csv, atomically: true, encoding: .utf8)
        let handle = try FileHandle(forWritingTo: csv)
        defer { try? handle.close() }
        try handle.seekToEnd()
        for dir in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let caf = dir.appendingPathComponent("audio.caf")
            guard FileManager.default.fileExists(atPath: caf.path) else { continue }
            let file = try AVAudioFile(forReading: caf)
            let sec = Double(file.length) / file.fileFormat.sampleRate
            let clock = ContinuousClock()
            let start = clock.now
            let result = try? await Transcription.shared.transcribeFile(caf)
            let elapsed = clock.now - start
            let ms = Double(elapsed.components.seconds * 1_000_000_000 + elapsed.components.attoseconds / 1_000_000_000) / 1_000_000.0
            let rtfx = sec * 1000.0 / max(ms, 1)
            let row = "\(dir.lastPathComponent),\(String(format: "%.2f", sec)),\(Int(ms)),\(String(format: "%.1f", rtfx)),\(result?.draft.words.count ?? -1)\n"
            try handle.write(contentsOf: Data(row.utf8))
        }
    }
}
