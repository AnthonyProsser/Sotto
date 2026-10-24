//
//  Dictation.swift
//  Sotto
//
//  Slice 3. The pipeline the gesture drives — sotto-spec.md §3, §4.4–§4.9.
//

import AVFoundation
import AppKit
import Speech
import os

/// Capture → transcribe → insert, and the HUD and the idle signal along the way.
/// `EventTap.route` calls the four methods below and nothing else does.
///
/// **Dictation always dumps at the end** (§4.4). Nothing is inserted while
/// speaking; live-streaming insertion was cut from v1 entirely.
///
/// **Microphone-rate capture may overlap Foundation Models freely.** STT and the
/// LLM share the ANE, but at 1× realtime the measured cost to a cleanup pass is
/// +5 %, inside run-to-run drift. The serialisation rule is import-rate work's
/// (slice 14), not this file's.
@MainActor
final class Dictation {
    static let shared = Dictation()

    private let log = Logger(subsystem: "com.anthonyprosser.Sotto", category: "dictation")

    /// The analyzer's preferred format, resolved once at launch so that starting a
    /// recording is synchronous. An `await` here would put an actor hop between
    /// the key-down and the first sample, and the first word is the one that gets
    /// clipped.
    private var audioFormat: AVAudioFormat?

    /// **One task per dictation, from `start()` to the HUD's last word** (2026-10-23).
    /// It used to be two — `start()`'s analyzer start and `stop()`'s finish — and
    /// the first could put "Transcription failed" on screen while the second was
    /// inserting. One task has one ending: an error, or an insertion, never both.
    private var pipeline: Task<Void, Never>?

    /// A cancelled pipeline still tearing its analyzers down. The next one waits
    /// for it, because `Transcription` is shared: a teardown landing after the
    /// next `begin` emptied that dictation's lanes, and its finish then failed
    /// with "Transcription unavailable".
    private var settling: Task<Void, Never>?

    /// `stop()` finishes this; the pipeline waits on it between `begin` and `finish`.
    private var release: AsyncStream<Void>.Continuation?

    /// The capture stream opened speculatively on key-down, held until the gesture
    /// says what it was. **Nothing reads it while it sits here** — `AsyncStream` is
    /// unbounded, so the buffers queue and the whole armed window flows into the
    /// transcriber the moment `start()` hands the stream over.
    private var armed: AsyncStream<AnalyzerInput>?

    /// **Live between `start()` and `stop()`, and `pipeline` cannot stand in for
    /// it.** `pipeline` is also non-nil through the transcription tail, so a
    /// release landing in that tail passed `stop()`'s guard and issued a second
    /// `finalizeAndFinishThroughEndOfInput()` against an analyzer that was already
    /// finalizing — measured 2026-08-24, two `finish` entries on one analyzer from
    /// one gesture pair 40 ms apart. The tail belongs to the gesture that started
    /// it; a later gesture must not be able to re-enter it.
    private var capturing = false

    private init() {}

    // MARK: - Launch

