//
//  Insertion.swift
//  Sotto
//
//  Slice 3. Getting text into another app — sotto-spec.md §3, §4.8.
//

import AppKit
import ApplicationServices
import os

/// **Two strategies, tried in order, and only when a text field is focused.**
/// Accessibility first because the write is atomic; clipboard paste second
/// because save-and-restore of `NSPasteboard` is lossy — promised and lazy data
/// cannot be captured, and anything that copies during the window clobbers the
/// restore. The CGEvent Unicode strategy is deleted and stays deleted.
///
/// **No focused field means the clipboard and nothing else** (§3). Sotto never
/// pastes into whatever happens to be frontmost; the HUD's "Copied to clipboard"
/// morph is the whole reason that path is safe.
enum Insertion {
    private static let log = Logger(subsystem: "com.anthonyprosser.Sotto", category: "insertion")

    /// What the HUD is told (§4.5's completion table).
    enum Outcome {
        /// Landed at the cursor. The HUD fades with no message.
        case inserted
        /// No writable field, or both strategies were refused. The HUD says so.
        case copied
        case failed(String)
    }

    // MARK: - Focus

    /// Focused app → focused element (§3). Every call goes through here, so the
    /// messaging timeout is set in one place: an unresponsive target app would
    /// otherwise block the main thread for the AX default of six seconds, and
    /// insertion runs at the moment the user is waiting for their text.
    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 1.0)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &value
        ) == .success else { return nil }
        guard let element = value, CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
        let focused = element as! AXUIElement
        AXUIElementSetMessagingTimeout(focused, 1.0)
        return focused
    }

    /// §3's test: `AXRole` is `AXTextField`/`AXTextArea`, **or** `AXValue` is
    /// settable. The second half is what catches Electron and the web views that
    /// report a role of their own invention while still accepting a write.
    private static func isWritable(_ element: AXUIElement) -> Bool {
        if let role: String = attribute(element, kAXRoleAttribute),
           role == kAXTextFieldRole || role == kAXTextAreaRole {
            return true
        }
        var settable: DarwinBoolean = false
        let status = AXUIElementIsAttributeSettable(
            element, kAXValueAttribute as CFString, &settable
        )
        return status == .success && settable.boolValue
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value as? T
    }

    // MARK: - Selection (§3, §4.9)

    /// `AXSelectedText` on the **focused element only**. Reading only the focused
    /// element is what keeps §4.9 tolerable — a stale selection in a background
    /// window cannot hijack a dictation.
    ///
    /// **The synthetic Cmd+C fallback runs only when the attribute is absent**,
    /// which is the Electron and browser case §3 names. It is gated that tightly
    /// because it costs a clipboard round-trip on a surface the user is about to
    /// dictate into, and the pasteboard restore it needs is the same lossy one
    /// that makes paste the second insertion strategy rather than the first.
    static func selectedText() async -> String? {
        guard let element = focusedElement() else { return nil }

        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element, kAXSelectedTextAttribute as CFString, &value
        )
        if status == .success {
            let selected = value as? String ?? ""
            return selected.isEmpty ? nil : selected
        }

        return await copyViaClipboard()
    }

    /// `async` rather than blocking: the poll below spans up to 300 ms, and this
    /// runs while capture is already going. A `usleep` on the main actor would
    /// stall the waveform for the first third of a second of every dictation into
    /// an app that needs the fallback.
    private static func copyViaClipboard() async -> String? {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)
        let before = pasteboard.changeCount
        defer { restore(saved, to: pasteboard) }

        post(keyCode: Key.c)

        // Polled rather than slept: an app that answers in 20 ms should not cost
        // the same as one that answers in 200.
        let deadline = Date().addingTimeInterval(0.3)
        while Date() < deadline {
            if pasteboard.changeCount != before {
                let copied = pasteboard.string(forType: .string)
                return copied?.isEmpty == false ? copied : nil
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    // MARK: - Insertion

    /// The ladder. Returns what the HUD should say.
    ///
    /// **One undo unit per insertion** (§4.8), which both strategies give for
    /// free: an `AXSelectedText` write is a single edit to the target's own text
    /// storage, and a paste is one `NSUndoManager` group. Nothing here types
    /// character by character, which is the shape that would break it.
    static func insert(_ text: String) -> Outcome {
        guard let element = focusedElement(), isWritable(element) else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return .copied
        }

        // 1. Accessibility. `AXSelectedText` rather than `AXValue`: it writes at
        //    the insertion point and replaces the selection if there is one,
        //    where `AXValue` would replace the entire field.
        //
        //    **The returned status is not evidence, and this is why the write is
        //    measured rather than trusted.** WebKit answers `kAXErrorSuccess` to
        //    this write and then does nothing with it — measured in Safari
        //    against a plain `<textarea>` reporting `AXTextArea`, 2026-08-19.
        //    Believing the status there loses the text with no error anywhere,
        //    which is the one outcome §4.5 rules out.
        //
        //    `AXNumberOfCharacters` is the check because it is an integer: the
        //    obvious alternative, reading `AXValue` before and after, copies the
        //    whole document across the AX boundary twice on every dictation, and
        //    the document can be a book. A same-length replacement would defeat
        //    it and cannot arise here — a selection routes to chat (§4.9), so
        //    insertion always runs against a bare caret.
        let before: Int? = attribute(element, kAXNumberOfCharactersAttribute)
        if AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, text as CFTypeRef
        ) == .success,
           let before, let after: Int = attribute(element, kAXNumberOfCharactersAttribute),
           after != before {
            return .inserted
        }

        // 2. Clipboard paste.
        log.notice("AX write did not land; falling back to paste.")
        return paste(text) ? .inserted : .failed("Couldn’t insert text")
    }

    private static func paste(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return false }

        post(keyCode: Key.v)

        // The restore is asynchronous because the paste is: the target app reads
        // the pasteboard on its own turn of the runloop, and putting the old
        // contents back before it has read is the failure this delay exists for.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            restore(saved, to: pasteboard)
        }
        return true
    }

    // MARK: - Synthetic events (§2.6)

    private enum Key {
        static let c: CGKeyCode = 8
        static let v: CGKeyCode = 9
    }

    /// Cmd + `keyCode`, tagged so Sotto's own tap ignores it.
    ///
    /// **Posted to `.cgAnnotatedSessionEventTap`**, which is what delivers
    /// reliably to the frontmost app. That location is downstream of the session
    /// tap `EventTap` listens on, so these never come back around — the tag is
    /// belt and braces, and it is the belt that is load-bearing when another tap
    /// re-posts them.
    private static func post(keyCode: CGKeyCode) {
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }

        for event in [down, up] {
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: EventTap.syntheticMarker)
            event.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    // MARK: - Pasteboard save and restore

    /// **Lossy, and known to be** (§3). Promised and lazy data — a file dragged
    /// from Finder, rich content from some apps — is not in `data(forType:)` and
    /// cannot be captured here at all. This is why paste is the second strategy.
    private static func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    private static func restore(_ items: [NSPasteboardItem], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        pasteboard.writeObjects(items)
    }
}
