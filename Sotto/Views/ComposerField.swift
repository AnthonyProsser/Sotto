//
//  ComposerField.swift
//  Sotto
//
//  Slice 9, stage 2. The composer's text field — sotto-spec.md §5.8.
//

import AppKit
import SwiftUI

/// The message field: grows a line at a time, caps, then scrolls itself.
///
/// **Why this is AppKit when every other view is SwiftUI.** §5.8 names the
/// keyboard rule and names IME inside it — "during IME composition Return remains
/// the input method's and does not send prematurely." SwiftUI's `onKeyPress` sees
/// the key *before* the input method has finished with it, so a Japanese or
/// Chinese user confirming a candidate with Return would send a half-composed
/// draft. AppKit already draws the distinction Sotto needs, in two selectors the
/// text system only calls once composition is done:
///
/// - `insertNewline(_:)` — Return. Sends.
/// - `insertNewlineIgnoringFieldEditor(_:)` — Shift-Return. Inserts a line break.
///
/// That is the whole rule, expressed as the two methods the system was already
/// going to call. Issue 2's ruling confines AppKit to the delegate, the status
/// item, and window hosts; this is the exception that ruling did not anticipate,
/// and it is one control rather than a surface.
struct ComposerField: NSViewRepresentable {
    @Binding var text: String
    /// Grows to this many lines, then scrolls internally (§5.8).
    ///
    /// **Lines, not points, and that is the correction.** The design's 144 pt is
    /// six lines at the drawn 15/24; the line box `.title3` actually lays out is
    /// 26.5 pt, so a 144 pt cap shows five lines and a sixth sliced through the
    /// middle — measured 2026-08-27. §5.8's rule was always "six lines"; 144 was
    /// arithmetic on a leading that the text system does not produce, and the
    /// rule is the part worth keeping.
    let maxLines: Int
    /// The field's laid-out height, reported upward so the composer can size
    /// itself. One line when empty.
    @Binding var height: CGFloat
    /// True once the draft needs a second line **at the field's current
    /// width** — the inline→stacked trigger (`OverlayView`, `DECISIONS.md`
    /// 2026-09-01: text types on the control row and moves to the top row only
    /// when the line fills). A height test cannot do this job: the raw natural
    /// line box (26⅓ pt) is taller than the drawn row regardless of where the
    /// draft wraps, so "more than one line tall" carries no width information.
    /// Width, not height, is what "the line fills" means, and the field lays
    /// out at whichever width the current composer state gives it.
    @Binding var overflow: Bool
    let onSend: () -> Void
    /// Cmd+V image paste → chip. Stay nil for call sites that don't need it.
    var onImagePaste: ((Data, String) -> Void)? = nil

    /// 15/24 from the design's caption. The size is `.title3`'s, read from the
    /// system rather than typed. **The 24-pt row is not the font's line box** —
    /// the style's natural box is `ascender − descender + leading` ≈ 26⅓, and
    /// TextKit 2 ignores `maximumLineHeight`, so a min/max pair does nothing.
    /// `paragraphStyle` closes the gap with `lineHeightMultiple` instead, which
    /// TextKit 2 does honor (measured 2026-09-01) — the caret then spans the
    /// same 24-pt row the glyphs and the frames assume, instead of a taller box
    /// that clipped and sat the text off-centre against it.
    static let lineHeight: CGFloat = 24

    static var font: NSFont { .preferredFont(forTextStyle: .title3) }

