//
//  Transcription.swift
//  Sotto
//
//  Slice 3. Apple's Speech framework, exclusively — DECISIONS.md, 2026-08-19.
//

import AVFoundation
import CoreMedia
import Foundation
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
    private var engine: Engine?
    private var detector: SpeechDetector?
    private var analyzer: SpeechAnalyzer?
    private var collector: Task<Draft, Error>?
    private var pauseCollector: Task<[Draft.Pause], Error>?

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
    func prepare() async {
        do {
            let kind = try await resolve(Locale.current)
            try await AssetInventory.reserve(locale: kind.locale)
            // A module built only to be asked two questions and thrown away; it
            // never meets an analyzer, so the one-analyzer rule above is intact.
            let probe = kind.makeEngine().module
            // Preinstalled. Included so the format we cache is one both
            // modules will accept; a detector-incompatible format would
            // make pause collection fail on every recording.
            let detector = SpeechDetector()
            guard await AssetInventory.status(forModules: [probe]) == .installed else {
                throw Failure.localeNotInstalled(kind.locale)
            }
            format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [probe, detector])
            if format == nil {
                format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [probe])
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

    /// The format the analyzer wants, for `AudioCapture` to convert into.
    func audioFormat() -> AVAudioFormat? { format }

    // MARK: - A recording

    /// Start analysing. Returns as soon as the analyzer is running; the results
    /// accumulate in the background until `finish()` or `cancel()`.
    func begin(_ inputs: AsyncStream<AnalyzerInput>) async throws {
        if kind == nil { await prepare() }
        guard let kind else { throw Failure.notPrepared }

        let engine = kind.makeEngine()
        self.engine = engine
        // Fresh module per recording, same rule as the transcriber. `reportResults`
        // is what fills `results`; the convenience init does not.
        let detector = SpeechDetector(
            detectionOptions: .init(sensitivityLevel: .medium),
            reportResults: true
        )
        self.detector = detector
        let analyzer = SpeechAnalyzer(modules: [engine.module, detector])
        self.analyzer = analyzer
        collector = Task { try await engine.collect() }
        pauseCollector = Task { try await Self.collectPauses(detector) }
        try await analyzer.start(inputSequence: inputs)
    }

    /// Called once the capture stream has finished. `finalizeAndFinishThroughEndOfInput`
    /// is what turns the last volatile span into a finalized result, so the draft
    /// is only complete after it returns.
    func finish() async throws -> Draft {
        defer { teardown() }
        guard let analyzer, let collector else { throw Failure.notPrepared }
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        var draft = try await collector.value
        // A detector failure must not take the transcript with it.
        draft.pauses = (try? await pauseCollector?.value) ?? []
        return draft
    }

    /// Escape priority 2 (§10.4). Throws away whatever has been transcribed —
    /// cancelling a transcription is not a request for a partial one.
    func cancel() async {
        await analyzer?.cancelAndFinishNow()
        collector?.cancel()
        pauseCollector?.cancel()
        teardown()
    }

    private func teardown() {
        analyzer = nil
        collector = nil
        pauseCollector = nil
        engine = nil
        detector = nil
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
