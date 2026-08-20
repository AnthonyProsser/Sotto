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
    }

    // MARK: - The gesture's four signals

    func start() {
        guard pipeline == nil else { return }

        Activity.shared.set(.recording, true)
        HUDPanel.shared.show(.recording(level: 0))
        // The seam. Slice 11 fills it; firing it here costs nothing and saves the
        // first dictation of every session ~3.5 s.
        Cleanup.shared.prewarm()

        let stream: AsyncStream<AnalyzerInput>
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
        guard pipeline != nil else { return }
        AudioCapture.shared.stop()
        // The waveform stays up through transcription: it is the surface that
        // reports the failure if one happens, and a HUD that vanished at the
        // release would have nowhere to say so. At level 0 it is a row of resting
        // dots, which reads as listening rather than as finished.
        HUDPanel.shared.show(.recording(level: 0))

        pipeline = Task {
            do {
                let draft = try await Transcription.shared.finish()
                deliver(draft)
            } catch {
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

    /// Escape priority 1, or a chord that revealed the gesture was Cmd+something
    /// (§4.1). Discard the audio and insert nothing — the HUD fades with no
    /// message, because an abort is not news.
    func abort() {
        guard pipeline != nil else { return }
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
        AudioCapture.shared.stop()
        pipeline?.cancel()
        pipeline = nil
        Task { await Transcription.shared.cancel() }
    }

    /// §4.9 first, then §3's ladder.
    private func deliver(_ draft: Transcription.Draft) {
        guard !draft.text.isEmpty else {
            log.notice("Nothing transcribed.")
            finish(with: nil)
            return
        }

        // **Selection routes to chat, always** (§4.9) — both gestures, and the
        // gesture does not change the routing. Chat is slice 9, so this is the
        // stub the build order asks for: log and drop, with the branch wired so
        // slice 9 fills a hole rather than adding one. Selected text is never a
        // dictation target; to replace text, delete it first.
        if let selection, !selection.isEmpty {
            log.notice("""
                Routed to chat (slice 9): \(draft.words.count, privacy: .public) words \
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
        selection = nil
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