    static var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        let font = Self.font
        // Drawn row over natural box — derived, not authored. When the system
        // font changes, the multiple follows it and the row stays 24. The
        // min/max pair is left unset on purpose: `maximumLineHeight` is
        // ignored by TextKit 2, and setting `minimumLineHeight` alongside the
        // multiple broke the scaling it was there to guarantee.
        style.lineHeightMultiple = Self.lineHeight / (font.ascender - font.descender + font.leading)
        return style
    }

    func makeNSView(context: Context) -> NSScrollView {
        let field = TextView(frame: NSRect(x: 0, y: 0, width: 100, height: Self.lineHeight))
        // **The six properties an `NSTextView` needs before it will lay out
        // inside a scroll view.** Without them the text container is zero-width,
        // nothing lays out, and the field reads as one that refuses focus rather
        // than as a layout bug — which is exactly how it presented the first time
        // (2026-08-27). `scrollableTextView()` sets them, but it also builds the
        // text view itself, and the two keyboard selectors below need to be on
        // the instance from the start.
        field.minSize = NSSize(width: 0, height: Self.lineHeight)
        field.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        field.isVerticallyResizable = true
        field.isHorizontallyResizable = false
        field.autoresizingMask = [.width]
        field.textContainer?.widthTracksTextView = true
        field.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        field.delegate = context.coordinator
        field.onSend = onSend
        field.onImagePaste = onImagePaste
        let coordinator = context.coordinator
        field.onSizeChange = { [weak field] in
            guard let field else { return }
            coordinator.report(field)
        }
        field.font = Self.font
        field.defaultParagraphStyle = Self.paragraphStyle
        field.typingAttributes = [
            .font: Self.font,
            .paragraphStyle: Self.paragraphStyle,
            .foregroundColor: NSColor.labelColor,
        ]
        field.textColor = .labelColor
        // The glass is the background. A field bezel here would be a second
        // surface inside the first (`rules/design.md` §3).
        field.drawsBackground = false
        field.isRichText = false
        field.importsGraphics = false
        field.allowsUndo = true
        field.textContainerInset = .zero
        field.textContainer?.lineFragmentPadding = 0

        let scroll = NSScrollView()
        scroll.documentView = field
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        // No elastic bounce: the field is six lines tall at most, and
        // rubber-banding a surface this small reads as the panel coming loose.
        scroll.verticalScrollElasticity = .none
        // The first show has no key transition to hang focus off — the window is
        // already key by the time this view exists — so the field claims it once
        // on the way in. `becomeKey` covers every show after that.
        DispatchQueue.main.async { [weak field] in
            guard let field, let window = field.window else { return }
            window.makeFirstResponder(field)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let field = scroll.documentView as? TextView else { return }
        field.onSend = onSend
        field.onImagePaste = onImagePaste
        if field.string != text { field.string = text }
        context.coordinator.report(field)
        context.coordinator.keepFocus(field)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let parent: ComposerField
        /// Where the caret was before a rebuild, so it can be put back.
        private var selection = NSRange(location: 0, length: 0)

        init(_ parent: ComposerField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? TextView else { return }
            parent.text = textView.string
            report(textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            selection = textView.selectedRange()
        }

        /// **The composer owns the caret for as long as the overlay is up.**
        ///
        /// The bar has two layouts (`OverlayView`), and moving between them is a
        /// structural change, so SwiftUI tears the representable down and builds
        /// a new one — which drops first responder on the floor at the exact
        /// moment the draft grows past one line. Measured 2026-08-27: typing
        /// stopped landing the instant the bar expanded.
        ///
        /// Reasserting it here rather than at the panel is what makes it survive
        /// every rebuild rather than just the first show. **The rule is the
        /// product's, not a workaround:** the overlay is a surface summoned to be
        /// typed into and there is nothing else in it to type into, so while it is
        /// the key window the caret belongs in the composer. A narrower condition
        /// — take focus only when the window itself holds it — was tried first
        /// and does not fire, because after a rebuild the responder is the
        /// hosting view rather than the window.
        func keepFocus(_ field: TextView) {
            guard let window = field.window, window.isKeyWindow else { return }
            guard window.firstResponder !== field else { return }
            window.makeFirstResponder(field)
            let end = (field.string as NSString).length
            field.setSelectedRange(NSRange(
                location: min(selection.location, end),
                length: min(selection.length, end - min(selection.location, end))
            ))
        }

        /// The laid-out height, clamped to the cap.
        ///
        /// **A TextKit 2 layout fragment is a paragraph, not a line**, which is
        /// the correction here — measured 2026-08-27, an eight-line draft with no
        /// hard breaks is one fragment, so taking the first fragment's height as
        /// the line height made the cap `8 lines x 6` and the field grew until the
        /// canvas ran out. The line is one step further in: the fragment's own
        /// `textLineFragments`, whose `typographicBounds` is the laid-out line box.
        ///
        /// An empty document has no fragments at all, which is why the floor is
        /// one line rather than zero.
        ///
        /// **A report at an un-laid-out width is worse than no report.** During
        /// the first layout pass — and the rebuild the inline→stacked switch
        /// triggers — the text view's width is still zero, and a zero-width
        /// container lays one unbounded line: the report would announce "one
        /// line" over a nine-line draft and collapse the height a previous,
        /// correct pass had set (the clipped-draft bug, 2026-09-01). Skip and
        /// wait for `setFrameSize` to re-run this at the real width.
        func report(_ textView: TextView) {
            guard textView.frame.width >= 1, let layout = textView.textLayoutManager else { return }
            layout.ensureLayout(for: layout.documentRange)
            var used: CGFloat = 0
            var line: CGFloat = 0
            var lines = 0
            layout.enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout]) { fragment in
                used = max(used, fragment.layoutFragmentFrame.maxY)
                lines += fragment.textLineFragments.count
                if line == 0, let first = fragment.textLineFragments.first {
                    line = first.typographicBounds.height
                }
                return true
            }
            if line == 0 { line = ComposerField.lineHeight }
            let cap = line * CGFloat(parent.maxLines)
            let clamped = min(max(used, line), cap)
            if abs(parent.height - clamped) > 0.5 {
                DispatchQueue.main.async { self.parent.height = clamped }
            }
            // Stacked is wider than inline, so a draft that overflowed inline
            // can lay one line here again; the consumer only acts on `true`,
            // which is what keeps this from oscillating with the width change.
            if (lines > 1) != parent.overflow {
                DispatchQueue.main.async { self.parent.overflow = lines > 1 }
            }
        }
    }

    /// Return, Shift-Return, Escape, and Cmd+V image paste — the whole keyboard rule.
    final class TextView: NSTextView {
        var onSend: () -> Void = {}
        var onImagePaste: ((Data, String) -> Void)? = nil
        /// Re-measure when the view's size changes. The width arrives *after*
        /// the first `updateNSView` (and again on the inline→stacked rebuild),
        /// and nothing else re-runs `report` for it — SwiftUI updates only on
        /// its own state, not on AppKit layout. Without this, a wide draft is
        /// measured once at the transient width and stays clipped forever.
        var onSizeChange: (() -> Void)? = nil

        override func setFrameSize(_ newSize: NSSize) {
            let widthChanged = abs(newSize.width - frame.width) > 0.5
            super.setFrameSize(newSize)
            if widthChanged {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.onSizeChange?()
                }
            }
        }

        override func insertNewline(_ sender: Any?) {
            // **Shift is read from the event, not from a second selector.**
            // `insertNewlineIgnoringFieldEditor(_:)` is the documented Shift-Return
            // binding and an `NSTextView` outside a field editor does not receive
            // it — measured 2026-08-27, Shift-Return sent the draft. Both keys
            // arrive here instead, and the modifier on the event that produced the
            // call is what separates them.
            //
            // This keeps the IME guarantee intact, which is the whole reason the
            // field is AppKit: `insertNewline(_:)` is only called once composition
            // has finished, so a candidate confirmed with Return never reaches it.
            // Reading `keyDown` directly would break exactly that.
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                insertLineBreak()
                return
            }
            // Non-empty only (§5.8: "Return sends a non-empty draft"). An empty
            // Return is not a line break either — it would grow the bar with
            // nothing in it.
            guard !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            onSend()
        }

        override func insertNewlineIgnoringFieldEditor(_ sender: Any?) {
            insertLineBreak()
        }

        private func insertLineBreak() {
            super.insertText("\n", replacementRange: selectedRange())
        }

        /// Escape belongs to the panel, not to the field. Without this the text
        /// view swallows it as "cancel completion" and §10.4's stack never gets
        /// its turn.
        override func cancelOperation(_ sender: Any?) {
            nextResponder?.tryToPerform(#selector(cancelOperation(_:)), with: sender)
        }

        /// **Cmd+V image paste (§5.5).** Images become draft attachments (chips), not
        /// inserted text. Text paste falls through to AppKit.
        override func paste(_ sender: Any?) {
            if handleImagePaste() { return }
            super.paste(sender)
        }

        override func pasteAsPlainText(_ sender: Any?) {
            if handleImagePaste() { return }
            super.pasteAsPlainText(sender)
        }

        private func handleImagePaste() -> Bool {
            let pb = NSPasteboard.general
            // Direct image data (screenshot Cmd+Ctrl+Shift+4, browser copy).
            if let tiff = pb.data(forType: .tiff), let img = NSImage(data: tiff), let rep = img.tiffRepresentation {
                // Prefer PNG if available.
                if let png = pb.data(forType: .png) {
                    onImagePaste?(png, "pasted-\(UUID().uuidString.prefix(4)).png"); return true
                }
                onImagePaste?(rep, "pasted-\(UUID().uuidString.prefix(4)).png"); return true
            }
            if let png = pb.data(forType: .png) {
                onImagePaste?(png, "pasted-\(UUID().uuidString.prefix(4)).png"); return true
            }
            // File URLs (Finder copy).
            if let items = pb.pasteboardItems {
                for item in items {
                    if let str = item.string(forType: .fileURL), let url = URL(string: str) {
                        let ext = url.pathExtension.lowercased()
                        if ["png","jpg","jpeg","webp","heic","gif","tiff","bmp"].contains(ext),
                           let data = try? Data(contentsOf: url) {
                            onImagePaste?(data, url.lastPathComponent); return true
                        }
                    }
                }
            }
            return false
        }
    }
}
