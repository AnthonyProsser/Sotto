//
//  GestureRecognizerTests.swift
//  SottoTests
//
//  Slice 2. §4.1's state machine, driven by hand with a fake clock: `after` is
//  the recognizer's only time seam, so the tests own it.
//

import Foundation
import Testing
@testable import Sotto

private final class Harness {
    let recognizer = GestureRecognizer()
    private(set) var signals: [GestureSignal] = []
    private var now: TimeInterval = 0
    private var pending: [(due: TimeInterval, body: () -> Void)] = []
    private(set) var delays: [TimeInterval] = []

    init() {
        recognizer.after = { [unowned self] delay, body in
            delays.append(delay)
            pending.append((now + delay, body))
        }
        recognizer.emit = { [unowned self] in signals.append($0) }
    }

    /// Fires every timer that falls due, in order, exactly as the runloop would.
    func advance(_ seconds: TimeInterval) {
        let target = now + seconds
        while let index = pending.indices.filter({ pending[$0].due <= target })
            .min(by: { pending[$0].due < pending[$1].due }) {
            let next = pending.remove(at: index)
            now = next.due
            next.body()
        }
        now = target
    }

    @discardableResult
    func send(_ input: GestureRecognizer.Input) -> GestureRecognizer.Disposition {
        recognizer.handle(input)
    }

    func take() -> [GestureSignal] {
        defer { signals = [] }
        return signals
    }
}

private let hold = GestureRecognizer.holdThreshold
private let window = GestureRecognizer.secondTapWindow

struct GestureRecognizerTests {

    // MARK: - Hold (push to talk)

    @Test func holdPastThresholdStartsAndReleaseStops() {
        let h = Harness()
        h.send(.rightOptionDown)
        #expect(h.take() == [.arm])
        #expect(h.delays == [hold])

        h.advance(hold + 0.01)
        #expect(h.take() == [.pushToTalk])

        h.send(.rightOptionUp)
        #expect(h.take() == [.stop])
    }

    @Test func nothingIsConsumedBeforeTheThreshold() {
        let h = Harness()
        #expect(h.send(.rightOptionDown) == .pass)
        // Option+e and the other dead keys still reach the app while unclassified.
        #expect(h.send(.otherKeyDown(isEscape: false)) == .pass)
    }

    @Test func holdConsumesOtherKeysAndReleaseAlwaysPasses() {
        let h = Harness()
        h.send(.rightOptionDown)
        h.advance(hold + 0.01)
        _ = h.take()

        #expect(h.send(.otherKeyDown(isEscape: false)) == .swallow)
        #expect(h.send(.otherKeyUp) == .swallow)
        #expect(h.take().isEmpty) // A key during a live hold is swallowed, not an abort.
        // Swallowing the release would leave every app believing Option is held.
        #expect(h.send(.rightOptionUp) == .pass)
        #expect(h.take() == [.stop])
    }

    // MARK: - Tap, double-tap, latch

    @Test func shortTapDisarmsAndNeverDictates() {
        let h = Harness()
        h.send(.rightOptionDown)
        h.advance(0.1)
        h.send(.rightOptionUp)
        h.advance(window + 0.05)
        #expect(h.take() == [.arm, .disarm])
        #expect(h.delays == [hold, window])
    }

    @Test func expiredWindowStartsAFreshGestureNotALatch() {
        let h = Harness()
        h.send(.rightOptionDown); h.advance(0.05); h.send(.rightOptionUp)
        h.advance(window + 0.05)
        h.send(.rightOptionDown)
        #expect(h.take() == [.arm, .disarm, .arm])
    }

    @Test func doubleTapLatchesAndThirdTapStops() {
        let h = Harness()
        h.send(.rightOptionDown); h.advance(0.05); h.send(.rightOptionUp)
        h.advance(0.1)
        h.send(.rightOptionDown)
        #expect(h.take() == [.arm, .disarm, .latched])

        h.send(.rightOptionUp) // Releasing the second tap does not stop the latch.
        h.advance(5)
        #expect(h.take().isEmpty)

        h.send(.rightOptionDown); h.advance(0.05); h.send(.rightOptionUp)
        #expect(h.take() == [.stop])
    }

