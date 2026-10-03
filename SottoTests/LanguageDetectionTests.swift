//
//  LanguageDetectionTests.swift
//  SottoTests
//
//  Per-dictation English/Spanish detection (`DECISIONS.md`, 2026-09-28). `say`
//  audio is a floor, not a microphone figure. The rule tests are pure; the
//  fixture tests drive the real begin/finish path with file buffers.
//

import AVFoundation
import Foundation
import Speech
import Testing
@testable import Sotto

@Suite
struct DetectionRuleTests {
    /// The two known traps: the Spanish model returns near-English words for English
    /// audio, and a short Spanish clip gives the recognizer very little text.
    @Test func englishTextFromTheSpanishModelIsNotSpanish() {
        #expect(!Transcription.prefersSpanish("Please sent me the corderly report by Friday."))
        #expect(!Transcription.prefersSpanish("Sounds good. Thanks."))
        #expect(!Transcription.prefersSpanish(""))
    }

    @Test func shortSpanishIsSpanish() {
        #expect(Transcription.prefersSpanish("Suena bien, gracias."))
        #expect(Transcription.prefersSpanish("Llámame luego."))
        #expect(Transcription.prefersSpanish("Necesito la cuenta de la mesa, por favor."))
    }

    @Test func profilesSavedBeforeLanguageDecodeAsDetect() throws {
        let old = #"{"id":"a","name":"Default","cleanupEnabled":true,"cleanupInstructions":"","vocabulary":[]}"#
        let profile = try JSONDecoder().decode(DictationProfile.self, from: Data(old.utf8))
        #expect(profile.language == .detect)
        let round = try JSONDecoder().decode(
            DictationProfile.self,
            from: JSONEncoder().encode(DictationProfile(name: "x", language: .spanish))
        )
        #expect(round.language == .spanish)
    }

    @Test func cleanupInstructionsForbidTranslation() {
        #expect(Cleanup.instructions(for: DictationProfile(name: "x")).contains("NEVER translate"))
    }
}

/// Runs the recording path a gesture does — `begin` on a stream, `finish` after it ends.
private func dictate(_ fixture: String, _ language: DictationProfile.Language) async throws -> (draft: Transcription.Draft, endToText: Double) {
    await Transcription.shared.prepare(Locale(identifier: "en_US"))
    // Awaited, never fire-and-forget: a racing restore left the singleton on the wrong locale before.
    guard let format = await Transcription.shared.audioFormat() else { throw Transcription.Failure.notPrepared }
    let buffers = try loadBuffers(fixtureURL(fixture), target: format)
    let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
    let t0: ContinuousClock.Instant, draft: Transcription.Draft
    do {
        try await Transcription.shared.begin(stream, language: language)
        for buffer in buffers { continuation.yield(AnalyzerInput(buffer: buffer)) }
        continuation.finish()
        t0 = ContinuousClock.now
        draft = try await Transcription.shared.finish()
    } catch {
        await Transcription.shared.prepare()
        throw error
    }
    let d = ContinuousClock.now - t0
    await Transcription.shared.prepare()
    return (draft, Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
}

extension SharedState {
@Suite
struct DetectPathTests {
    private func requireBoth() async throws {
        for id in ["en_US", "es_ES"] {
            let ok = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: id)) != nil
            if !ok { try Test.cancel("\(id) not supported on this machine") }
        }
    }

    private func detected(_ fixture: String) async throws -> String {
        try await requireBoth()
        let (draft, _) = try await dictate(fixture, .detect)
        return (draft.locales.first ?? "") + "|" + draft.text
    }

    @Test func shortEnglishStaysEnglish() async throws {
        let r = try await detected("en-short1.caf")
        #expect(r.hasPrefix("en"), "\(r)")
    }

    @Test func fillerEnglishStaysEnglish() async throws {
        let r = try await detected("en-fillers.caf")
        #expect(r.hasPrefix("en"), "\(r)")
    }

    @Test func shortSpanishIsDetected() async throws {
        let r = try await detected("es-short2.caf")
        #expect(r.hasPrefix("es"), "\(r)")
    }

    @Test func spanishIsDetected() async throws {
        let r = try await detected("es-basic.caf")
        #expect(r.hasPrefix("es"), "\(r)")
    }

    @Test func codeSwitchedClipReturnsText() async throws {
        let r = try await detected("en-codeswitch.caf")
        #expect(r.split(separator: "|", maxSplits: 1).count == 2 && r.count > 4, "\(r)")
    }

    @Test func alwaysSpanishForcesTheLocale() async throws {
        try await requireBoth()
        let (draft, _) = try await dictate("es-basic.caf", .spanish)
        #expect(draft.locales.first?.hasPrefix("es") == true, "\(draft.locales) \(draft.text)")
    }
}

/// The v1 latency matrix: Always English vs Detect × cleanup off vs on, timed from
/// end of input to the text `Dictation` would insert (transcription finish, then the
/// cleanup pass on the marked draft, exactly as `Dictation.stop` runs it). Probe-gated:
/// 20 timed runs per case after a warm-up. Writes `/tmp/sotto-latency-matrix.txt`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SOTTO_PROBES"] != nil))
struct DetectLatencyProbe {
    @Test func latencyMatrix() async throws {
        let profile = DictationProfile(name: "Latency", cleanupEnabled: true)
        func run(_ fixture: String, _ language: DictationProfile.Language, cleanup: Bool) async throws -> (ms: Double, rejected: Bool) {
            let (draft, transcribe) = try await dictate(fixture, language)
            guard cleanup, !draft.text.isEmpty else { return (transcribe, false) }
            let marked = AudioHistory.mark(draft.text, words: draft.words, pauses: draft.pauses)
            let t0 = ContinuousClock.now
            var rejected = false
            do { _ = try await Cleanup.shared.clean(marked, profile: profile) } catch { rejected = true }
            let d = ContinuousClock.now - t0
            return (transcribe + Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15, rejected)
        }
        var out = ""
        for fixture in ["en-q1.caf", "en-short1.caf"] {
            for cleanup in [false, true] {
                for (label, language) in [("english", DictationProfile.Language.english), ("detect", .detect)] {
                    _ = try await run(fixture, language, cleanup: cleanup) // warm
                    var ms: [Double] = [], rejected = 0
                    for _ in 0..<20 {
                        let r = try await run(fixture, language, cleanup: cleanup)
                        ms.append(r.ms); if r.rejected { rejected += 1 }
                    }
                    ms.sort()
                    let p50 = ms[ms.count / 2], p95 = ms[Int(Double(ms.count - 1) * 0.95)]
                    out += String(format: "%@ cleanup=%@ %@ n=%d p50=%.0f ms p95=%.0f ms rejected=%d\n",
                                  fixture, cleanup ? "on " : "off", label, ms.count, p50, p95, rejected)
                }
            }
        }
        print(out)
        try? out.write(toFile: "/tmp/sotto-latency-matrix.txt", atomically: true, encoding: .utf8)
        #expect(!out.isEmpty)
    }
}
}
