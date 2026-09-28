//
//  Transcription.swift
//  Sotto
//
//  Slice 3. Apple's Speech framework, exclusively — DECISIONS.md, 2026-08-19.
//

import AVFoundation
import CoreMedia
import Foundation
import NaturalLanguage
import Speech
import os

/// **The whole of v1's speech-to-text.** `SpeechAnalyzer` with `SpeechTranscriber`,
/// falling back to `DictationTranscriber` past `SpeechTranscriber`'s 30 locales
/// (`rules/audio-and-transcription.md` §5). Parakeet, FluidAudio, Silero, and
/// Whisper ship in no form, and there is deliberately no backend-selection seam:
/// a second engine stays possible behind §2.2's "audio in, timestamped text out"
/// interface, but nothing here is built to receive one.
///
/// **Sotto does not chunk.** The analyzer segments and streams by itself — 110
/// finalized results over nine minutes, first at 0.507 s, measured. §4.2's
/// `maxChunk` was FluidAudio's internal threshold and went with it.
///
/// An actor because `SpeechAnalyzer` is one, the capture thread feeds it, and the
/// main actor starts and stops it.
actor Transcription {
    static let shared = Transcription()

    private let log = Logger(subsystem: "com.anthonyprosser.Sotto", category: "stt")

    /// Survives between recordings: which transcriber, which locale, and the
    /// format the analyzer asked for.
    private var kind: Kind?
    private var format: AVAudioFormat?

    /// **Rebuilt for every recording, and that is not an optimisation to undo.**
    /// Handing the same `SpeechTranscriber` to a second `SpeechAnalyzer` traps
    /// inside the framework — `EXC_BREAKPOINT` in `TranscriberCommon.worker`
    /// setter, from `SpeechAnalyzer.prepareModulesIfNeeded()`, reproduced on the
    /// second dictation of every launch (2026-08-19). A module belongs to one
    /// analyzer for its lifetime.
    ///
    /// **One lane, or two under Detect** (`DECISIONS.md`, 2026-09-28): a lane is a
    /// module, its own analyzer, and its collector. Detect runs an English and a
    /// Spanish lane on the same buffers to completion; the detector rides the
    /// first lane only, since pauses do not depend on the locale.
    private var lanes: [Lane] = []
    private var detector: SpeechDetector?
    private var pauseCollector: Task<[Draft.Pause], Error>?
    private var feeder: Task<Void, Never>?
    /// English and Spanish, reserved at launch when the machine already has them.
    private var enKind: Kind?
    private var esKind: Kind?

    private struct Lane {
        let engine: Engine
        let analyzer: SpeechAnalyzer
        let collector: Task<Draft, Error>
    }

    private init() {}

    /// What a finished recording produces. Word timings are **starts only** —
    /// `endTime` is never read (§9.3), which sidesteps a bug class and is
    /// independently validated by the measurement: word starts hit a bounded
    /// floor, sentence ends smear to +1075 ms at long pauses.
    ///
    /// `pauses` come from `SpeechDetector` on the same analyzer. Slice 4's
    /// chunker is gone; the detector is what is left of that slice, folded
    /// into history so cleanup (§4.6) and the sidecar have something to store.
    struct Draft: Sendable {
        struct Word: Sendable, Codable, Equatable {
            let text: String
            let start: TimeInterval
        }

        struct Pause: Sendable, Codable, Equatable {
            let start: TimeInterval
            let duration: TimeInterval
        }

        var text: String
        var words: [Word]
        var pauses: [Pause]

        /// **The locale of the transcript that won, read off the module that
        /// produced it.** Apple's Speech framework does not detect language;
        /// Sotto's Detect mode runs English and Spanish and picks by the text
        /// (`DECISIONS.md`, 2026-09-28), so under Detect this is the pick and
        /// under Always English / Spanish it is the setting.
        ///
        /// Plural because `LocaleDependentSpeechModule.selectedLocales` is
        /// plural, and this is read straight off it rather than reconstructed.
        /// **Today it always holds exactly one**, because the only initialiser
        /// either transcriber offers is `init(locale:)`, singular. If Apple ever
        /// lets a module select several, this fills itself and neither the
        /// schema nor the badge row changes.
        var locales: [String] = []
    }

    enum Failure: LocalizedError {
        /// The locale's assets are not on the machine and installing them is a
        /// download, which §2's consent rule does not let Sotto start by itself.
        case localeNotInstalled(Locale)
        case noSupportedLocale(Locale)
        case notPrepared

        var errorDescription: String? {
            switch self {
            case .localeNotInstalled, .noSupportedLocale: "Language not available"
            case .notPrepared: "Transcription unavailable"
            }
        }
    }

    // MARK: - Startup

    /// **`reserve()` is a claim, not a download** (`rules/audio-and-transcription.md`
    /// §1.0). macOS already ships ~1 GB of ASR assets for its own dictation;
    /// `status(forModules:)` returning `.supported` means "not claimed by this
    /// app", and one `reserve(locale:)` flips it to `.installed` with no network
    /// access. Reservation is per-process, so it happens once at launch.
    ///
    /// **`installedLocales` is not consulted.** It reported `en_US` installed on a
    /// machine where `status(forModules:)` said `.supported` for the same locale;
    /// gating on it and calling `downloadAndInstall()` downloads a model the
    /// machine already has.
    func prepare(_ locale: Locale = .current) async {
        do {
            let kind = try await resolve(locale)
            try await AssetInventory.reserve(locale: kind.locale)
            // A module built only to be asked two questions and thrown away; it
            // never meets an analyzer, so the one-analyzer rule above is intact.
            let probe = kind.makeEngine().module
            guard await AssetInventory.status(forModules: [probe]) == .installed else {
                throw Failure.localeNotInstalled(kind.locale)
            }
            // English and Spanish for Detect, and for the Always-X settings.
            // Reserve only — a locale the machine does not already have is
            // skipped, never downloaded (§2's consent rule).
            enKind = await reserveIfInstalled("en_US")
            esKind = await reserveIfInstalled("es_ES")
            // Preinstalled. Included so the format we cache is one every
            // module will accept; a detector-incompatible format would
            // make pause collection fail on every recording.
            let modules = [probe] + [enKind, esKind].compactMap { $0?.makeEngine().module }
            let detector = SpeechDetector()
            format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules + [detector])
            if format == nil {
                format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules)
            }
            self.kind = kind
            log.notice("""
                Transcriber ready: \(kind.label, privacy: .public) \
                \(kind.locale.identifier, privacy: .public).
                """)
        } catch {
            log.error("Transcriber unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func reserveIfInstalled(_ identifier: String) async -> Kind? {
        guard let match = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)),
              (try? await AssetInventory.reserve(locale: match)) != nil
        else { return nil }
        let kind = Kind.speech(match)
        guard await AssetInventory.status(forModules: [kind.makeEngine().module]) == .installed else {
            log.error("\(identifier, privacy: .public) is not installed; not offered to dictation.")
            return nil
        }
        return kind
    }

    /// The format the analyzer wants, for `AudioCapture` to convert into.
    func audioFormat() -> AVAudioFormat? { format }

    // MARK: - A recording

    /// Start analysing. Returns as soon as the analyzer is running; the results
    /// accumulate in the background until `finish()` or `cancel()`.
    func begin(_ inputs: AsyncStream<AnalyzerInput>, language: DictationProfile.Language = .detect) async throws {
        if kind == nil { await prepare() }
        guard let kind else { throw Failure.notPrepared }

        let kinds = try kinds(for: language, fallback: kind)
        // Fresh module per recording, same rule as the transcriber. `reportResults`
        // is what fills `results`; the convenience init does not.
        let detector = SpeechDetector(
            detectionOptions: .init(sensitivityLevel: .medium),
            reportResults: true
        )
        self.detector = detector
        lanes = kinds.enumerated().map { makeLane($1.makeEngine(), detector: $0 == 0 ? detector : nil) }
        pauseCollector = Task { try await Self.collectPauses(detector) }
        // A second analyzer needs its own stream; `AnalyzerInput` shares the buffer.
        let streams = fanOut(inputs, to: lanes.count)
        for (lane, stream) in zip(lanes, streams) {
            try await lane.analyzer.start(inputSequence: stream)
        }
    }

    /// Called once the capture stream has finished. `finalizeAndFinishThroughEndOfInput`
    /// is what turns the last volatile span into a finalized result, so the draft
    /// is only complete after it returns.
    func finish() async throws -> Draft {
        guard !lanes.isEmpty else { throw Failure.notPrepared }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (i, lane) in lanes.enumerated() {
                group.addTask {
                    do { try await lane.analyzer.finalizeAndFinishThroughEndOfInput() }
                    // The primary lane's failure is the dictation's; a secondary
                    // lane failing only costs the detection its second opinion.
                    catch { if i == 0 { throw error } }
                }
            }
            try await group.waitForAll()
        }
        return try await collectDraft()
    }

    /// Which locales a recording runs, in lane order (English first). Detect
    /// degrades to whatever of English and Spanish is installed, and leaves a
    /// system locale that is neither alone rather than forcing it onto en/es.
    private func kinds(for language: DictationProfile.Language, fallback: Kind) throws -> [Kind] {
        switch language {
        case .english:
            guard let enKind else { throw Failure.localeNotInstalled(Locale(identifier: "en_US")) }
            return [enKind]
        case .spanish:
            guard let esKind else { throw Failure.localeNotInstalled(Locale(identifier: "es_ES")) }
            return [esKind]
        case .detect:
            let code = fallback.locale.language.languageCode
            let pair = [enKind, esKind].compactMap { $0 }
            return pair.isEmpty || (code != "en" && code != "es") ? [fallback] : pair
        }
    }

    private func makeLane(_ engine: Engine, detector: SpeechDetector?) -> Lane {
        var modules: [any SpeechModule] = [engine.module]
        if let detector { modules.append(detector) }
        return Lane(
            engine: engine,
            analyzer: SpeechAnalyzer(modules: modules),
            collector: Task { try await engine.collect() }
        )
    }

    private func fanOut(_ inputs: AsyncStream<AnalyzerInput>, to count: Int) -> [AsyncStream<AnalyzerInput>] {
        guard count > 1 else { return [inputs] }
        let pairs = (0..<count).map { _ in AsyncStream<AnalyzerInput>.makeStream() }
        feeder = Task {
            for await input in inputs { pairs.forEach { $0.continuation.yield(input) } }
            pairs.forEach { $0.continuation.finish() }
        }
        return pairs.map(\.stream)
    }

    /// **The Detect rule** (`DECISIONS.md`, 2026-09-28): Spanish only when the
    /// on-device language recognizer, constrained to English and Spanish, gives
    /// the *Spanish* transcript P(es) of at least 0.8; otherwise English. Model
    /// confidence was rejected — the Spanish model is confident on English words.
    nonisolated static func prefersSpanish(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.english, .spanish]
        recognizer.processString(text)
        return (recognizer.languageHypotheses(withMaximum: 2)[.spanish] ?? 0) >= 0.8
    }

    /// No UI caller: file import is out of v1 (`DECISIONS.md`, 2026-09-28). Kept as
    /// the entry point fixture tests use, because `analyzeSequence(from:)` never
    /// finalizes and `isFinal` results would never arrive.
    ///
    /// A file off disk through the same modules as a dictation.
    /// Returns the draft plus the analyzed audio as buffers, so the caller
    /// stores exactly what was transcribed. Anything AVFoundation reads is
    /// accepted (m4a, mp3, wav, aac); a format the analyzer does not want is
    /// converted through a temp file first.
    func transcribeFile(_ source: URL) async throws -> (
        draft: Draft, buffers: [AVAudioPCMBuffer], format: AVAudioFormat
    ) {
        if kind == nil { await prepare() }
        guard kind != nil else { throw Failure.notPrepared }

        let engine = kind!.makeEngine()
        let detector = SpeechDetector(
            detectionOptions: .init(sensitivityLevel: .medium),
            reportResults: true
        )
        self.detector = detector

        let target = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [engine.module, detector]
        ) ?? format ?? AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        let analysisURL = try Self.analysisFile(for: source, target: target)
        defer {
            if analysisURL != source {
                try? FileManager.default.removeItem(at: analysisURL)
            }
        }
        let analysis = try AVAudioFile(forReading: analysisURL)

        let lane = makeLane(engine, detector: detector)
        let analyzer = lane.analyzer
        lanes = [lane]
        pauseCollector = Task { try await Self.collectPauses(detector) }
        // `finishAfterFile` is the whole point: without it the file's results
        // never finalize, the `isFinal` filter in `drain` matches nothing, and
        // the import lands empty with no error anywhere.
        try await analyzer.start(inputAudioFile: analysis, finishAfterFile: true)
        // `start` returns once the file is consumed, not once its results are
        // delivered. `collectDraft`'s grace assumes finalize has returned (as in
        // `finish()`); without this, a slow first transcription after launch
        // (asset load, ANE shared with the cleanup prewarm) outlasts the 2 s
        // grace, the collectors are cancelled, and the draft comes back empty.
        try await analyzer.finalizeAndFinishThroughEndOfInput()

        let draft = try await collectDraft()
        let buffers = try Self.readFully(analysis)
        return (draft, buffers, analysis.processingFormat)
    }

    /// The tail both inputs share: the microphone path calls it after finalize
    /// returns, the file path after the sequence is consumed. Bounded wait on
    /// the result sequences (§1.0), then the draft. Owns teardown.
    private func collectDraft() async throws -> Draft {
        defer { teardown() }
        guard !lanes.isEmpty else { throw Failure.notPrepared }

        // **The modules' result sequences do not reliably end when the analyzer
        // does, and the two `await`s below are the only unbounded waits in a
        // dictation.** Finalizing is the analyzer's statement that every result
        // has been delivered, so `results` should finish with it. Measured
        // 2026-08-24: after several short recordings in quick succession it
        // sometimes does not, and `collector.value` then suspends forever. That
        // suspension is the whole of the stuck-HUD bug — it holds
        // `Dictation.pipeline` non-nil, so the HUD is never hidden, the idle
        // signal keeps reporting `recording`, and every later gesture is rejected
        // by the `pipeline == nil` guard until the app is relaunched.
        //
        // Sotto has paid everything it owes before this point: the input stream is
        // finished (`AudioCapture.stop`) and `finalizeAndFinishThroughEndOfInput`
        // has *returned*. The only missing signal is Apple's end-of-sequence, which
        // is why this is a bounded wait rather than a defect to fix upstream of it.
        // It is not a watchdog over Sotto's own state: nothing here resets the
        // pipeline, sets a flag, or hides the HUD. It ends the wait, and the
        // ordinary path then completes and clears the state itself — measured, the
        // draft returns 1 ms after the grace fires and the dictation finishes
        // normally with whatever was transcribed.
        let forceEnd = Task { [weak self] in
            try await Task.sleep(for: Self.resultGrace)
            await self?.endSequencesThatOutlivedTheAnalyzer()
        }
        defer { forceEnd.cancel() }

        // Locales are read off each live module before `teardown()` fires in the
        // defer above — the module is what holds the answer.
        var drafts: [Draft] = []
        for (i, lane) in lanes.enumerated() {
            var d: Draft
            if i == 0 {
                d = try await lane.collector.value
            } else if let other = try? await lane.collector.value {
                d = other
            } else {
                continue
            }
            d.locales = lane.engine.selectedLocales
            drafts.append(d)
        }
        // English is lane 0 under Detect; a lone lane is the answer as it stands.
        var draft = drafts.count == 2 && Self.prefersSpanish(drafts[1].text) ? drafts[1] : drafts[0]
        // A detector failure must not take the transcript with it.
        draft.pauses = (try? await pauseCollector?.value) ?? []
        return draft
    }

    /// **Two seconds, against a healthy delivery of under one millisecond.** Every
    /// run that completed did so in 0–1 ms after finalize returned; the slow part
    /// is finalizing itself, which is already over by the time this starts. The
    /// grace is three orders of magnitude clear of the observed normal, so it
    /// cannot expire on a working recording, and a wedged one costs the user two
    /// seconds instead of a relaunch.
    private static let resultGrace = Duration.seconds(2)

    /// Only reachable from `finish()`'s grace, and only once the sequences have
    /// outlived the analyzer feeding them. Whatever the collectors accumulated is
    /// kept — ending the sequence lets `drain` return normally.
    private func endSequencesThatOutlivedTheAnalyzer() async {
        log.error("Result sequences did not end after finalize; cancelling the collectors.")
        // **Cancelling the drains is what unblocks `finish()`, and it has to come
        // first.** `cancelAndFinishNow()` alone was tried and does not work — the
        // grace fired, the call was made, and the collectors stayed suspended
        // anyway (measured 2026-08-24, 4 of 5 rounds still wedged). It is still
        // called, because leaving an analyzer unfinished is worse than calling it,
        // but it is called *after* the cancels so that a hang inside it cannot
        // take the recovery with it.
        lanes.forEach { $0.collector.cancel() }
        pauseCollector?.cancel()
        feeder?.cancel()
        for lane in lanes { await lane.analyzer.cancelAndFinishNow() }
    }

    /// Escape priority 2 (§10.4). Throws away whatever has been transcribed —
    /// cancelling a transcription is not a request for a partial one.
    func cancel() async {
        feeder?.cancel()
        for lane in lanes { await lane.analyzer.cancelAndFinishNow() }
        lanes.forEach { $0.collector.cancel() }
        pauseCollector?.cancel()
        teardown()
    }

    private func teardown() {
        lanes = []
        feeder?.cancel()
        feeder = nil
        pauseCollector = nil
        detector = nil
    }

    // MARK: - File helpers

    /// The source itself when the analyzer accepts its format, else a
    /// same-content temp file at the analyzer's format. The caller deletes the
    /// temp file; comparing sample rate and channels is the whole gate, because
    /// those are what make an analyzer reject an input.
    private static func analysisFile(for source: URL, target: AVAudioFormat) throws -> URL {
        let file = try AVAudioFile(forReading: source)
        let actual = file.processingFormat
        if actual.sampleRate == target.sampleRate,
           actual.channelCount == target.channelCount
        {
            return source
        }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("caf")
        guard let converter = AVAudioConverter(from: actual, to: target) else {
            return source
        }
        let out = try AVAudioFile(
            forWriting: temp,
            settings: target.settings,
            commonFormat: target.commonFormat,
            interleaved: target.isInterleaved
        )
        file.framePosition = 0
        while file.framePosition < file.length {
            let remaining = file.length - file.framePosition
            let capacity = AVAudioFrameCount(min(remaining, 480_000))
            guard let input = AVAudioPCMBuffer(pcmFormat: actual, frameCapacity: capacity) else { break }
            try file.read(into: input)
            guard input.frameLength > 0 else { break }
            guard let converted = AVAudioPCMBuffer(
                pcmFormat: target,
                frameCapacity: AVAudioFrameCount(Double(input.frameLength) * target.sampleRate / actual.sampleRate + 16)
            ) else { break }
            var consumed = false
            var convertError: NSError?
            converter.convert(to: converted, error: &convertError) { _, status in
                if consumed {
                    status.pointee = .noDataNow
                    return nil
                }
                consumed = true
                status.pointee = .haveData
                return input
            }
            if convertError != nil { break }
            try out.write(from: converted)
        }
        return temp
    }

    /// Whole file as buffers, in segments so an hour-long import never asks for
    /// one giant buffer. The caller feeds these to the Opus write.
    private static func readFully(_ file: AVAudioFile) throws -> [AVAudioPCMBuffer] {
        file.framePosition = 0
        var buffers: [AVAudioPCMBuffer] = []
        while file.framePosition < file.length {
            let remaining = file.length - file.framePosition
            let capacity = AVAudioFrameCount(min(remaining, 480_000))
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: capacity
            ) else { break }
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            buffers.append(buffer)
        }
        return buffers
    }

    // MARK: - The two transcribers

    /// `SpeechTranscriber` or `DictationTranscriber`, and the only place the
    /// difference is visible. **`DictationTranscriber` returns no punctuation and
    /// no capitalisation** — §3.1's cleanup pass supplies both, which is why the
    /// fallback path depends on cleanup harder than the primary one does.
    private enum Engine {
        case speech(SpeechTranscriber)
        case dictation(DictationTranscriber)

        var module: any SpeechModule {
            switch self {
            case .speech(let m): m
            case .dictation(let m): m
            }
        }

        /// Read from the live module rather than from `Kind`'s stored locale: the
        /// framework is the authority on what it resolved to, and `selectedLocales`
        /// is where it says so.
        var selectedLocales: [String] {
            switch self {
            case .speech(let m): m.selectedLocales.map(\.identifier)
            case .dictation(let m): m.selectedLocales.map(\.identifier)
            }
        }

        func collect() async throws -> Draft {
            switch self {
            case .speech(let m): try await Transcription.drain(m.results)
            case .dictation(let m): try await Transcription.drain(m.results)
            }
        }
    }

    /// Which transcriber and which locale — the part of the answer that is worth
    /// resolving once, as against the module, which is worth resolving never.
    private enum Kind {
        case speech(Locale)
        case dictation(Locale)

        var locale: Locale {
            switch self {
            case .speech(let l), .dictation(let l): l
            }
        }

        var label: String {
            switch self {
            case .speech: "SpeechTranscriber"
            case .dictation: "DictationTranscriber"
            }
        }

        func makeEngine() -> Engine {
            switch self {
            case .speech(let locale):
                // `.audioTimeRange` is the only attribute asked for.
                // `.volatileResults` is deliberately absent: the live guess it
                // reports is §4's deleted live transcript layer, and only the
                // finalized path is in scope.
                .speech(SpeechTranscriber(
                    locale: locale,
                    transcriptionOptions: [],
                    reportingOptions: [],
                    attributeOptions: [.audioTimeRange]
                ))
            case .dictation(let locale):
                .dictation(DictationTranscriber(locale: locale, preset: .timeIndexedLongDictation))
            }
        }
    }

    /// `SpeechTranscriber` first — it is the one with native punctuation and
    /// capitalisation. `DictationTranscriber`'s 54 locales are what make a
    /// non-Apple backend unnecessary in v1, and every locale probed where
    /// `SpeechTranscriber` said `.unsupported` came back supported there.
    private func resolve(_ locale: Locale) async throws -> Kind {
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            return .speech(match)
        }
        if let match = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            return .dictation(match)
        }
        throw Failure.noSupportedLocale(locale)
    }

    /// Accumulate finalized results. Generic over the module's result type because
    /// the two transcribers publish different ones; `text` is all either is asked
    /// for, and `isFinal` is what drops the volatile spans nothing here wants.
    private static func drain<S: AsyncSequence>(_ results: S) async throws -> Draft
    where S.Element: SpeechModuleResult & Textual {
        var draft = Draft(text: "", words: [], pauses: [])
        for try await result in results where result.isFinal {
            let text = result.text
            draft.text += String(text.characters)
            for run in text.runs {
                guard let range = run.audioTimeRange else { continue }
                let word = String(text[run.range].characters)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !word.isEmpty else { continue }
                // Start only. The seek offset ships at zero — landing half a
                // second early is pre-roll, not error (§9.3).
                draft.words.append(.init(text: word, start: range.start.seconds))
            }
        }
        draft.text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return draft
    }

    /// Silence ranges from `SpeechDetector`. Anything under 80 ms is treated as
    /// a flap, not a pause cleanup would want.
    private static func collectPauses(_ detector: SpeechDetector) async throws -> [Draft.Pause] {
        var pauses: [Draft.Pause] = []
        for try await result in detector.results where result.isFinal && !result.speechDetected {
            let duration = result.range.duration.seconds
            guard duration >= 0.08 else { continue }
            pauses.append(.init(start: result.range.start.seconds, duration: duration))
        }
        return pauses
    }
}

/// The one member the two transcribers' results share that `SpeechModuleResult`
/// does not declare. Three lines instead of two copies of `drain`.
nonisolated protocol Textual {
    var text: AttributedString { get }
}

nonisolated extension SpeechTranscriber.Result: Textual {}
nonisolated extension DictationTranscriber.Result: Textual {}