    @Test func chordDuringLatchedTapIsNotAStop() {
        let h = Harness()
        h.send(.rightOptionDown); h.advance(0.05); h.send(.rightOptionUp)
        h.send(.rightOptionDown)
        _ = h.take()

        h.send(.rightOptionDown)
        h.send(.otherKeyDown(isEscape: false)) // Option+something
        h.send(.rightOptionUp)
        #expect(h.take().isEmpty)

        h.send(.rightOptionDown); h.send(.rightOptionUp)
        #expect(h.take() == [.stop]) // Still latched, and a plain tap still stops it.
    }

    // MARK: - Chords abort

    @Test func chordWhileArmedAbortsAndTheReleaseIsInert() {
        let h = Harness()
        h.send(.rightOptionDown)
        #expect(h.send(.otherKeyDown(isEscape: false)) == .pass)
        h.advance(hold + 0.1) // The threshold timer must be dead: no late PUSH_TO_TALK.
        h.send(.rightOptionUp)
        h.advance(window + 0.1)
        #expect(h.take() == [.arm, .abort])
    }

    @Test func chordInTheSecondTapWindowAborts() {
        let h = Harness()
        h.send(.rightOptionDown); h.advance(0.05); h.send(.rightOptionUp)
        h.send(.otherKeyDown(isEscape: false))
        h.send(.rightOptionDown) // Idle again, so this is a fresh press.
        #expect(h.take() == [.arm, .disarm, .abort, .arm])
    }

    // MARK: - Escape (priority 1)

    @Test(arguments: ["armed", "holding", "awaitingSecond", "latched", "latchedTap"])
    func escapeAbortsEveryLiveState(state: String) {
        let h = Harness()
        switch state {
        case "armed": h.send(.rightOptionDown)
        case "holding": h.send(.rightOptionDown); h.advance(hold + 0.01)
        case "awaitingSecond": h.send(.rightOptionDown); h.advance(0.05); h.send(.rightOptionUp)
        case "latched":
            h.send(.rightOptionDown); h.advance(0.05); h.send(.rightOptionUp); h.send(.rightOptionDown)
            h.send(.rightOptionUp)
        default: // latchedTap
            h.send(.rightOptionDown); h.advance(0.05); h.send(.rightOptionUp); h.send(.rightOptionDown)
            h.send(.rightOptionUp); h.send(.rightOptionDown)
        }
        _ = h.take()

        // Escape is the one key a hold does not swallow (§10.5).
        #expect(h.send(.otherKeyDown(isEscape: true)) == .pass)
        #expect(h.take() == [.abort])

        // Disarmed for good: releasing the key must not stop or restart anything.
        h.send(.rightOptionUp)
        h.advance(window + hold)
        #expect(h.take().isEmpty)
    }

    @Test func escapeWithNoGestureEmitsNothing() {
        // Nothing for priority 1 to do, so `EventTap` falls through to priority 2
        // (cancel transcription). The fall-through depends on this staying silent.
        let h = Harness()
        #expect(h.send(.otherKeyDown(isEscape: true)) == .pass)
        #expect(h.take().isEmpty)
    }

    @Test func escapeAfterAHoldAbortedCannotAlsoBeAStop() {
        let h = Harness()
        h.send(.rightOptionDown); h.advance(hold + 0.01)
        h.send(.otherKeyDown(isEscape: true))
        h.send(.rightOptionUp)
        #expect(h.take() == [.arm, .pushToTalk, .abort]) // No .stop.
    }

    // MARK: - Escape (priority 2)

    /// The arbiter itself (`EventTap.handle`) needs a live CGEventTap and is a
    /// manual check. What is testable without one: priority 2 declines when no
    /// transcription is in flight, which is what stops a bare Escape from doing
    /// anything to an idle Sotto.
    @Test @MainActor func cancelTranscriptionDeclinesWhenNothingIsInFlight() {
        #expect(Dictation.shared.cancelTranscription() == false)
    }
}
