//
//  EventTap.swift
//  Sotto
//
//  Slice 2. The tap itself — §2.4, §2.5, §2.6.
//

import ApplicationServices
import CoreGraphics
import Foundation
import os

/// The `CGEventTap`, its thread, and the keycode comparison. Gesture *meaning* is next
/// door in `GestureRecognizer`; this file is transport.
///
/// **The tap runs on a dedicated thread (§2.5).** Hard requirement, not an
/// optimization: a callback that blocks the main runloop freezes the menu bar, which
/// breaks quit-as-panic (§10.5), which is the only reliable shutdown path — event taps
/// are per-process and die with the process. A wedged tap must never take the UI down
/// with it.
///
/// **What it reads.** Two keycodes are acted on, 54 and 61, plus one comparison against
/// 53 for Escape. `Sotto` is a right-hand program (DECISIONS.md, 2026-08-15), so left
/// Cmd and left Option are not triggers. One precision so §2.4's claim stays honest: a
/// `flagsChanged` subscription cannot be filtered per keycode by the OS, so the callback
/// is handed every modifier and discards the rest on the next line. Nothing is decoded,
/// nothing is accumulated, nothing is stored.
final class EventTap {
    static let shared = EventTap()

    private let log = Logger(subsystem: "com.anthonyprosser.Sotto", category: "gestures")
    private let recognizer = GestureRecognizer()
    private var tap: CFMachPort?

    private init() {}

    /// The keycodes this file compares against, and the complete list.
    private enum Key {
        static let escape: Int64 = 53
        static let rightCommand: Int64 = 54
        static let rightOption: Int64 = 61
    }

    /// Device-dependent modifier bits, from IOKit's `IOLLEvent.h`. A `flagsChanged`
    /// event reports the whole modifier state, so `.maskCommand` cannot tell a Right Cmd
    /// press from a Left one, and cannot tell a press from a release while the other
    /// side is held. These bits can.
    private enum DeviceMask {
        static let rightCommand: UInt64 = 0x0000_0010 // NX_DEVICERCMDKEYMASK
        static let rightOption: UInt64 = 0x0000_0040  // NX_DEVICERALTKEYMASK
    }

    /// §2.6's tag. Slice 3 posts Cmd+C for the selection fallback and Cmd+V for the
    /// clipboard paste; without the matching check below, Sotto's own gesture detector
    /// fires on Sotto's own output. The poster arrives with those two call sites — the
    /// filter is here now because a tap that forgets it fails in a way that looks like a
    /// timing bug rather than a missing line.
    static let syntheticMarker: Int64 = 0x536F_7474 // "Sott"

    func install() {
        // §2.4: asked at first use of the feature that needs it, and the gestures are
        // the app. Onboarding proper is slice 15; this is the bare system prompt.
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        if !AXIsProcessTrustedWithOptions(prompt as CFDictionary) {
            log.notice("Accessibility not granted yet — the tap will not install until it is.")
        }

        let thread = Thread { [self] in run() }
        thread.name = "com.anthonyprosser.Sotto.eventtap"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    // MARK: - The thread

    private func run() {
        // Assigned here rather than in `install()` on purpose: the timer has to land on
        // *this* runloop. Scheduled onto the main one it would fire on a thread the
        // state machine is never touched from; scheduled onto a runloop nobody runs, it
        // would not fire at all.
        recognizer.after = { delay, body in
            let timer = CFRunLoopTimerCreateWithHandler(
                kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + delay, 0, 0, 0
            ) { _ in body() }
            CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .commonModes)
        }
        recognizer.emit = { [log] signal in
            log.notice("\(signal.rawValue, privacy: .public)")
        }

        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        // `.defaultTap`, not `.listenOnly`: a listen-only tap cannot swallow, and the
        // hold has to swallow. `.cgSessionEventTap` is the session-level tap, which is
        // where a tap can both see and alter what reaches the frontmost app.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                return Unmanaged<EventTap>.fromOpaque(context)
                    .takeUnretainedValue()
                    .handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            log.error("""
                Event tap not created. Grant Sotto Accessibility and Input Monitoring in \
                System Settings > Privacy & Security, then relaunch.
                """)
            return
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        log.notice("Event tap installed.")

        CFRunLoopRun()
    }

    // MARK: - The callback

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)

        // macOS disables a tap whose callback ran long, and says so through the tap
        // itself. Re-arming here is what makes §10.5's backstop a recovery rather than a
        // dead keyboard shortcut for the rest of the session.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
                log.notice("Tap re-armed after being disabled.")
            }
            return nil
        }

        // §2.6.
        guard event.getIntegerValueField(.eventSourceUserData) != Self.syntheticMarker else {
            return pass
        }

        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags.rawValue
        let disposition: GestureRecognizer.Disposition

        switch type {
        case .flagsChanged:
            switch keycode {
            case Key.rightCommand:
                let isDown = flags & DeviceMask.rightCommand != 0
                disposition = recognizer.handle(isDown ? .rightCommandDown : .rightCommandUp)
            case Key.rightOption:
                guard flags & DeviceMask.rightOption != 0 else { return pass }
                disposition = recognizer.handle(.rightOptionDown)
            default:
                return pass // Every other modifier, discarded without being looked at.
            }
        case .keyDown:
            disposition = recognizer.handle(.otherKeyDown(isEscape: keycode == Key.escape))
        case .keyUp:
            disposition = recognizer.handle(.otherKeyUp)
        default:
            return pass
        }

        return disposition == .pass ? pass : nil
    }
}
