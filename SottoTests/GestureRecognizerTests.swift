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
        h.send(.keyDown)
        #expect(h.take() == [.arm])
        #expect(h.delays == [hold])

        h.advance(hold + 0.01)
        #expect(h.take() == [.pushToTalk])

        h.send(.keyUp)
        #expect(h.take() == [.stop])
    }

    @Test func nothingIsConsumedBeforeTheThreshold() {
        let h = Harness()
        #expect(h.send(.keyDown) == .pass)
        // Option+e and the other dead keys still reach the app while unclassified.
        #expect(h.send(.otherKeyDown(isEscape: false)) == .pass)
    }

    @Test func holdConsumesOtherKeysAndReleaseAlwaysPasses() {
        let h = Harness()
        h.send(.keyDown)
        h.advance(hold + 0.01)
        _ = h.take()

        #expect(h.send(.otherKeyDown(isEscape: false)) == .swallow)
        #expect(h.send(.otherKeyUp) == .swallow)
        #expect(h.take().isEmpty) // A key during a live hold is swallowed, not an abort.
        // Swallowing the release would leave every app believing Option is held.
        #expect(h.send(.keyUp) == .pass)
        #expect(h.take() == [.stop])
    }

    // MARK: - Tap, double-tap, latch

    @Test func shortTapDisarmsAndNeverDictates() {
        let h = Harness()
        h.send(.keyDown)
        h.advance(0.1)
        h.send(.keyUp)
        h.advance(window + 0.05)
        #expect(h.take() == [.arm, .disarm])
        #expect(h.delays == [hold, window])
    }

    @Test func expiredWindowStartsAFreshGestureNotALatch() {
        let h = Harness()
        h.send(.keyDown); h.advance(0.05); h.send(.keyUp)
        h.advance(window + 0.05)
        h.send(.keyDown)
        #expect(h.take() == [.arm, .disarm, .arm])
    }

    @Test func doubleTapLatchesAndThirdTapStops() {
        let h = Harness()
        h.send(.keyDown); h.advance(0.05); h.send(.keyUp)
        h.advance(0.1)
        h.send(.keyDown)
        #expect(h.take() == [.arm, .disarm, .latched])

        h.send(.keyUp) // Releasing the second tap does not stop the latch.
        h.advance(5)
        #expect(h.take().isEmpty)

        h.send(.keyDown); h.advance(0.05); h.send(.keyUp)
        #expect(h.take() == [.stop])
    }

    @Test func chordDuringLatchedTapIsNotAStop() {
        let h = Harness()
        h.send(.keyDown); h.advance(0.05); h.send(.keyUp)
        h.send(.keyDown)
        _ = h.take()

        h.send(.keyDown)
        h.send(.otherKeyDown(isEscape: false)) // Option+something
        h.send(.keyUp)
        #expect(h.take().isEmpty)

        h.send(.keyDown); h.send(.keyUp)
        #expect(h.take() == [.stop]) // Still latched, and a plain tap still stops it.
    }

    // MARK: - Chords abort

    @Test func chordWhileArmedAbortsAndTheReleaseIsInert() {
        let h = Harness()
        h.send(.keyDown)
        #expect(h.send(.otherKeyDown(isEscape: false)) == .pass)
        h.advance(hold + 0.1) // The threshold timer must be dead: no late PUSH_TO_TALK.
        h.send(.keyUp)
        h.advance(window + 0.1)
        #expect(h.take() == [.arm, .abort])
    }

    @Test func chordInTheSecondTapWindowAborts() {
        let h = Harness()
        h.send(.keyDown); h.advance(0.05); h.send(.keyUp)
        h.send(.otherKeyDown(isEscape: false))
        h.send(.keyDown) // Idle again, so this is a fresh press.
        #expect(h.take() == [.arm, .disarm, .abort, .arm])
    }

    // MARK: - Escape (priority 1)

    @Test(arguments: ["armed", "holding", "awaitingSecond", "latched", "latchedTap"])
    func escapeAbortsEveryLiveState(state: String) {
        let h = Harness()
        switch state {
        case "armed": h.send(.keyDown)
        case "holding": h.send(.keyDown); h.advance(hold + 0.01)
        case "awaitingSecond": h.send(.keyDown); h.advance(0.05); h.send(.keyUp)
        case "latched":
            h.send(.keyDown); h.advance(0.05); h.send(.keyUp); h.send(.keyDown)
            h.send(.keyUp)
        default: // latchedTap
            h.send(.keyDown); h.advance(0.05); h.send(.keyUp); h.send(.keyDown)
            h.send(.keyUp); h.send(.keyDown)
        }
        _ = h.take()

        // Escape is the one key a hold does not swallow (§10.5).
        #expect(h.send(.otherKeyDown(isEscape: true)) == .pass)
        #expect(h.take() == [.abort])

        // Disarmed for good: releasing the key must not stop or restart anything.
        h.send(.keyUp)
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
        h.send(.keyDown); h.advance(hold + 0.01)
        h.send(.otherKeyDown(isEscape: true))
        h.send(.keyUp)
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

// MARK: - Every offered dictation key

struct DictationKeyTests {
    @Test func keycodesAndMasksMatchIOKit() {
        // From HIToolbox `Events.h` and IOKit `IOLLEvent.h`, verified against the SDK.
        #expect(DictationKey.rightOption.keycode == 61 && DictationKey.rightOption.deviceMask == 0x40)
        #expect(DictationKey.rightCommand.keycode == 54 && DictationKey.rightCommand.deviceMask == 0x10)
        #expect(DictationKey.rightControl.keycode == 62 && DictationKey.rightControl.deviceMask == 0x2000)
        #expect(DictationKey.default == .rightOption)
    }

    @Test(arguments: DictationKey.allCases)
    func filterAcceptsOnlyTheChosenKey(key: DictationKey) {
        #expect(key.input(keycode: key.keycode, flags: key.deviceMask) == .keyDown)
        #expect(key.input(keycode: key.keycode, flags: 0) == .keyUp)
        // Another held modifier's bits do not turn a release into a press.
        #expect(key.input(keycode: key.keycode, flags: 0x20 | 0x08) == .keyUp)

        for other in DictationKey.allCases where other != key {
            #expect(key.input(keycode: other.keycode, flags: other.deviceMask) == nil)
            #expect(key.input(keycode: other.keycode, flags: 0) == nil)
        }
        // Left-hand modifiers (Cmd 55, Shift 56, Option 58, Ctrl 59) and Fn 63.
        for keycode: Int64 in [55, 56, 58, 59, 63] {
            #expect(key.input(keycode: keycode, flags: key.deviceMask) == nil)
        }
    }

    @Test(arguments: DictationKey.allCases)
    func holdLatchAndEscapeBehaveTheSame(key: DictationKey) {
        func press(_ h: Harness) { h.send(key.input(keycode: key.keycode, flags: key.deviceMask)!) }
        func release(_ h: Harness) { h.send(key.input(keycode: key.keycode, flags: 0)!) }

        // Hold: nothing consumed until the threshold, release passes.
        let hold = Harness()
        #expect(hold.send(key.input(keycode: key.keycode, flags: key.deviceMask)!) == .pass)
        hold.advance(GestureRecognizer.holdThreshold + 0.01)
        #expect(hold.send(.otherKeyDown(isEscape: false)) == .swallow)
        #expect(hold.send(key.input(keycode: key.keycode, flags: 0)!) == .pass)
        #expect(hold.take() == [.arm, .pushToTalk, .stop])

        // Double-tap latches, a third tap stops.
        let latch = Harness()
        press(latch); latch.advance(0.05); release(latch)
        latch.advance(0.1)
        press(latch); release(latch)
        latch.advance(1)
        press(latch); latch.advance(0.05); release(latch)
        #expect(latch.take() == [.arm, .disarm, .latched, .stop])

        // Escape aborts a live hold, and the release is inert.
        let esc = Harness()
        press(esc); esc.advance(GestureRecognizer.holdThreshold + 0.01)
        #expect(esc.send(.otherKeyDown(isEscape: true)) == .pass)
        release(esc)
        #expect(esc.take() == [.arm, .pushToTalk, .abort])
    }
}
