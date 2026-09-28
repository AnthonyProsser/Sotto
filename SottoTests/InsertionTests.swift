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

@Suite(.serialized)
@MainActor
struct InsertionIntegrationTests {

    /// A key window with a focused text view, and the system-wide AX focus
    /// confirmed to be inside this process before anything is inserted — otherwise
    /// `insert` would write into whatever app is frontmost.
    private func focusedTextView(_ initial: String) async throws -> (NSTextView, NSWindow) {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        textView.string = initial
        textView.isEditable = true
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 300, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = textView
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: (initial as NSString).length, length: 0))

        for _ in 0..<40 {
            if focusedPID() == ProcessInfo.processInfo.processIdentifier { return (textView, window) }
            try await Task.sleep(for: .milliseconds(50))
        }
        window.close()
        throw FocusUnavailable()
    }

    private struct FocusUnavailable: Error, CustomStringConvertible {
        var description: String { "system-wide AX focus never landed in the test host; run manually" }
    }

    private func focusedPID() -> pid_t? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &value
        ) == .success, let element = value, CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(element as! AXUIElement, &pid)
        return pid
    }

    @Test(.enabled(if: AXIsProcessTrusted(), "test host has no Accessibility grant"))
    func insertsAtTheCaretWithALeadingSpace() async throws {
        let (view, window) = try await focusedTextView("hello")
        defer { window.close() }
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
        defer { window.close() }
        guard case .inserted = Insertion.insert("hi") else {
            Issue.record("expected .inserted")
            return
        }
        #expect(view.string == "say (hi")
    }
}
