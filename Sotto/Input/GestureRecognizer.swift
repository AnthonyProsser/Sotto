//
//  GestureRecognizer.swift
//  Sotto
//
//  Slice 2. The §4.1 state machine.
//

import Foundation

/// Everything slice 2 produces. Each is a log line today: slice 3 gives the first
/// four bodies and slice 9 gives `overlay` one.
enum GestureSignal: String {
    /// Right Cmd went down and nothing is classified yet. Slice 3 opens the
    /// microphone speculatively on this, so that a hold that becomes a dictation
    /// already has the lead-in audio the user spoke over the 250 ms threshold.
    /// **It is not a recording** — `disarm` throws the audio away.
    case arm = "ARM"
    /// The armed window ended without becoming a dictation.
    case disarm = "DISARM"
    case pushToTalk = "PUSH_TO_TALK"
    case latched = "LATCHED"
    case stop = "STOP"
    case abort = "ABORT"
    case overlay = "OVERLAY"
}

/// §4.1's state machine, and nothing else — no Core Graphics, no tap, no I/O.
///
/// **It cannot know what you typed.** `EventTap` does the keycode comparison and hands
/// this type `otherKeyDown(isEscape:)`, a single Bool. An ordinary key's code never
/// crosses this boundary, which is what makes §2.4's privacy claim checkable by reading
/// one file instead of chasing a value through two.
///
/// It runs on the tap thread and is touched from no other, which is why it holds no
/// lock. `after` and `emit` must both be assigned from that thread before the first
/// event arrives — see `EventTap.run()`.
final class GestureRecognizer {
    /// What the tap should do with the event that produced this transition.
    enum Disposition { case pass, swallow }

    enum Input {
        case rightCommandDown, rightCommandUp
        case rightOptionDown
        case otherKeyDown(isEscape: Bool)
        case otherKeyUp
    }

    /// §4.1's two numbers. The build order says outright to expect both to move once
    /// Anthony has lived with them, so they are named rather than inline.
    static let holdThreshold: TimeInterval = 0.250
    static let secondTapWindow: TimeInterval = 0.300

    /// Fire `body` once after `delay`, **on the tap thread's runloop**. Scheduled from
    /// any other thread the timer is added to a runloop nobody runs and silently never
    /// fires, which is why `EventTap` assigns this from inside `run()`.
    var after: (TimeInterval, @escaping () -> Void) -> Void = { _, _ in }

    var emit: (GestureSignal) -> Void = { _ in }

    private enum State {
        case idle
        /// Right Cmd is down and under the hold threshold — still unclassified.
        case armed
        /// Crossed the threshold with the key still down. This is the only state that
        /// consumes, and the whole of what "consumed" means.
        case pushToTalk
        /// Released under the threshold; the second-tap window is open.
        case awaitingSecond
        case latched
        /// Right Cmd down again during a latched session: a stop on release, unless a
        /// chord arrives first and reveals it was Cmd+something.
        case latchedTap
        /// Aborted while the key is still physically down. Its release does nothing —
        /// §4.1's "the user should never have to think about how to let go."
        case spent
    }

    /// A scheduled timer is cancelled by outliving its generation rather than by being
    /// retained and invalidated: one `Int` against a stored `CFRunLoopTimer` per
    /// transition plus the bookkeeping to match them up.
    private var generation = 0
    private var state: State = .idle {
        didSet { generation &+= 1 }
    }

    private var lastRightOptionDown: TimeInterval = -.infinity

    func handle(_ input: Input) -> Disposition {
        switch input {
        case .rightCommandDown:
            return rightCommandDown()
        case .rightCommandUp:
            return rightCommandUp()
        case .rightOptionDown:
            return rightOptionDown()
        case .otherKeyDown(let isEscape):
            return otherKeyDown(isEscape: isEscape)
        case .otherKeyUp:
            // Delivering a keyUp whose keyDown was swallowed leaves the app holding a
            // key that never went down.
            return state == .pushToTalk ? .swallow : .pass
        }
    }

    // MARK: - Right Cmd

    private func rightCommandDown() -> Disposition {
        // A Cmd tap between two Option taps means they were not a double-tap.
        lastRightOptionDown = -.infinity

        switch state {
        case .idle:
            state = .armed
            emit(.arm)
            expire(after: Self.holdThreshold) { [self] in
                state = .pushToTalk
                emit(.pushToTalk)
            }
        case .awaitingSecond:
            state = .latched
            emit(.latched)
        case .latched:
            state = .latchedTap
        case .armed, .pushToTalk, .latchedTap, .spent:
            break // A press we already have down: auto-repeat, or a release we missed.
        }

        // **Never consumed here.** Consumption starts at the threshold, which is what
        // leaves Right-Cmd+C working (DECISIONS.md, 2026-08-15).
        return .pass
    }

    private func rightCommandUp() -> Disposition {
        switch state {
        case .armed:
            state = .awaitingSecond
            // **Released under the threshold, so the microphone closes now rather
            // than at the end of the second-tap window** (Anthony, 2026-08-24).
            // Nobody speaks during a double-tap, so there is no audio in that
            // window worth keeping, and stopping here halves the worst case a
            // press that never becomes a dictation can hold the device open.
            emit(.disarm)
            expire(after: Self.secondTapWindow) { [self] in
                state = .idle // Window closed with no second tap: discard, say nothing.
            }
        case .pushToTalk, .latchedTap:
            state = .idle
            emit(.stop)
        case .spent:
            state = .idle // The inert release Escape and the chord rule both promise.
        case .idle, .awaitingSecond, .latched:
            break
        }

        // **Always passes**, including out of `pushToTalk`. Swallowing this one event
        // leaves every app on the machine believing Cmd is still held, with nothing
        // later to correct it.
        return .pass
    }

    // MARK: - Everything else

    private func otherKeyDown(isEscape: Bool) -> Disposition {
        lastRightOptionDown = -.infinity

        if isEscape {
            switch state {
            case .armed, .pushToTalk, .latchedTap:
                emit(.abort)
                state = .spent
            case .awaitingSecond, .latched:
                emit(.abort)
                state = .idle
            case .idle, .spent:
                break
            }
            // Escape is the one key a hold does not swallow, which is what keeps
            // Cmd+Opt+Esc reachable while a gesture is in flight (§10.5).
            return .pass
        }

        switch state {
        case .armed:
            emit(.abort) // A chord. Discard, pass through, and disarm.
            state = .spent
        case .awaitingSecond:
            emit(.abort)
            state = .idle
        case .pushToTalk:
            // The hold owns the keyboard until it ends (DECISIONS.md, 2026-08-15).
            return .swallow
        case .latchedTap:
            state = .latched // Cmd+something during a latched session is not a stop.
        case .idle, .latched, .spent:
            break
        }
        return .pass
    }

    // MARK: - Right Option

    private func rightOptionDown() -> Disposition {
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastRightOptionDown <= Self.secondTapWindow {
            lastRightOptionDown = -.infinity
            emit(.overlay)
        } else {
            lastRightOptionDown = now
        }
        // Right Option is never consumed. The consumption rule exists because one key
        // was doing two jobs while recording, and nothing here records.
        return .pass
    }

    // MARK: -

    /// Run `body` after `delay` unless the state has moved on since.
    private func expire(after delay: TimeInterval, _ body: @escaping () -> Void) {
        let scheduled = generation
        after(delay) { [self] in
            guard generation == scheduled else { return }
            body()
        }
    }
}
