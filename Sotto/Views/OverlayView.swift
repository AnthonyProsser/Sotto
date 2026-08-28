//
//  OverlayView.swift
//  Sotto
//
//  Slice 9, stages 1–2. The compose bar — sotto-spec.md §5.8, Frames 1 and 3 of
//  `Designs for Slice9.pdf`.
//

import SwiftUI

/// The compose surface: add-context `+`, message field, chat control, send
/// (§5.8).
///
/// **Two layouts, because the design draws two.** Frame 1 puts everything on one
/// 52 pt line. Frame 3 — the same bar with chips and a two-line draft — stacks
/// them: chips, then the field, then a control row underneath. Nothing in the PDF
/// draws the state between them, so the rule is this file's, stated plainly: the
/// bar is **inline while the draft is one line with no attachments**, and
/// **stacked otherwise**.
///
/// **The way back is emptiness, not height, and that is deliberate.** The field is
/// wider stacked than inline, so a draft that wraps to two lines inline may fit on
/// one line stacked — a height test in both directions oscillates on exactly the
/// string that triggers it. Collapsing only when the text and the chips are both
/// empty makes the transition happen once on the way out and once on the way back.
///
/// **Everything here is one consumer's local constant, not a token.** The
/// pre-approved tier-2 slot for this slice is *overlay intrusiveness* — width
/// ratio, padding, stroke, shadow, position, density — and a row buys indirection
/// plus a maintenance claim, which none of these have earned while there is
/// exactly one bar reading them (`rules/design.md` §9). The one thing promoted to
/// `Token` is the material, because `Token.Material` already reserves the role by
/// name and Anthony ruled on the HUD's twin the same way.
///
/// **The appearance is not pinned, and that is deliberate.** `HUDPanel` pins
/// because its labels would invert mid-dictation under a surface the user is not
/// looking at; the overlay is the surface the user *is* looking at, and
/// `rules/design.md` §6.7 says the branch does not generalise.
struct OverlayView: View {
    /// §6.1's 600 pt bar. A ratio of the display was considered and is not what
    /// the design draws — nothing in the bar scales with the screen, and a
    /// proportional width on a large display would stretch a single line of type
    /// across half of it.
    static let width: CGFloat = 600

    /// One line of composer, inline. The bar's bottom edge is what stays put,
    /// which is why the panel is anchored from the bottom.
    static let barHeight: CGFloat = 52

    /// **20, up from the design's 16 (Anthony, 2026-08-27), in both states** —
    /// Frame 2's docked composer draws r18 and takes this instead, so there is one
    /// radius family rather than two (`DECISIONS.md`, 2026-08-27).
    ///
    /// Still strictly less than half of `barHeight`, and that is the constraint
    /// rather than a coincidence: at `r = h/2` a `.continuous` corner and a
    /// circular arc are the same curve, because no straight edge is left for the
    /// superellipse to blend into (`DECISIONS.md`, 2026-08-18). 26 is the ceiling
    /// here and 20 keeps 6 pt of flat edge, so the corner is a real squircle.
    static let radius: CGFloat = 20

    /// The panel's canvas budget: chips wrapped to three rows, a field at its
    /// 144 pt cap, a control row, and the padding around them. The window is made
    /// this tall once and never resized — the surface grows *inside* it, which is
    /// cheaper than resizing a window on every keystroke and is why the bar can be
    /// bottom-anchored with a single `setFrameOrigin`.
    static let maxHeight: CGFloat = 320

    /// Left and right of the row. 14 pt from the design's caption.
    private static let padding: CGFloat = 14
    /// Both round controls, and the height the inline row aligns on.
    private static let control: CGFloat = 26
    private static let gap: CGFloat = 12

    // Stacked metrics, from Frame 2's caption — pad 13, chips row 27, gap 11,
    // field, gap 15, control row 26, pad 13.
    private static let padTop: CGFloat = 13
    private static let padBottom: CGFloat = 13
    private static let chipsGap: CGFloat = 11
    private static let fieldGap: CGFloat = 15
    private static let chipHeight: CGFloat = 27
    private static let lineHeight: CGFloat = 24
    /// §5.8, unchanged since it was written: six lines, then internal scroll.
    /// The height that comes to is the field's to compute — see `ComposerField`
    /// for why it is not the drawn 144.
    private static let fieldMaxLines = 6

    @State private var text = ""
    @State private var attachments: [String] = []
    @State private var fieldHeight: CGFloat = OverlayView.lineHeight
    @State private var expanded = false

    var body: some View {
        GlassEffectContainer(spacing: 0) {
            composer
                .frame(width: Self.width)
                // Applied last so it captures the content above it, and the shape
                // is passed to `in:` rather than clipped afterwards — a later
                // `.clipShape` would cut the specular edge and the rim refraction
                // the material draws outside the path (`rules/design.md` §6.1).
                .glassEffect(Token.Material.overlay, in: Token.shape(radius: Self.radius))
        }
        // The same rim the HUD wears, from the same one implementation. The
        // design's flat "0.5 pt @ 9 % light / 12 % dark" stroke is the mockup's
        // stand-in for a lit edge, which is what `Specular` already is.
        .specularRim(radius: Self.radius)
        // The panel is taller than the bar so the surface can grow without
        // resizing the window, so the bar has to say where in that canvas it
        // sits: bottom-centred, because growth is upward from a fixed bottom edge
        // (§5.8).
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .onChange(of: fieldHeight) { _, height in
            if height > Self.lineHeight + 1 { expanded = true }
        }
        .onChange(of: attachments) { _, chips in
            if !chips.isEmpty { expanded = true }
        }
        .onChange(of: text) { _, draft in
            if draft.isEmpty && attachments.isEmpty { expanded = false }
        }
    }

