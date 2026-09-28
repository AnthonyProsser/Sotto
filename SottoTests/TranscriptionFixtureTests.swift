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

@Suite(.serialized)
struct TranscriptionFixtureTests {

    private func transcribe(_ fixture: String, locale: String) async throws -> Transcription.Draft {
        // A visible skip, not a failure, when the locale is unsupported here.
        let isSupported = await supported(locale)
        if !isSupported { try Test.cancel("\(locale) not supported on this machine") }
        await Transcription.shared.prepare(Locale(identifier: locale))
        let result = try await Transcription.shared.transcribeFile(fixtureURL(fixture))
        return result.draft
    }

    @Test
    func englishFillersFixtureTranscribesWithTimings() async throws {
        defer { Task { await Transcription.shared.prepare() } }
        let draft = try await transcribe("en-fillers.caf", locale: "en_US")
        let text = draft.text.lowercased()
        #expect(!text.isEmpty)
        for word in ["think", "meet", "budget"] {
            #expect(text.contains(word), "missing \"\(word)\" in: \(draft.text)")
        }
        #expect(!draft.words.isEmpty)
        let starts = draft.words.map(\.start)
        #expect(starts == starts.sorted(), "word starts are not monotonic")
        #expect(draft.words.allSatisfy { $0.start >= 0 })
        #expect(draft.locales.contains { $0.hasPrefix("en") })
        // The fixture holds a 1.2 s silence; SpeechDetector should report a long pause.
        #expect(draft.pauses.contains { $0.duration >= 0.6 }, "pauses: \(draft.pauses)")
    }

    @Test
    func spanishFixtureTranscribesWithTimings() async throws {
        defer { Task { await Transcription.shared.prepare() } }
        let draft = try await transcribe("es-basic.caf", locale: "es_ES")
        let text = draft.text.lowercased()
        #expect(!text.isEmpty)
        for word in ["mesa", "gracias"] {
            #expect(text.contains(word), "missing \"\(word)\" in: \(draft.text)")
        }
        #expect(!draft.words.isEmpty)
        #expect(draft.locales.contains { $0.hasPrefix("es") })
    }
}
