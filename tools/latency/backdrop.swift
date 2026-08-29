//
//  backdrop.swift — screenshot harness, 2026-08-27.
//
//  Fills the screen with one flat colour so a glass surface can be judged
//  against a known backdrop. Glass reads the luminance *behind* it rather than
//  the system appearance (`rules/design.md` §6.7), so "light and dark" for
//  Sotto's panels means a light and a dark backdrop, not Aqua and Dark Aqua.
//
//  **Why this exists rather than a wallpaper change or an image in Preview:**
//  macOS 26 returns `missing value` for the desktop picture, so a wallpaper set
//  from a script cannot be put back; and a background app cannot be raised above
//  the frontmost one from AppleScript, so an image window sits behind whatever
//  the user was in.
//
//  **Level 21: above the Dock (20), below `.statusBar` (25)**, which is where
//  `HUDPanel` and `OverlayPanel` live — so it covers every ordinary window and
//  covers neither of the two surfaces being photographed.
//
//  Usage: backdrop <light|dark> [seconds]
//

import AppKit

let wantsLight = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] != "dark" : true
let seconds = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2])! : 20

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let screen = NSScreen.main ?? NSScreen.screens[0]
let window = NSWindow(
    contentRect: screen.frame,
    styleMask: [.borderless],
    backing: .buffered,
    defer: false
)
window.setFrame(screen.frame, display: true)
window.isOpaque = true
window.backgroundColor = wantsLight
    ? NSColor(white: 0.95, alpha: 1)
    : NSColor(white: 0.08, alpha: 1)
window.hasShadow = false
window.ignoresMouseEvents = true
window.level = NSWindow.Level(rawValue: 21)
window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
window.orderFrontRegardless()

DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
app.run()
