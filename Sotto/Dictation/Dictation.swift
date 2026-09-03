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

    /// Live between `start()` and the end of the pipeline it kicks off.
    private var pipeline: Task<Void, Never>?

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

    /// §4.9's routing input, read at the moment the user starts speaking rather
    /// than when they stop: clicking elsewhere to place a cursor deselects, so a
    /// selection read at the end would be a different question.
    private var selection: String?

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

    /// **Right Cmd went down and nothing is classified yet.** The microphone opens
    /// here and the HUD is composited transparent, so that the ~55 ms of CoreAudio
    /// bring-up and the ~100 ms of buffer fill happen *inside* the 250 ms the user
    /// spends holding the key rather than after it. A hold that becomes a dictation
    /// therefore arrives with the lead-in already captured — the words a fast
    /// speaker used to lose.
    ///
    /// **The transcriber is not touched.** A `SpeechTranscriber` module belongs to
    /// one `SpeechAnalyzer` for its lifetime and building one costs real work; a
    /// speculative analyzer on every Right Cmd press is not a trade worth making.
    /// The stream is held instead, and handed over at `start()`.
    ///
    /// **It cannot raise the microphone prompt.** §2.4 asks at first use of the
    /// feature, and an unclassified key-down is not that — a bare Right Cmd would
    /// otherwise put the TCC dialog on screen, and `engine.start()` blocks its
    /// caller until that dialog is answered. Unauthorized, this does nothing and
    /// the real gesture asks, exactly as before.
    func arm() {
        guard pipeline == nil, armed == nil, AudioCapture.isAuthorized else { return }
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

    func start() {
        guard pipeline == nil else { return }

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
                finish(with: Self.message(for: error).map(HUDState.error))
                return
            }
        }

        capturing = true

        // Read after capture is running, not before it: the Cmd+C fallback in
        // `selectedText()` polls the pasteboard for up to 300 ms, and paying that
        // ahead of the first sample would clip the first word. It suspends rather
        // than blocks, so the waveform keeps moving while it waits.
        selection = nil
        Task { selection = await Insertion.selectedText() }

        pipeline = Task { [stream] in
            do {
                try await Transcription.shared.begin(stream)
            } catch {
                guard !Task.isCancelled else { return }
                log.error("Transcriber failed to start: \(error.localizedDescription, privacy: .public)")
                finish(with: Self.message(for: error).map(HUDState.error))
            }
        }
    }

    /// The gesture ended. Capture stops, the analyzer finalizes, and the text goes
    /// wherever §3 and §4.9 send it.
    func stop() {
        guard capturing else { return }
        capturing = false
        AudioCapture.shared.stop()
        // The waveform stays up through transcription: it is the surface that
        // reports the failure if one happens, and a HUD that vanished at the
        // release would have nowhere to say so. At level 0 it is a row of resting
        // dots, which reads as listening rather than as finished.
        HUDPanel.shared.show(.recording(level: 0))

        pipeline = Task {
            do {
                let draft = try await Transcription.shared.finish()
                let recording = AudioCapture.shared.takeRecording()
                deliver(draft)
                if let recording, !draft.text.isEmpty {
                    AudioHistory.record(
                        draft: draft,
                        buffers: recording.buffers,
                        format: recording.format
                    )
                }
            } catch {
                AudioCapture.shared.discardRecording()
                // **A cancelled pipeline is not a failed one.** Escape (either
                // priority) and a chord both cancel this task, and the `await`
                // above then throws `CancellationError` — reported, that puts
                // "Transcription failed" on screen for 3.5 s immediately after
                // the user asked for the opposite. `abort` and
                // `cancelTranscription` have already finished the HUD.
                guard !Task.isCancelled else { return }
                log.error("Transcription failed: \(error.localizedDescription, privacy: .public)")
                finish(with: Self.message(for: error).map(HUDState.error))
            }
        }
    }

    /// Escape priority 1, a chord that revealed the gesture was Cmd+something
    /// (§4.1), or the release that ended an armed window without classifying it.
    /// Discard the audio and insert nothing — the HUD fades with no message,
    /// because an abort is not news.
    ///
    /// **One discard path, and this is it.** `disarm` routes here rather than
    /// growing a second one; the difference between the two cases is only which of
    /// `pipeline` and `armed` was live, and `cancelPipeline` already handles both.
    func abort() {
        guard pipeline != nil || armed != nil else { return }
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
        pipeline = nil
        Task { await Transcription.shared.cancel() }
    }

    /// §4.9 first, then §5.4 overlay dictation, then §3's ladder.
    private func deliver(_ draft: Transcription.Draft) {
        guard !draft.text.isEmpty else {
            log.notice("Nothing transcribed.")
            finish(with: nil)
            return
        }

        // **Overlay dictation fills the bar with an ordinary message (§5.4).**
        // Not automatically about an attached block — just as typed input would be.
        if Activity.shared.active.contains(.overlay) {
            var bar = DraftStore.shared.draft.text
            if !bar.isEmpty && !bar.hasSuffix(" ") && !bar.hasSuffix("\n") { bar += " " }
            bar += draft.text
            DraftStore.shared.draft.text = bar
            // Leave selection attachment path alone — that comes via the + menu / auto-capture, not via this.
            log.notice("Routed dictation to overlay bar: \(draft.words.count, privacy: .public) words.")
            finish(with: nil)
            return
        }

        // **Selection routes to chat, always** (§4.9) — both gestures, and the
        // gesture does not change the routing. Chat is slice 9, so this is the
        // stub the build order asks for: log and drop, with the branch wired so
        // slice 9 fills a hole rather than adding one. Selected text is never a
        // dictation target; to replace text, delete it first.
        if let selection, !selection.isEmpty {
            // Attach selection as chip + transcript as ordinary message in draft.
            let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"
            DraftStore.shared.addSelection(app: app, text: selection)
            var bar = DraftStore.shared.draft.text
            if !bar.isEmpty && !bar.hasSuffix(" ") && !bar.hasSuffix("\n") { bar += " " }
            bar += draft.text
            DraftStore.shared.draft.text = bar
            // Ensure overlay shows so user sees where it went.
            OverlayPanel.shared.show()
            log.notice("""
                Routed to chat draft (slice 9): \(draft.words.count, privacy: .public) words \
                against a \(selection.count, privacy: .public)-character selection.
                """)
            finish(with: nil)
            return
        }

        switch Insertion.insert(draft.text) {
        case .inserted:
            finish(with: nil)
        case .copied:
            finish(with: .message("Copied to clipboard"))
        case .failed(let reason):
            finish(with: .error(reason))
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
        selection = nil
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