    func prepare() {
        AudioCapture.shared.onLevel = { level in
            Task { @MainActor in HUDPanel.shared.level(level) }
        }
        Task {
            await Transcription.shared.prepare()
            audioFormat = await Transcription.shared.audioFormat()
        }

        // **First-touch costs, moved off the first gesture.** Each of these is
        // paid once per launch wherever it happens; measured cold they were
        // ~107 ms of window creation, ~241 ms of first render, ~43 ms of first
        // contact with the cleanup model, and ~309 ms of reaching CoreAudio and
        // bringing the input node up — together most of the cold path.
        //
        // **On the main actor, half a second in, not on a background queue.**
        // `start()` runs here too, and `AVAudioEngine`'s graph is not safe to
        // mutate from two threads at once; a gesture landing mid-warm-up queues
        // behind it and pays a cost it was going to pay anyway. The delay is so
        // the status item and the tap are up first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            HUDPanel.shared.warm()
            Cleanup.shared.prewarm()
            AudioCapture.shared.warm()
        }
    }

    // MARK: - The gesture's signals

    /// **The dictation key went down and nothing is classified yet.** The microphone opens
    /// here and the HUD is composited transparent, so that the ~55 ms of CoreAudio
    /// bring-up and the ~100 ms of buffer fill happen *inside* the 250 ms the user
    /// spends holding the key rather than after it. A hold that becomes a dictation
    /// therefore arrives with the lead-in already captured — the words a fast
    /// speaker used to lose.
    ///
    /// **The transcriber is not touched.** A `SpeechTranscriber` module belongs to
    /// one `SpeechAnalyzer` for its lifetime and building one costs real work; a
    /// speculative analyzer on every key press is not a trade worth making.
    /// The stream is held instead, and handed over at `start()`.
    ///
    /// **It cannot raise the microphone prompt.** §2.4 asks at first use of the
    /// feature, and an unclassified key-down is not that — a bare key press would
    /// otherwise put the TCC dialog on screen, and `engine.start()` blocks its
    /// caller until that dialog is answered. Unauthorized, this does nothing and
    /// the real gesture asks, exactly as before.
    func arm() {
        guard pipeline == nil, armed == nil, AudioCapture.isAuthorized else { return }
        Insertion.wakeElectronAccessibility()
        HUDPanel.shared.prepare(.recording(level: 0))
        do {
            armed = try AudioCapture.shared.start(analyzerFormat: audioFormat)
        } catch {
            // Silent on purpose. Nothing has been classified, so there is nothing
            // to report yet; `start()` opens the microphone itself and surfaces the
            // failure there if the gesture turns out to be real.
            armed = nil
            HUDPanel.shared.hide()
        }
    }

    /// A latched dictation stops itself after this long with no finalized word.
    /// Pressing the key again is still the ordinary stop.
    private static let latchedSilence = Duration.seconds(60)

    func start(latched: Bool) {
        guard pipeline == nil else {
            // A double-tap during the last dictation's tail starts nothing, so its
            // latch must not wait for a stop tap that would stop nothing.
            if latched { EventTap.shared.endLatch() }
            return
        }
        let started = ContinuousClock.now

        Activity.shared.set(.recording, true)
        // Already on screen and composited if the armed window ran; this is the
        // alpha change and nothing else.
        HUDPanel.shared.show(.recording(level: 0))

        let stream: AsyncStream<AnalyzerInput>
        if let armed {
            // The hold path. Capture has been running since key-down and the
            // buffered prefix is still in the stream.
            stream = armed
            self.armed = nil
        } else {
            // The latch path, and the first-run permission path. The second tap
            // closed the microphone under Anthony's ruling, so it opens here.
            do {
                stream = try AudioCapture.shared.start(analyzerFormat: audioFormat)
            } catch {
                log.error("Capture failed: \(error.localizedDescription, privacy: .public)")
                // A `nil` message is the permission-prompt case: the question is on
                // screen, and a HUD error behind it would be Sotto complaining about
                // something the user is in the middle of answering.
                if latched { EventTap.shared.endLatch() }
                finish(with: Self.message(for: error).map(HUDState.error))
                return
            }
        }

        capturing = true
        let (released, release) = AsyncStream<Void>.makeStream()
        self.release = release
        let previous = settling
        settling = nil

        pipeline = Task { [stream] in
            await previous?.value
            let state: HUDState?
            do {
                state = try await dictate(stream, released: released, latched: latched, started: started)
            } catch {
                // Whatever the analyzers were doing, they stop here — a `begin`
                // that threw halfway leaves a lane running, and a cancelled
                // pipeline is the one the next `start()` is waiting on.
                await Transcription.shared.cancel()
                // **A cancelled pipeline is not a failed one, and owns nothing
                // any more.** `abort` and `cancelTranscription` have finished the
                // HUD and discarded the audio; a capture running now belongs to
                // the next dictation.
                guard !Task.isCancelled else { return }
                AudioCapture.shared.discardRecording()
                // Not cancelled means still the current pipeline — nothing clears
                // `pipeline` without cancelling it — so `capturing` is this one's:
                // still set, the latch is ours and the user never tapped to end it.
                if latched && capturing { EventTap.shared.endLatch() }
                log.error("Transcription failed: \(error.localizedDescription, privacy: .public)")
                state = Self.message(for: error).map(HUDState.error)
            }
            guard !Task.isCancelled else { return }
            finish(with: state)
        }
    }

    /// The gesture ended. Capture stops, and the pipeline `start()` began
    /// finalizes and sends the text wherever §3 and §4.9 say.
    func stop() {
        guard capturing else { return }
        capturing = false
        AudioCapture.shared.stop()
        // The HUD stays up through transcription: it is the surface that reports
        // the failure if one happens, and a HUD that vanished at the release would
        // have nowhere to say so.
        HUDPanel.shared.show(.transcribing)
        release?.finish()
        release = nil
    }

    /// Escape priority 1, a chord that revealed the gesture was Cmd+something
    /// (§4.1), or the release that ended an armed window without classifying it.
    /// Discard the audio and insert nothing — the HUD fades with no message,
    /// because an abort is not news.
    ///
    /// **One discard path, and this is it.** `disarm` routes here rather than
    /// growing a second one; the difference between the two cases is only which of
    /// `pipeline` and `armed` was live, and `cancelPipeline` already handles both.
    ///
    /// **Only while the microphone is open.** A tap during the last dictation's
    /// tail still disarms, and cancelling that tail would throw away text the
    /// user finished speaking; Escape priority 2 is the way to do that.
    func abort() {
        guard capturing || armed != nil else { return }
        armed = nil
        cancelPipeline()
        finish(with: nil)
    }

    /// **Escape priority 2** (§10.4). Returns whether it fired, so `EventTap` can
    /// resolve the stack: exactly one action per press, and priority 1 has already
    /// had its turn by the time this is called.
    ///
    /// Cancelling throws the transcript away rather than inserting what arrived so
    /// far. A partial transcription is not what the user asked for when they hit
    /// Escape.
    @discardableResult
    func cancelTranscription() -> Bool {
        guard pipeline != nil else { return false }
        cancelPipeline()
        finish(with: nil)
        return true
    }

    // MARK: -

    private func cancelPipeline() {
        capturing = false
        AudioCapture.shared.stop()
        AudioCapture.shared.discardRecording()
        pipeline?.cancel()
        settling = pipeline
        pipeline = nil
    }

    /// The dictation, start to insertion. Returns what the HUD says last.
    ///
    /// **An error and an insertion cannot both happen.** `Insertion.insert` is
    /// the last thing here and nothing after it throws, so a thrown error means
    /// nothing was inserted; and the HUD state comes from the insertion's outcome
    /// and nothing else.
    private func dictate(
        _ stream: AsyncStream<AnalyzerInput>,
        released: AsyncStream<Void>,
        latched: Bool,
        started: ContinuousClock.Instant
    ) async throws -> HUDState? {
        try Task.checkCancellation()
        try await Transcription.shared.begin(stream, language: ProfileStore.shared.active.language)
        let begun = ContinuousClock.now

        let quiet = latched ? Task { await stopWhenQuiet() } : nil
        for await _ in released {}
        quiet?.cancel()
        try Task.checkCancellation()

        let stopped = ContinuousClock.now
        let draft = try await Transcription.shared.finish()
        // Cancelled while finalizing, the capture's buffers may already be the
        // next dictation's: `start()` resets them before that pipeline waits on this one.
        try Task.checkCancellation()
        let finalized = ContinuousClock.now
        let recording = AudioCapture.shared.takeRecording()
        let profile = ProfileStore.shared.active
        var text = draft.text
        var cleaned: String?
        var cleanup = "off"
        if profile.cleanupEnabled, !draft.text.isEmpty {
            let marked = AudioHistory.mark(draft.text, words: draft.words, pauses: draft.pauses)
            do {
                let result = try await Cleanup.shared.clean(marked, profile: profile, locale: draft.locales.first)
                cleanup = "accepted"
                if !result.isEmpty {
                    text = result
                    cleaned = result
                }
            } catch Cleanup.Failure.unavailable {
                // Configuration state, not a failure: the banner in Settings →
                // Dictation owns it, and the dictation proceeds like a
                // cleanup-off profile.
                cleanup = "unavailable"
            } catch {
                // **The raw text goes in and the HUD says nothing** (2026-10-23).
                // A "Cleanup failed" beside text that had just landed read as the
                // dictation failing.
                log.error("Cleanup failed: \(String(describing: error), privacy: .public)")
                cleanup = if case Cleanup.Failure.rejected = error { "rejected" } else { "failed" }
            }
        }
        let cleanedAt = ContinuousClock.now
        try Task.checkCancellation()

        if let recording, !draft.text.isEmpty {
            AudioHistory.record(
                draft: draft,
                buffers: recording.buffers,
                format: recording.format,
                cleaned: cleaned,
                profile: profile.name
            )
        }
        guard !text.isEmpty else {
            log.notice("Nothing transcribed.")
            return nil
        }
        // §3's ladder, and nothing before it.
        //
        // **Selection no longer routes anywhere** (Anthony, 2026-09-18,
        // `DECISIONS.md`). §4.9 sent a dictation made against selected text to the
        // chat draft; chat is gone, so the transcript takes the ordinary path and
        // the AX write replaces whatever was selected. This contradicts §4.9's
        // "selected text is never a dictation target" — his call, logged, and the
        // spec copy is stale on it.
        let outcome = await Insertion.insert(text)
        let done = ContinuousClock.now

        // One line per dictation for the optimization work: where the time went
        // between the release and the text landing. Counts and times, never text.
        log.notice("""
            TIMING recording=\((stopped - started).ms, privacy: .public)ms \
            begin=\((begun - started).ms, privacy: .public)ms \
            finalize=\((finalized - stopped).ms, privacy: .public)ms \
            cleanup=\((cleanedAt - finalized).ms, privacy: .public)ms(\(cleanup, privacy: .public)) \
            insert=\((done - cleanedAt).ms, privacy: .public)ms(\(String(describing: outcome), privacy: .public)) \
            total=\((done - stopped).ms, privacy: .public)ms \
            words=\(draft.words.count, privacy: .public) chars=\(text.count, privacy: .public) \
            locale=\(draft.locales.first ?? "?", privacy: .public) latched=\(latched, privacy: .public)
            """)

        switch outcome {
        case .inserted: return nil
        case .copied: return .message("Copied to clipboard")
        case .failed(let reason): return .error(reason)
        }
    }

    /// The latched auto-stop: the ordinary `stop()`, once the transcriber has
    /// gone `latchedSilence` without a finalized word. Finalized results come
    /// every few seconds while someone talks and stop when they do, which is a
    /// steadier signal than the microphone level — a fan or a room never trips it.
    private func stopWhenQuiet() async {
        while (try? await Task.sleep(for: .seconds(5))) != nil {
            guard Transcription.shared.quiet >= Self.latchedSilence else { continue }
            guard capturing else { return }
            log.notice("Latched dictation went quiet; stopping.")
            stop()
            // The latch ended without the user's tap; the recognizer must not
            // spend their next tap stopping it.
            EventTap.shared.endLatch()
            return
        }
    }

    /// One exit for every path. `nil` takes the HUD away with no message, which is
    /// §4.5's "fades" for both the inserted and the aborted cases.
    ///
    /// **`.recording` clears here rather than at the gesture's end.** §14.8's
    /// contributor list has no entry for the transcription tail of a dictation —
    /// `fileTranscription` is slice 14's imports — and the icon reporting that
    /// Sotto is awake until the text actually lands is the reading that matches
    /// what the user sees.
    private func finish(with state: HUDState?) {
        pipeline = nil
        armed = nil
        capturing = false
        release = nil
        // **The one exit closes the microphone too.** `finish` is reachable from
        // `start()`'s catch with capture already running — `begin` throwing left
        // the engine live, `pipeline` nil, and the release that followed rejected
        // by `stop()`'s guard, so the device stayed open with no HUD and nothing
        // to close it. `AudioCapture.stop()` is idempotent, so the paths that have
        // already stopped pay nothing.
        AudioCapture.shared.stop()
        Activity.shared.set(.recording, false)

        guard let state else {
            HUDPanel.shared.hide()
            return
        }
        // Long enough to read at a glance from the top of the screen, short
        // enough that it is gone before the next sentence. Errors hold longer
        // because they are the ones worth reading twice (§4.5).
        let hold: TimeInterval = if case .error = state { 3.5 } else { 2 }
        HUDPanel.shared.show(state, thenHideAfter: hold)
    }

    /// Failure strings live where the failure is thrown (§14.3) — there is no
    /// central error vocabulary. This maps the two that come from framework types
    /// rather than from Sotto's own code.
    /// `nil` means "say nothing" — the one case is the microphone prompt, which
    /// is its own surface while it is up.
    private static func message(for error: Error) -> String? {
        guard let localized = error as? LocalizedError else { return "Transcription failed" }
        return localized.errorDescription
    }
}

extension Duration {
    /// Whole milliseconds, for the timing lines in the log.
    var ms: Int {
        let (seconds, attoseconds) = components
        return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
    }
}
