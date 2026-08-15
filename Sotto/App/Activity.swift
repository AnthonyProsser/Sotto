//
//  Activity.swift
//  Sotto
//
//  Slice 1. The idle / not-idle signal from sotto-spec.md §14.8.
//

import Foundation
import Observation

/// **The single source of truth for whether Sotto is awake.** One observable,
/// one contributor list, defined here in slice 1 and fed by six later slices.
///
/// The alternative — each slice raising its own flag — is the failure the build
/// order names outright: seven sources of truth that disagree the first time two
/// of them overlap. A contributor is added to this enum or it does not exist.
///
/// **The icon reports awake, not recording** (§14.8). macOS 26 already draws its
/// own microphone indicator in the same menu bar whenever any app holds the mic,
/// so a recording-specific state would duplicate something the system asserts
/// better. What the system does *not* report is whether Sotto is doing anything
/// at all, and that is the state worth owning. The accepted cost is that a filled
/// icon no longer means "you are still latched."
@Observable
final class Activity {
    static let shared = Activity()

    private init() {}

    /// **§14.8's list, complete and closed.** The slice in each comment is the one
    /// that wires it; only `mainWindow` is wired today. Adding a case is adding to
    /// the spec's list, so it needs the same argument the seven below had.
    enum Contributor: CaseIterable {
        case recording          // slice 3 — either gesture, including latched
        case overlay            // slice 9
        case mainWindow         // slice 1
        case generating         // slice 7 — a chat response in flight
        case fileTranscription  // slice 14
        case cleanup            // slice 11
        case modelLoading       // slice 8
    }

    private(set) var active: Set<Contributor> = []

    var isIdle: Bool { active.isEmpty }

    func set(_ contributor: Contributor, _ isActive: Bool) {
        if isActive {
            active.insert(contributor)
        } else {
            active.remove(contributor)
        }
    }

    /// Calls `body` now and again on every change to `isIdle`.
    ///
    /// `withObservationTracking` fires `onChange` *before* the value is written and
    /// then stops tracking, so the callback hops to the next main-queue turn to read
    /// the new value and re-arm. SwiftUI consumers do not need this — it exists for
    /// the status item, which is AppKit and has no observation of its own.
    func observeIsIdle(_ body: @escaping (Bool) -> Void) {
        withObservationTracking {
            body(isIdle)
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.observeIsIdle(body) }
        }
    }
}