    @ViewBuilder
    private var composer: some View {
        if expanded { stacked } else { inline }
    }

    // MARK: - Frame 1: one line, everything on it

    private var inline: some View {
        HStack(spacing: Self.gap) {
            addContext
            field.frame(height: Self.lineHeight)
            chatControl
            sendButton
        }
        .padding(.horizontal, Self.padding)
        .frame(height: Self.barHeight)
    }

    // MARK: - Frame 3: chips, field, controls

    private var stacked: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !attachments.isEmpty {
                chips
                Spacer(minLength: 0).frame(height: Self.chipsGap)
            }
            field.frame(height: fieldHeight)
            Spacer(minLength: 0).frame(height: Self.fieldGap)
            HStack(spacing: Self.gap) {
                addContext
                Spacer(minLength: 0)
                chatControl
                sendButton
            }
        }
        .padding(.horizontal, Self.padding)
        .padding(.top, Self.padTop)
        .padding(.bottom, Self.padBottom)
    }

    // MARK: - Pieces

    private var field: some View {
        ZStack(alignment: .topLeading) {
            // Placeholder only, no label (§5.8). Drawn rather than asked for:
            // `NSTextView` has no placeholder, and the alternative is the private
            // `placeholderString` key.
            if text.isEmpty {
                Text("Message")
                    .font(.title3)
                    .foregroundStyle(Color(nsColor: .placeholderTextColor))
                    .frame(height: Self.lineHeight)
                    .allowsHitTesting(false)
            }
            ComposerField(
                text: $text,
                maxLines: Self.fieldMaxLines,
                height: $fieldHeight,
                onSend: send
            )
        }
    }

    /// Stage 4 gives it the §5.8 menu — file, image, screenshot, current
    /// selection. Until then it seeds a chip, so the wrapping row and the per-chip
    /// dismiss are exercisable rather than theoretical.
    private var addContext: some View {
        Button {
            attachments.append("Screenshot \(attachments.count + 1)")
        } label: {
            Image(systemName: "plus")
                // Same style as the field it sits beside, so the glyph tracks the
                // text rather than a number: `.title3` is 15 pt.
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: Self.control, height: Self.control)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    /// §14.3 rejects a *saturated* send button, not a send button. 7 % ink behind
    /// a 60 % ink glyph is the design's answer: present, and third in weight after
    /// the caret and the chat control.
    ///
    /// Rejected system value: `.quaternary`, the nearest hierarchical fill, which
    /// is about 0.25 and at 26 pt reads as a filled button.
    private var sendButton: some View {
        Button(action: send) {
            Image(systemName: "arrow.up")
                // `.callout` is 12 pt — the HUD's own precedent for reaching a
                // size through a named style (`DECISIONS.md`, 2026-08-18).
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary.opacity(0.6))
                .frame(width: Self.control, height: Self.control)
                .background(.primary.opacity(0.07), in: .circle)
        }
        .buttonStyle(.plain)
    }

    /// Attachments wrap above the field and count toward intrinsic height (§5.8).
    /// Accent is on the chips and the caret and nowhere else, per Frame 1's
    /// caption — `Color.accentColor` is `controlAccentColor`, so the design's
    /// `#0A84FF` stays a stand-in and is never typed.
    private var chips: some View {
        WrapLayout(spacing: 6, lineSpacing: 6) {
            ForEach(attachments, id: \.self) { name in
                HStack(spacing: 5) {
                    Text(name).font(.callout).lineLimit(1)
                    Button {
                        attachments.removeAll { $0 == name }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2.weight(.semibold))
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 9)
                .frame(height: Self.chipHeight)
                .background(Color.accentColor.opacity(0.12), in: .capsule)
            }
        }
    }

    /// Names the current target and, from stage 4, opens the recent-chat list
    /// (§5.3). **`New chat` is the placeholder when no chat is selected**
    /// (Anthony's ruling) — not hidden and not disabled, because the control is
    /// how you reach an older chat with continuity off, so it can never be the
    /// thing that is missing.
    ///
    /// Frame 3's dashed-accent pill is the *pending* treatment and belongs with
    /// stage 4; nothing here is pending yet, so this is drawn plain.
    private var chatControl: some View {
        HStack(spacing: 4) {
            Text("New chat")
                .font(.callout)
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.down")
                // The smallest named style, which is what a disclosure chevron
                // wants; a literal here would author a size for one glyph.
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .frame(height: Self.control)
        .background(.primary.opacity(0.07), in: .capsule)
        .fixedSize()
    }

    /// Stage 3 owns the draft and where it goes. Until it exists, sending is the
    /// part that is observable — the surface empties and returns to Frame 1 —
    /// which is what stage 2 needs to show the transition working in both
    /// directions.
    private func send() {
        text = ""
        attachments = []
        expanded = false
    }
}

/// A wrapping row. There is no system layout for this — `HStack` does not wrap,
/// `Grid` is fixed-column, and `ViewThatFits` picks one child rather than
/// flowing them — so it is written once here, for the one consumer that needs it.
private struct WrapLayout: Layout {
    let spacing: CGFloat
    let lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width && !row.indices.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
