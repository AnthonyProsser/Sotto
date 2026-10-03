//
//  InsertionTests.swift
//  SottoTests
//
//  Slice 3. The leading-space rule is pure and tested directly. One integration
//  test drives the real `Insertion.insert` into an NSTextView in this process
//  (the test host is Sotto, so it carries Sotto's Accessibility grant).
//  The measured-write fall-through (Safari), the no-focused-field clipboard path
//  and Electron are manual checks: they need another app.
//

import AppKit
import ApplicationServices
import Testing
@testable import Sotto

struct InsertionSpacingTests {

    @Test(arguments: ["a", "d", "9", ".", ",", ")", "]", "}", "!"])
    func spaceAfterAWordOrClosingPunctuation(preceding: Character) {
        #expect(Insertion.leadingSpace(after: preceding) == " ")
    }

    @Test(arguments: [" ", "\n", "\t", "(", "[", "{", "<", "\u{201C}", "\u{2018}", "\"", "'"] as [Character])
    func noSpaceAfterWhitespaceOrAnOpener(preceding: Character) {
        #expect(Insertion.leadingSpace(after: preceding).isEmpty)
    }

    @Test func noReadMeansNoSpace() {
        #expect(Insertion.leadingSpace(after: nil).isEmpty)
    }
}

extension SharedState {
@Suite @MainActor
struct InsertionIntegrationTests {

