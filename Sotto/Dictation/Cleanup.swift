//
//  Cleanup.swift
//  Sotto
//
//  Slice 3 leaves the seam; slice 11 fills it — DECISIONS.md, 2026-08-19.
//

import FoundationModels
import os

/// **The prewarm seam, and nothing else yet.** §4.6's cleanup pass belongs to
/// slice 11; what belongs here is the warm-up, because the gesture is slice 2/3
/// and without this file slice 11 would reach back into gesture handling to add
/// it.
///
/// **Why it exists at all:** measured on the reference machine, the first request
/// after launch costs ~3.5 s and every request after it ~850 ms. Un-prewarmed,
/// the first dictation of every session pays that 3.5 s in the gap between
/// speaking and seeing text — the one place latency is decisive.
///
/// **Cleanup owns this session and never shares chat's.** Reusing a single
/// `LanguageModelSession` for two simultaneous requests throws `concurrentRequests`
/// deterministically; two distinct sessions both complete. There is no parallel
/// speedup either way — the model serialises underneath.
///
/// **Prewarming is never an `Activity` contributor.** The icon reports that Sotto
/// is awake (§14.8), and a speculative warm-up the user did not ask for is not
/// that. `Activity.Contributor.cleanup` is set when a pass actually runs, which
/// is slice 11's line to write.
@MainActor
final class Cleanup {
    static let shared = Cleanup()

    private let log = Logger(subsystem: "com.anthonyprosser.Sotto", category: "cleanup")

    /// **`.permissiveContentTransformations`, not the default set.** The default
    /// guardrails refuse on the user's own dictated content, and an app that
    /// declines to punctuate what someone just said because it contained
    /// profanity or a medical term is not a dictation app.
    private let model = SystemLanguageModel(
        useCase: .general,
        guardrails: .permissiveContentTransformations
    )

    private var session: LanguageModelSession?

    private init() {}

    /// Fired from `Dictation.prepare()` half a second after launch, alongside the
    /// HUD and audio warm-ups (`DECISIONS.md`, 2026-08-23).
    ///
    /// **Earlier than the seam originally asked for.** It fired from the gesture
    /// until 2026-08-23, when measurement put first contact with the model at
    /// ~43 ms on the cold path — small beside the audio costs beside it, but paid
    /// for nothing, since nothing about it needs the gesture to have happened.
    ///
    /// **Unavailable is not a failure and never reaches the HUD** (`DECISIONS.md`,
    /// 2026-08-19). `availability` is a configuration state, knowable before the
    /// gesture fires, and it routes to Settings → Dictation with a banner naming
    /// the reason. That pane arrives with slice 11; until then this logs and the
    /// dictation proceeds uncleaned, which is what §8.1's cleanup-off profile does
    /// anyway.
    func prewarm() {
        guard case .available = model.availability else {
            log.notice("Cleanup model unavailable: \(String(describing: self.model.availability), privacy: .public)")
            return
        }
        let session = session ?? LanguageModelSession(model: model)
        self.session = session
        session.prewarm()
    }
}
