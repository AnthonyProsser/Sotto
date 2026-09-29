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

import AVFoundation
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

    /// Vocabulary to the recognizer, measured. Prints nothing useful under the harness,
    /// so the per-term hits are written to a file. "No worse" is the assertion: the
    /// recognizer may already get a term right, and biasing must not lose one.
    @Test
    func vocabularyDoesNotHurtAndIsMeasured() async throws {
        let terms = ["Quenthara", "Zorbelix"]
        func hits(_ text: String) -> [String: Bool] {
            Dictionary(uniqueKeysWithValues: terms.map { ($0, text.lowercased().contains($0.lowercased())) })
        }
        func run(_ vocabulary: [String]) async throws -> Transcription.Draft {
            await Transcription.shared.prepare(Locale(identifier: "en_US"))
            defer { Task { await Transcription.shared.prepare() } }
            return try await Transcription.shared.transcribeFile(fixtureURL("en-vocab.caf"), vocabulary: vocabulary).draft
        }
        if !(await supported("en_US")) { try Test.cancel("en_US not supported on this machine") }
        let without = try await run([])
        let with = try await run(terms)
        await Transcription.shared.prepare()
        let a = hits(without.text), b = hits(with.text)
        let report = """
        without: \(without.text)
          hits: \(terms.map { "\($0)=\(a[$0]!)" }.joined(separator: " "))
        with:    \(with.text)
          hits: \(terms.map { "\($0)=\(b[$0]!)" }.joined(separator: " "))

        """
        let dir = "/private/tmp/claude-501/-Users-anthonyprosser-Code-Sotto/9905479f-50fa-4b0d-9436-b51d90048347/scratchpad"
        try? report.write(toFile: dir + "/vocab-results.txt", atomically: true, encoding: .utf8)
        #expect(!with.text.isEmpty, "\(report)")
        #expect(b.values.filter { $0 }.count >= a.values.filter { $0 }.count, "\(report)")
    }

    /// Probe: does `AnalysisContext` move either transcriber on this OS? Each variant
    /// appends one labelled line to vocab-results.txt. Self-contained (its own analyzers
    /// fed from the fixture) so timing of `setContext` relative to `start` can vary.
    @Test
    func contextualStringsProbe() async throws {
        let terms = ["Quenthara", "Zorbelix"]
        let path = "/private/tmp/claude-501/-Users-anthonyprosser-Code-Sotto/9905479f-50fa-4b0d-9436-b51d90048347/scratchpad/vocab-results.txt"
        func log(_ line: String) {
            let old = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            try? (old + line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
        if !(await supported("en_US")) { try Test.cancel("en_US not supported on this machine") }
        let locale = Locale(identifier: "en_US")
        await Transcription.shared.prepare(locale)   // reserves the locale for this process

        enum When { case none, before, after }
        func context(_ strings: [String]) -> AnalysisContext {
            let c = AnalysisContext(); c.contextualStrings[.general] = strings; return c
        }
        func run(_ label: String, dictation: Bool, when: When, strings: [String]) async {
            do {
                let module: any SpeechModule = dictation
                    ? DictationTranscriber(locale: locale, preset: .timeIndexedLongDictation)
                    : SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
                let analyzer = SpeechAnalyzer(modules: [module])
                guard let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
                    log("\(label): no format"); return
                }
                let file = try AVAudioFile(forReading: fixtureURL("en-vocab.caf"))
                let src = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
                try file.read(into: src)
                let converter = AVAudioConverter(from: file.processingFormat, to: target)!
                let ratio = target.sampleRate / file.processingFormat.sampleRate
                let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(src.frameLength) * ratio) + 4096)!
                var fed = false
                var err: NSError?
                converter.convert(to: out, error: &err) { _, status in
                    if fed { status.pointee = .endOfStream; return nil }
                    fed = true; status.pointee = .haveData; return src
                }
                let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
                if when == .before { try await analyzer.setContext(context(strings)) }
                try await analyzer.start(inputSequence: stream)
                if when == .after { try await analyzer.setContext(context(strings)) }
                cont.yield(AnalyzerInput(buffer: out)); cont.finish()
                let collector = Task { () -> String in
                    var text = ""
                    if let m = module as? SpeechTranscriber {
                        for try await r in m.results where r.isFinal { text += String(r.text.characters) }
                    } else if let m = module as? DictationTranscriber {
                        for try await r in m.results where r.isFinal { text += String(r.text.characters) }
                    }
                    return text
                }
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                let text = try await withThrowingTaskGroup(of: String.self) { g in
                    g.addTask { try await collector.value }
                    g.addTask { try await Task.sleep(for: .seconds(3)); collector.cancel(); return "" }
                    let first = try await g.next() ?? ""
                    g.cancelAll(); return first
                }
                let hits = terms.filter { text.lowercased().contains($0.lowercased()) }
                log("\(label): hits=\(hits) text=\(text)")
            } catch { log("\(label): ERROR \(error)") }
        }
        log("--- probe \(Date())")
        let phrases = ["Please ask Quenthara to book the Zorbelix conference room for Friday"]
        await run("speech none          ", dictation: false, when: .none, strings: [])
        await run("speech before start  ", dictation: false, when: .before, strings: terms)
        await run("speech after start   ", dictation: false, when: .after, strings: terms)
        await run("speech after, phrase ", dictation: false, when: .after, strings: phrases)
        await run("dictation none       ", dictation: true, when: .none, strings: [])
        await run("dictation before     ", dictation: true, when: .before, strings: terms)
        await run("dictation after      ", dictation: true, when: .after, strings: terms)
        await Transcription.shared.prepare()
    }
}
}
