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

/// Detect vs Always English, end-of-input to draft. Probe-gated: 40 real
/// transcriptions. Prints p50/p95 and writes `lang-detect-latency.txt`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SOTTO_PROBES"] != nil))
struct DetectLatencyProbe {
    @Test func detectVersusAlwaysEnglish() async throws {
        var out = ""
        var p50 = [String: Double]()
        for fixture in ["en-q1.caf", "en-short1.caf"] {
            for (label, language) in [("english", DictationProfile.Language.english), ("detect", .detect)] {
                _ = try await dictate(fixture, language) // warm
                var ms: [Double] = []
                for _ in 0..<20 { ms.append(try await dictate(fixture, language).endToText) }
                ms.sort()
                let m = ms[ms.count / 2], p95 = ms[Int(Double(ms.count - 1) * 0.95)]
                p50["\(fixture)-\(label)"] = m
                out += String(format: "%@ %@ n=%d p50=%.0f ms p95=%.0f ms\n", fixture, label, ms.count, m, p95)
            }
        }
        print(out)
        try? out.write(
            toFile: "/private/tmp/claude-501/-Users-anthonyprosser-Code-Sotto/9905479f-50fa-4b0d-9436-b51d90048347/scratchpad/lang-detect-latency.txt",
            atomically: true, encoding: .utf8
        )
        #expect(!p50.isEmpty)
    }
}
}