    /// A key window with a focused text view, and the system-wide AX focus
    /// confirmed to be inside this process before anything is inserted — otherwise
    /// `insert` would write into whatever app is frontmost.
    private func focusedTextView(_ initial: String, as textView: NSTextView = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))) async throws -> (NSTextView, NSWindow) {
        textView.string = initial
        textView.isEditable = true
        return try await focused(textView) { $0.setSelectedRange(NSRange(location: (initial as NSString).length, length: 0)) }
    }

    /// Any first responder, not only a text view: the no-focused-field test needs one that is not a field.
    private func focused<V: NSView>(_ view: V, configure: (V) -> Void = { _ in }) async throws -> (V, NSWindow) {
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 300, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false // ARC owns it; the default double-releases on close()
        window.contentView = view
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        configure(view)

        for _ in 0..<40 {
            if focusedPID() == ProcessInfo.processInfo.processIdentifier { return (view, window) }
            try await Task.sleep(for: .milliseconds(50))
        }
        window.orderOut(nil)
        throw FocusUnavailable()
    }

    private struct FocusUnavailable: Error, CustomStringConvertible {
        var description: String { "system-wide AX focus never landed in the test host; run manually" }
    }

    private func focusedElement() -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &value
        ) == .success, let element = value, CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
        return (element as! AXUIElement)
    }

    private func focusedPID() -> pid_t? {
        guard let element = focusedElement() else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return pid
    }


    @Test(.enabled(if: AXIsProcessTrusted(), "test host has no Accessibility grant"))
    func insertsAtTheCaretWithALeadingSpace() async throws {
        let (view, window) = try await focusedTextView("hello")
        defer { window.orderOut(nil) }
        let outcome = Insertion.insert("world")
        guard case .inserted = outcome else {
            Issue.record("expected .inserted, got \(outcome)")
            return
        }
        #expect(view.string == "hello world")
    }

    @Test(.enabled(if: AXIsProcessTrusted(), "test host has no Accessibility grant"))
    func noSpaceAgainstAnOpener() async throws {
        let (view, window) = try await focusedTextView("say (")
        defer { window.orderOut(nil) }
        guard case .inserted = Insertion.insert("hi") else {
            Issue.record("expected .inserted")
            return
        }
        #expect(view.string == "say (hi")
    }

    // MARK: - The ladder's other rungs

    /// Restores the user's pasteboard (every item, every type) however the body exits.
    private func keepingClipboard(_ body: () async throws -> Void) async rethrows {
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer {
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        }
        try await body()
    }

    /// Answers `kAXErrorSuccess` to an `AXSelectedText` write and does nothing with it —
    /// Safari's behaviour (input-and-insertion.md §2), which is what sends `insert` to paste.
    private final class IgnoresAXWrites: NSTextView {
        override func setAccessibilitySelectedText(_ selectedText: String?) {}
    }

    /// Cmd+V only reaches a text view through a Paste menu item, and the test host has no main menu.
    private func withPasteMenu(_ body: () async throws -> Void) async rethrows {
        let previous = NSApp.mainMenu
        defer { NSApp.mainMenu = previous }
        let menu = NSMenu(), edit = NSMenu(title: "Edit"), host = NSMenuItem()
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        host.submenu = edit
        menu.addItem(NSMenuItem())
        menu.addItem(host)
        NSApp.mainMenu = menu
        try await body()
    }

    @Test(.enabled(if: AXIsProcessTrusted(), "test host has no Accessibility grant"))
    func fallsBackToPasteWhenTheAXWriteDoesNotLand() async throws {
        try await keepingClipboard {
            try await withPasteMenu {
                let sentinel = "user clipboard \(UUID().uuidString)"
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(sentinel, forType: .string)

                let (view, window) = try await focusedTextView("hello", as: IgnoresAXWrites(frame: NSRect(x: 0, y: 0, width: 300, height: 100)))
                defer { window.orderOut(nil) }
                guard case .inserted = Insertion.insert("world") else {
                    Issue.record("expected .inserted from the paste rung")
                    return
                }
                for _ in 0..<40 where view.string != "hello world" { try await Task.sleep(for: .milliseconds(50)) }
                #expect(view.string == "hello world", "paste did not land: \(view.string)")
                // The restore is deferred 0.5 s (Insertion.paste).
                try await Task.sleep(for: .milliseconds(900))
                #expect(NSPasteboard.general.string(forType: .string) == sentinel, "the user's clipboard was not restored")
            }
        }
    }

    @Test(.enabled(if: AXIsProcessTrusted(), "test host has no Accessibility grant"))
    func noFocusedFieldCopiesToTheClipboardAndTouchesNoView() async throws {
        try await keepingClipboard {
            let textView = NSTextView(frame: NSRect(x: 0, y: 40, width: 300, height: 60))
            textView.string = "untouched"
            let button = NSButton(title: "Not a field", target: nil, action: nil)
            button.frame = NSRect(x: 0, y: 0, width: 300, height: 40)
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
            container.addSubview(textView)
            container.addSubview(button)
            let (_, window) = try await focused(container) { $0.window?.makeFirstResponder(button) }
            defer { window.orderOut(nil) }
            // The button (or the window) holds focus, so no writable element is focused.
            try #require(window.firstResponder === button, "button did not take first responder")

            let text = "clipboard only \(UUID().uuidString)"
            guard case .copied = Insertion.insert(text) else {
                Issue.record("expected .copied")
                return
            }
            #expect(NSPasteboard.general.string(forType: .string) == text)
            #expect(textView.string == "untouched")
        }
    }

    /// A different process: real `AXFocusedUIElement` across the boundary, `AXTextArea`, the AX write.
    /// Needs Automation permission for Sotto to control TextEdit; without it the test cancels.
    @Test(.enabled(if: AXIsProcessTrusted(), "test host has no Accessibility grant"))
    func insertsIntoTextEdit() async throws {
        func script(_ source: String) throws {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            guard let error else { return }
            if (error[NSAppleScript.errorNumber] as? Int) == -1743 {
                try Test.cancel("Sotto has no Automation permission for TextEdit")
            }
            throw AppleScriptFailure(description: "\(error)")
        }
        let bundleID = "com.apple.TextEdit"
        let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty

        try await keepingClipboard {
            try script("tell application \"TextEdit\"\nactivate\nmake new document\nend tell")
            defer {
                try? script("tell application \"TextEdit\" to close front document saving no")
                if !wasRunning { try? script("tell application \"TextEdit\" to quit") }
            }
            let textEdit = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first)

            var element: AXUIElement?
            for _ in 0..<100 {
                if let candidate = focusedElement(), focusedPID() == textEdit.processIdentifier { element = candidate; break }
                try await Task.sleep(for: .milliseconds(50))
            }
            let target = try #require(element, "TextEdit's text view never took AX focus")

            guard case .inserted = Insertion.insert("dictated into TextEdit") else {
                Issue.record("expected .inserted")
                return
            }
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(target, kAXValueAttribute as CFString, &value)
            #expect(value as? String == "dictated into TextEdit")
        }
    }

    private struct AppleScriptFailure: Error, CustomStringConvertible { var description: String }
}
}
