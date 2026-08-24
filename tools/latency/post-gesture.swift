//
//  post-gesture.swift — latency harness, 2026-08-23.
//
//  Posts one synthetic Right-Cmd gesture. Three shapes, because the armed
//  window (2026-08-24) made what happens to a press that never becomes a
//  dictation as interesting as the dictation itself:
//
//    hold   Cmd down, hold, Escape, Cmd up  — starts and aborts a dictation
//    tap    Cmd down, hold, Cmd up          — a bare press, no dictation at all
//    chord  Cmd down, C down/up, Cmd up     — Right-Cmd+C, which must stay a copy
//
//  **Posts to `.cgSessionEventTap`, never `.cgAnnotatedSessionEventTap`.** The
//  annotated location is downstream of Sotto's own tap: events posted there
//  reach the frontmost app but are invisible to Sotto, which reads as a tap
//  that does nothing.
//
//  Usage: post-gesture <hold-ms> [hold|tap|chord]
//

import CoreGraphics
import Foundation

let holdMS = CommandLine.arguments.count > 1 ? UInt32(CommandLine.arguments[1])! : 600
let shape = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "hold"

// Device-dependent modifier bits, matching EventTap's own table.
let maskCommand: UInt64 = 0x0010_0000
let deviceRightCommand: UInt64 = 0x0000_0010
let rightCommandKey: CGKeyCode = 54
let escapeKey: CGKeyCode = 53
let cKey: CGKeyCode = 8

let source = CGEventSource(stateID: .hidSystemState)

func postFlags(_ flags: UInt64) {
    guard let e = CGEvent(keyboardEventSource: source, virtualKey: rightCommandKey, keyDown: true) else { return }
    e.type = .flagsChanged
    e.flags = CGEventFlags(rawValue: flags)
    e.post(tap: .cgSessionEventTap)
}

func postKey(_ key: CGKeyCode, down: Bool, flags: UInt64 = 0) {
    guard let e = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { return }
    if flags != 0 { e.flags = CGEventFlags(rawValue: flags) }
    e.post(tap: .cgSessionEventTap)
}

postFlags(maskCommand | deviceRightCommand)   // Right Cmd down — arms the gesture
usleep(holdMS * 1000)

switch shape {
case "tap":
    break                                      // nothing but the release below
case "chord":
    postKey(cKey, down: true, flags: maskCommand | deviceRightCommand)
    postKey(cKey, down: false, flags: maskCommand | deviceRightCommand)
default:
    postKey(escapeKey, down: true)             // Escape — aborts, inserts nothing
    postKey(escapeKey, down: false)
}

postFlags(0)                                   // Right Cmd up

// The posting process exiting immediately can drop the last event.
usleep(1_000_000)
