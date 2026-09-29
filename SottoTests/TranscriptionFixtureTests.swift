//
//  TranscriptionFixtureTests.swift
//  SottoTests
//
//  Real Speech frameworks on small `say`-synthesised files (Fixtures/make-fixtures.sh).
//  Synthetic speech is a FLOOR: no noise, accent or disfluency beyond what was
//  scripted, so these prove the pipeline, not real-microphone accuracy.
//  The test host is Sotto and shares `Transcription.shared` with the running
//  app, so the suite is serialised and puts the locale back afterwards.
//

import Foundation
import Speech
import Testing
@testable import Sotto

/// Where a fixture lives: the bundle when the resource was copied in, else the
/// source folder (the synchronized group may flatten or preserve subfolders).
func fixtureURL(_ name: String, file: StaticString = #filePath) -> URL {
    let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
    if let url = Bundle(for: FixtureBundleAnchor.self).url(forResource: base, withExtension: ext) { return url }
    return URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        .appendingPathComponent("Fixtures").appendingPathComponent(name)
}
private final class FixtureBundleAnchor {}

private func supported(_ identifier: String) async -> Bool {
    let locale = Locale(identifier: identifier)
    let speech = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
    let dictation = await DictationTranscriber.supportedLocale(equivalentTo: locale)
    return speech != nil || dictation != nil
}

extension SharedState {
@Suite
struct TranscriptionFixtureTests {

    /// **Restores the app's locale before returning, and must await it.** An
    /// earlier `defer { Task { prepare() } }` was fire-and-forget: it raced the
    /// next test's `prepare(es)`, landed last, and left the singleton on en_US, so
    /// the Spanish fixture was transcribed as English and came back empty.
    private func transcribe(_ fixture: String, locale: String) async throws -> Transcription.Draft {
        // A visible skip, not a failure, when the locale is unsupported here.
        let isSupported = await supported(locale)
        if !isSupported { try Test.cancel("\(locale) not supported on this machine") }
        await Transcription.shared.prepare(Locale(identifier: locale))
        do {
            let draft = try await Transcription.shared.transcribeFile(fixtureURL(fixture)).draft
            await Transcription.shared.prepare()
            return draft
        } catch {
            await Transcription.shared.prepare()
            throw error
        }
    }

    @Test
    func englishFillersFixtureTranscribesWithTimings() async throws {
        let draft = try await transcribe("en-fillers.caf", locale: "en_US")
        let text = draft.text.lowercased()
        #expect(draft.locales.contains { $0.hasPrefix("en") }, "resolved locales: \(draft.locales), text: \(draft.text)")
        #expect(!text.isEmpty)
        for word in ["think", "meet", "budget"] {
            #expect(text.contains(word), "missing \"\(word)\" in: \(draft.text)")
        }
        #expect(!draft.words.isEmpty)
        let starts = draft.words.map(\.start)
        #expect(starts == starts.sorted(), "word starts are not monotonic")
        #expect(draft.words.allSatisfy { $0.start >= 0 })
        // The fixture holds a 1.2 s silence. Known product bug, not a test-path gap:
        // SpeechDetector.results delivers zero results on macOS 27 in every
        // configuration (file or stream input, all sensitivities), and none of the
        // 26 real recordings on disk has ever stored a pause. When this starts
        // passing, `withKnownIssue` fails the run and the wrapper comes off.
        withKnownIssue("SpeechDetector reports no results; pause markers never reach cleanup") {
            #expect(draft.pauses.contains { $0.duration >= 0.6 }, "pauses: \(draft.pauses)")
        }
    }

    @Test
    func spanishFixtureTranscribesWithTimings() async throws {
        let draft = try await transcribe("es-basic.caf", locale: "es_ES")
        let text = draft.text.lowercased()
        #expect(draft.locales.contains { $0.hasPrefix("es") }, "resolved locales: \(draft.locales), text: \(draft.text)")
        #expect(!text.isEmpty)
        for word in ["mesa", "gracias"] {
            #expect(text.contains(word), "missing \"\(word)\" in: \(draft.text)")
        }
        #expect(!draft.words.isEmpty)
    }

    // MARK: - SpeechTranscriber / DictationTranscriber choice

    @Test func englishResolvesToTheSpeechTranscriber() async throws {
        #expect(try await Transcription.shared.transcriberName(for: Locale(identifier: "en_US")) == "SpeechTranscriber")
    }

    /// Dutch is outside `SpeechTranscriber`'s 30 locales and inside `DictationTranscriber`'s 54.
    @Test func aLocaleSpeechTranscriberLacksResolvesToTheDictationTranscriber() async throws {
        let dutch = Locale(identifier: "nl_NL")
        try #require(await SpeechTranscriber.supportedLocale(equivalentTo: dutch) == nil,
                     "nl_NL is now a SpeechTranscriber locale; pick another fallback-only locale")
        if await DictationTranscriber.supportedLocale(equivalentTo: dutch) == nil {
            try Test.cancel("nl_NL not supported on this machine")
        }
        #expect(try await Transcription.shared.transcriberName(for: dutch) == "DictationTranscriber")
    }

    /// The real framework on the fallback path. No punctuation is asserted: that is
    /// the gap cleanup fills (rules/audio-and-transcription.md §5).
    @Test func dutchFixtureTranscribesThroughTheDictationTranscriber() async throws {
        let draft = try await transcribe("nl-basic.caf", locale: "nl_NL")
        #expect(draft.locales.contains { $0.hasPrefix("nl") }, "resolved locales: \(draft.locales), text: \(draft.text)")
        #expect(!draft.text.isEmpty)
        #expect(!draft.words.isEmpty, "the fallback path returned no word timings")
        let starts = draft.words.map(\.start)
        #expect(starts == starts.sorted(), "word starts are not monotonic")
    }
}
}
