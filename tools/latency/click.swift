//
//  click.swift — test harness, 2026-08-27.
//
//  Posts one left click at a global screen point, so the overlay's controls can
//  be exercised from a script. Same posting rule as the other harnesses: this
//  one goes to `.cghidEventTap` because it is meant for whatever is on screen,
//  not for Sotto's own event tap.
//
//  Usage: click <x> <y>
//
import CoreGraphics
import Foundation

let x = Double(CommandLine.arguments[1])!
let y = Double(CommandLine.arguments[2])!
let point = CGPoint(x: x, y: y)
let src = CGEventSource(stateID: .hidSystemState)
CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
usleep(60_000)
CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
usleep(40_000)
CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
usleep(300_000)
