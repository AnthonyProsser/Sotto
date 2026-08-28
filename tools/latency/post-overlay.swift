//
//  post-overlay.swift — slice 9, 2026-08-26.
//
//  Posts one synthetic double-tap of Right Option (keycode 61), which is the
//  overlay's only invocation (§5.1, `DECISIONS.md` 2026-08-15).
//
//  **Posts to `.cgSessionEventTap`, never `.cgAnnotatedSessionEventTap`** — the
//  annotated location is downstream of Sotto's own tap, so events posted there
//  are invisible to it and read as a tap that does nothing
//  (`rules/input-and-insertion.md` §5.1).
//
//  Usage: post-overlay [gap-ms]   — gap must be under GestureRecognizer's 300 ms
//

import CoreGraphics
import Foundation

let gapMS = CommandLine.arguments.count > 1 ? UInt32(CommandLine.arguments[1])! : 120

let maskAlternate: UInt64 = 0x0008_0000
let deviceRightOption: UInt64 = 0x0000_0040 // NX_DEVICERALTKEYMASK
let rightOptionKey: CGKeyCode = 61

let source = CGEventSource(stateID: .hidSystemState)

func postFlags(_ flags: UInt64) {
    guard let e = CGEvent(keyboardEventSource: source, virtualKey: rightOptionKey, keyDown: true) else { return }
    e.type = .flagsChanged
    e.flags = CGEventFlags(rawValue: flags)
    e.post(tap: .cgSessionEventTap)
}

postFlags(maskAlternate | deviceRightOption)
usleep(30_000)
postFlags(0)
usleep(gapMS * 1000)
postFlags(maskAlternate | deviceRightOption)
usleep(30_000)
postFlags(0)

// The posting process exiting immediately can drop the last event.
usleep(1_000_000)
