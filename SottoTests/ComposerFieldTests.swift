//
//  ComposerFieldTests.swift
//  Sotto
//
//  The field's laid-out line measurement — the inline→stacked trigger's
//  inputs (`OverlayView` expands on `overflow`, never on height).
//

import Testing
@testable import Sotto
import AppKit
import Foundation

@MainActor
struct ComposerFieldTests {

    /// The field exactly as `ComposerField.makeNSView` builds it, at a fixed
    /// width, with the string set the way `updateNSView` sets it.
    private func makeField(_ string: String, width: CGFloat) -> NSTextView {
        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: ComposerField.lineHeight))
        field.minSize = NSSize(width: 0, height: ComposerField.lineHeight)
        field.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        field.isVerticallyResizable = true
        field.isHorizontallyResizable = false
        field.autoresizingMask = [.width]
        field.textContainer?.widthTracksTextView = true
        field.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        field.font = ComposerField.font
        field.defaultParagraphStyle = ComposerField.paragraphStyle
        field.typingAttributes = [
            .font: ComposerField.font,
            .paragraphStyle: ComposerField.paragraphStyle,
        ]
        field.textContainerInset = .zero
        field.textContainer?.lineFragmentPadding = 0
        field.string = string
        return field
    }

    /// The same enumeration `Coordinator.report` runs.
    private func measure(_ field: NSTextView) -> (height: CGFloat, line: CGFloat, lines: Int) {
        guard let layout = field.textLayoutManager else { return (0, 0, 0) }
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
        return (used, line, lines)
    }

    /// **The drawn 24-pt row is held.** The style's natural box is ~26⅓ pt;
    /// `ComposerField.paragraphStyle` scales it down with
    /// `lineHeightMultiple`, which TextKit 2 honors where it ignores
    /// `maximumLineHeight`. If this ever fails, the caret and frames are
    /// working against a taller line box again — the off-centre text and
    /// clipped draft bug comes back with it.
    @Test func drawnRowIsHonored() {
        let m = measure(makeField("H", width: 450))
        #expect(m.lines == 1)
        #expect(abs(m.line - ComposerField.lineHeight) < 0.5)
    }

    /// A short draft stays inline: one line, so `overflow` never becomes true.
    @Test func shortDraftIsOneLine() {
        #expect(measure(makeField("Hello there", width: 450)).lines == 1)
    }

    /// The width-fill trigger: a draft that wraps at the inline width is two
    /// lines, which is what moves it to the top row. 450 pt is roughly the
    /// inline field's width in the 600-pt bare bar (600 − padding − controls
    /// − capsule).
    @Test func wrappedDraftIsTwoLines() {
        let long = String(repeating: "word ", count: 40)
        let m = measure(makeField(long, width: 450))
        #expect(m.lines >= 2)
        #expect(m.height >= 2 * ComposerField.lineHeight)
    }

    /// A hard break is two lines at any width — Shift-Return always stacks,
    /// because the inline row has nowhere to put a second line.
    @Test func hardBreakIsTwoLines() {
        #expect(measure(makeField("a\nb", width: 450)).lines == 2)
    }

    /// An empty draft reports no lines; the overflow signal stays false.
    @Test func emptyDraftIsZeroLines() {
        #expect(measure(makeField("", width: 450)).lines == 0)
    }
}
