//
//  OverlayView.swift
//  Sotto
//
//  Slice 9, stages 1–2. The compose bar — sotto-spec.md §5.8, Frames 1 and 3 of
//  `Designs for Slice9.pdf`.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import os

/// The compose surface: add-context `+`, message field, chat control, send
/// (§5.8).
///
/// **Two layouts, because the design draws two.** Frame 1 puts everything on one
/// 52 pt line. Frame 3 — the same bar with chips and a two-line draft — stacks
/// them: chips, then the field, then a control row underneath. Nothing in the PDF
/// draws the state between them, so the rule is this file's, stated plainly: the
/// bar is **inline while the draft is one line at the inline width with no
/// attachments**, and **stacked otherwise**. The trigger is the field's laid-out
/// line count (`ComposerField.overflow`), never its height — the raw natural
/// line box is 26⅓ pt against the drawn 24 (`ComposerField.paragraphStyle` for
/// how the row is held at 24), so a height test cannot separate one short line
/// from two, and it fired on the first keystroke for a day (measured 2026-09-01).
///
/// **The way back is emptiness, not length, and that is deliberate.** The field is
/// wider stacked than inline, so a draft that wraps to two lines inline may fit on
/// one line stacked — a two-direction test oscillates on exactly the string that
/// triggers it. Collapsing only when the text and the chips are both empty makes
/// the transition happen once on the way out and once on the way back.
///
/// **Everything here is one consumer's local constant, not a token.** The
/// pre-approved tier-2 slot for this slice is *overlay intrusiveness* — width
/// ratio, padding, stroke, shadow, position, density — and a row buys indirection
/// plus a maintenance claim, which none of these have earned while there is
/// exactly one bar reading them (`rules/design.md` §9). The one thing promoted to
/// `Token` is the material, because `Token.Material` already reserves the role by
/// name and Anthony ruled on the HUD's twin the same way.
///
/// **The bare bar's appearance is not pinned, and that is deliberate.** It is
/// glass, and the render server flips it from the luminance behind it —
/// `HUDPanel` pins because its labels would invert mid-dictation under a
/// surface the user is not looking at; this is the surface the user *is*
/// looking at, and `rules/design.md` §6.7 says the branch does not generalise.
/// **The docked panel is the one pinned surface:** its wash is not glass and
/// cannot flip itself, so `OverlayPanel` pins the window's appearance from a
/// backdrop sample while a chat is open (`DECISIONS.md`, 2026-09-02), and
/// lifts the pin the moment the bare state returns.
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

    /// **70 % of usable display height, then the conversation scrolls** (Anthony
    /// 2026-08-27 six answers (2) — §5.8's 720 pt companion does not survive
    /// because there is no panel to bound). Replaces the 2026-08-27 placeholder
    /// 320. The window is made this tall once per show and the surface grows
    /// *inside* it — cheaper than resizing on every keystroke and keeps the bottom
    /// edge still without moving the origin.
    /// Primary — optional to allow `NSScreen.main` nil fallback. Clamped to >=320.
    static func maxHeight(for screen: NSScreen?) -> CGFloat {
        let h = (screen?.visibleFrame.height ?? 800) * 0.70
        return max(h, 320)
    }

    static func maxHeight(for screen: NSScreen) -> CGFloat { maxHeight(for: screen as NSScreen?) }
    @available(*, deprecated, message: "Use maxHeight(for:)")
    static let maxHeight: CGFloat = OverlayView.maxHeight(for: NSScreen.main)

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

    /// The wash's top edge above the conversation viewport. The ramp spans
    /// `WashView.feather` (40), so 48 puts full tint 8 pt above the first line
    /// of conversation — Anthony, 2026-09-01: the no-tint→tint change "can
    /// continue increasing another 20 pixels into the chat panel" and should
    /// sit "a little bit higher from the top of the text" than the 24 pt it
    /// had. One edit to change.
    private static let topInset: CGFloat = 48

    /// The docked content's gutter on both sides of the wash. Derived, not
    /// picked: the wash is `columnWidth + 20` and the content is the drawn
    /// 452 pt wide, so an equal gutter is 34. One edit to change.
    private static let sideInset: CGFloat = (WashView.columnWidth + 20 - 452) / 2

    @State private var store = DraftStore.shared
    /// The docked panel's background surface is a user choice (Settings →
    /// Appearance). The default is now a feathered Liquid Glass panel; the wash
    /// is one option among three (`DECISIONS.md`, 2026-09-03).
    @State private var appearance = AppearanceSettings.shared
    @State private var fieldHeight: CGFloat = OverlayView.lineHeight
    /// The draft needs a second line at the inline width (`ComposerField`).
    /// This, not the field's height, is what expands the bar.
    @State private var fieldOverflow = false
    @State private var expanded = false
    @State private var recents: [DraftStore.RecentChat] = []
    @State private var isDropTargeted = false
    /// Bumped after a send so the conversation body re-reads `chat.md`.
    @State private var conversationReload = 0

    private var draft: Draft { store.draft }
    private var textBinding: Binding<String> {
        Binding(get: { store.draft.text }, set: { store.draft.text = $0 })
    }
    private var isDocked: Bool {
        if case .existing = store.draft.target { return true }
        return false
    }
    private var slug: String {
        if case .existing(let slug) = store.draft.target { return slug }
        return ""
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if isDocked {
                dockedPanel
            } else {
                bareBar
            }
        }
        // The panel is taller than the bar so the surface can grow without
        // resizing the window, so the bar has to say where in that canvas it
        // sits: bottom-centred, because growth is upward from a fixed bottom edge
        // (§5.8).
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .onAppear {
            store.applyContinuityIfNeeded()
            recents = store.recentChats(limit: 8)
            // Chips force the stacked shape; the draft's text does not — a
            // one-line restored draft types on the control row like a fresh one
            // (DECISIONS.md 2026-09-01), and the field's own overflow report
            // expands the bar within a tick when the restored text fills it.
            expanded = !store.draft.attachments.isEmpty
        }
        // Per-show refresh: the panel is built once and reused, so `onAppear`
        // above runs a single time per process lifetime while `show()` can run
        // any number — without this the picker keeps the disk snapshot from
        // the first open until the next send. Posted from `OverlayPanel.show()`
        // after continuity resolves; the menu itself opens later, so the list
        // is current whenever it is pulled down.
        .task {
            for await _ in NotificationCenter.default.notifications(named: .sottoOverlayDidShow) {
                recents = store.recentChats(limit: 8)
            }
        }
        // Retarget moves the window, not just the next show: docked is a
        // property of the target (Frame 2 vs Frame 3), so switching chats in
        // the menu has to drag the panel with it or the wash column lands
        // mid-screen.
        .onChange(of: store.draft.target) { _, _ in
            OverlayPanel.shared.reposition()
        }
        .onChange(of: fieldOverflow) { _, overflow in
            if overflow { expanded = true }
        }
        .onChange(of: store.draft.attachments) { _, chips in
            if !chips.isEmpty { expanded = true }
            else if store.draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { expanded = false }
        }
        .onChange(of: store.draft.text) { _, t in
            if t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && store.draft.attachments.isEmpty { expanded = false }
            if store.draft.isEmpty { expanded = false }
        }
        .onChange(of: store.draft.isEmpty) { _, isEmpty in
            if isEmpty { expanded = false }
        }
    }

    /// Frame 3: the centred 600 pt bar, no wash — unchanged by the panel rework
    /// (gap 1's ruling keeps the bare state a floating bar).
    private var bareBar: some View {
        VStack(spacing: 8) {
            GlassEffectContainer(spacing: 0) {
                composer
                    .frame(width: Self.width)
                    // Applied last so it captures the content above it, and the shape
                    // is passed to `in:` rather than clipped afterwards — a later
                    // `.clipShape` would cut the specular edge and the rim refraction
                    // the material draws outside the path (`rules/design.md` §6.1).
                    .glassEffect(Token.Material.overlay, in: Token.shape(radius: Self.radius))
            }
            // The same rim the HUD wears, from the same one implementation.
            .specularRim(radius: Self.radius)
            // Exponential drop shadow — not a single hard edge (B). Needs bottomSlack.
            .shadow(color: Color.black.opacity(0.10), radius: 6, x: 0, y: 4)
            .shadow(color: Color.black.opacity(0.08), radius: 16, x: 0, y: 10)
            .shadow(color: Color.black.opacity(0.05), radius: 32, x: 0, y: 18)
            // Lift bar above window edge so shadow paints — clipped otherwise.
            .padding(.bottom, OverlayPanel.bottomSlack)
        }
        .overlay {
            if isDropTargeted { dropAffordance.frame(width: Self.width) }
        }
        .onDrop(of: [.image, .fileURL, .png, .tiff], isTargeted: $isDropTargeted, perform: handleDrop)
    }

    /// Frame 2, rebuilt per "Chat panel light and dark mode.pdf" (2026-09-01):
    /// a wash field bottom-right, the conversation read-only above the
    /// in-panel composer. **The field reaches the screen's right edge and the
    /// window's bottom edge** (Anthony, 2026-09-01, "I can tell exactly where
    /// the gradient starts") — the old field stopped at the column's own rect,
    /// so its 20 pt feather was cut off before it finished and the edge read
    /// as a seam. The content's insets are unchanged: what moved is the
    /// boundary between wash and world, not the position of anything in it.
    /// The canvas caps it at 70 % of usable height, where the conversation
    /// body becomes the sole scroll region (§5.8).
    private var dockedPanel: some View {
        VStack(spacing: 0) {
            ConversationView(
                slug: slug,
                maxHeight: OverlayView.maxHeight(for: NSScreen.main) - composerReserve,
                reload: conversationReload
            )
            Spacer(minLength: 0).frame(height: 10)
            panelComposer
        }
        .padding(.top, Self.topInset)
        // Equal side insets, so the content is centred on the wash it sits in
        // (Anthony, 2026-09-01: "the chat bar… seems to not be centered
        // compared to the background… needs to be moved right a little bit").
        // It was 24 leading / 44 trailing: the content held the position it had
        // in the old 500 pt field while the field itself grew 20 pt rightward
        // to reach the screen edge, which left it 10 pt left of centre. The
        // drawn 24 pt gutter is what gives way, because the drawing measured it
        // against the narrower field.
        .padding(.horizontal, Self.sideInset)
        .padding(.bottom, 15 + OverlayPanel.bottomSlack)
        .frame(width: WashView.columnWidth + 20)
        .background { panelSurface.allowsHitTesting(false) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .overlay {
            if isDropTargeted { dropAffordance }
        }
        .onDrop(of: [.image, .fileURL, .png, .tiff], isTargeted: $isDropTargeted, perform: handleDrop)
    }

    /// The docked panel's background (Settings → Appearance). `washBlur` is
    /// `WashView` unchanged; the two Liquid Glass options are `GlassPanelView`,
    /// reversing gap 1 — with `liquidBlur` now the default (`DECISIONS.md`,
    /// 2026-09-03).
    @ViewBuilder
    private var panelSurface: some View {
        switch appearance.chatPanelStyle {
        case .liquidBlur:
            GlassPanelView(border: .feathered)
        case .liquidGlass:
            GlassPanelView(border: .crisp)
        case .washBlur:
            WashView()
        }
    }

    /// What the conversation must leave room for below itself: the spacer, the
    /// composer at its *current* shape, and the wash's top and bottom insets.
    /// Was a fixed 150, sized for the inline bar — with a stacked composer the
    /// panel outgrew the canvas and the wash's feathered top edge clipped
    /// against the window top, the same seam class as the truncated-edge bug
    /// that moved the field to the screen edge.
    private var composerReserve: CGFloat {
        10 + composerHeight + Self.topInset + 15 + OverlayPanel.bottomSlack
    }

    private var composerHeight: CGFloat {
        expanded
            ? Self.padTop + fieldHeight + Self.fieldGap + Self.control + Self.padBottom
            : Self.barHeight
    }

    /// **The same chat bar as the bare state, at panel width** (Anthony,
    /// 2026-09-01: the docked composer was its own two-row implementation and
    /// read as a different control — the selector sat beside the text and the
    /// bar grew unbounded because nothing framed the text view). One row to
    /// type in — `+`, field, chat capsule, send — until the line fills, then
    /// the draft moves to the top row and the bottom row keeps only attach,
    /// chat, and send. That is exactly `composer`'s inline→stacked switch, so
    /// the docked state reuses it wholesale; the only docked differences are
    /// the placeholder and the width.
    private var panelComposer: some View {
        GlassEffectContainer(spacing: 0) {
            composer
                .glassEffect(Token.Material.overlay, in: Token.shape(radius: Self.radius))
        }
        .specularRim(radius: Self.radius)
        .shadow(color: Color.black.opacity(0.10), radius: 6, x: 0, y: 4)
        .shadow(color: Color.black.opacity(0.08), radius: 16, x: 0, y: 10)
        .shadow(color: Color.black.opacity(0.05), radius: 32, x: 0, y: 18)
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
            if !store.draft.attachments.isEmpty {
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
            // `placeholderString` key. The drawing names the docked field's
            // placeholder "Ask a follow-up"; the bare bar keeps "Message".
            if store.draft.text.isEmpty {
                Text(isDocked ? "Ask a follow-up" : "Message")
                    .font(.title3)
                    .foregroundStyle(Color(nsColor: .placeholderTextColor))
                    .frame(height: Self.lineHeight)
                    .allowsHitTesting(false)
            }
            ComposerField(
                text: textBinding,
                maxLines: Self.fieldMaxLines,
                height: $fieldHeight,
                overflow: $fieldOverflow,
                onSend: send,
                onImagePaste: { data, name in store.addImage(filename: name, data: data) }
            )
        }
    }

    /// §5.8 menu — file, screenshot. **Paste path is Cmd+V
    /// (ComposerField.handleImagePaste). No generic image button here.**
    /// Screenshot capture is feasible via CGWindowList/ScreenCaptureKit but
    /// deferred — shown disabled per gate preference (requires Screen
    /// Recording, don't prompt). Attach Selection is deliberately absent: a
    /// selection reaches the draft through the §4.9 dictation flow, not the
    /// menu (Anthony, 2026-09-01).
    private var addContext: some View {
        Menu {
            Button("Add File…") { pickFile() }
            // Feasible via CGWindowList / ScreenCaptureKit (requires Screen
            // Recording). Shown disabled until capture ships — no prompt now.
            Button("Screenshot of Last Focused Window") {}
                .disabled(true)
            if !store.draft.attachments.isEmpty {
                Divider()
                Button("Clear All", role: .destructive) {
                    store.setAttachments([])
                }
            }
        } label: {
            Image(systemName: "plus")
                // Same style as the field it sits beside, so the glyph tracks the
                // text rather than a number: `.title3` is 15 pt.
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: Self.control, height: Self.control)
                .contentShape(.rect)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    private func pickFile() {
        // Overlay is at .statusBar (25) and would occlude the open panel at
        // .modalPanel (8). Hide it for the modal, then restore.
        let wasVisible = OverlayPanel.shared.isVisible
        if wasVisible { OverlayPanel.shared.hide() }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        let result = panel.runModal()
        if result == .OK, let url = panel.url, let data = try? Data(contentsOf: url) {
            store.addImage(filename: url.lastPathComponent, data: data)
        }
        if wasVisible {
            // Restore on next runloop so panel ordering settles.
            DispatchQueue.main.async { OverlayPanel.shared.show() }
        }
    }

    /// §14.3 rejects a *saturated* send button, not a send button, and no
    /// accent colour yet (Anthony, 2026-09-01: "keep the ruling but change the
    /// percentage — the circle is too subtle"). 12 % ink behind an 80 % ink
    /// glyph is one step up from gap 3's 7 %/60 %; a ChatGPT-style lighter
    /// outer circle is the named next step, still without colour. The ChatGPT
    /// circle shipped and was reverted the same day (Anthony: "revert your
    /// changes with the bar") — it was built on a misreading of the
    /// blurrier-on-typing report, and the focus-loss regression that came with
    /// it needs diagnosing first.
    private var sendButton: some View {
        Button(action: send) {
            Image(systemName: "arrow.up")
                // `.callout` is 12 pt — the HUD's own precedent for reaching a
                // size through a named style (`DECISIONS.md`, 2026-08-18).
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary.opacity(0.8))
                .frame(width: Self.control, height: Self.control)
                .background(.primary.opacity(0.12), in: .circle)
        }
        .buttonStyle(.plain)
        .disabled(store.draft.isEmpty)
        // Return has two paths to `send()` — this shortcut through the key-
        // equivalent pass, and ComposerField's `insertNewline` through the
        // first responder. Whichever fires first empties the draft
        // synchronously, so the other hits `send()`'s empty guard: one press,
        // one turn.
        .keyboardShortcut(.return, modifiers: [])
    }

    /// Attachments wrap above the field and count toward intrinsic height (§5.8).
    /// Accent is on the chips and the caret and nowhere else, per Frame 1's
    /// caption — `Color.accentColor` is `controlAccentColor`, so the design's
    /// `#0A84FF` stays a stand-in and is never typed.
    /// Each chip has dismiss — correctness, not convenience (§4.9 accidental attachment).
    private var chips: some View {
        WrapLayout(spacing: 6, lineSpacing: 6) {
            ForEach(Array(store.draft.attachments.enumerated()), id: \.element.id) { index, att in
                HStack(spacing: 5) {
                    Text(att.chipLabel).font(.callout).lineLimit(1)
                    Button {
                        store.removeAttachment(at: index)
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

    /// Names the current target and opens the recent-chat list (§5.3).
    /// **`New chat` is the placeholder when no chat is selected**
    /// (Anthony's ruling) — not hidden and not disabled, because the control is
    /// how you reach an older chat with continuity off, so it can never be the
    /// thing that is missing.
    ///
    /// **The list is a native `Menu`, not the drawn custom panel** (Anthony,
    /// 2026-09-01: same style as the `+` menu) — `rules/design.md` §1's rule:
    /// macOS already draws menus. The label keeps the drawn capsule; the popup
    /// is the system's, so no custom rows, checkmarks, or material here. The
    /// chevron is static — a `Menu` exposes no open state to mirror.
    ///
    /// `recents` is cached and refreshed on appear, on every show, and after
    /// send rather than read in the menu content: body re-evaluates on every
    /// keystroke, and `recentChats` parses every `chat.md` on disk each call.
    private var chatControl: some View {
        Menu {
            Button("New chat") { store.setTarget(.new) }
            Divider()
            if recents.isEmpty {
                Button("No recent chats") {}
                    .disabled(true)
            } else {
                ForEach(recents) { chat in
                    Button(chat.title ?? chat.slug) {
                        store.setTarget(.existing(slug: chat.slug))
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(pickerLabel)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.down")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: Self.control)
            .background(.primary.opacity(0.07), in: .capsule)
            .fixedSize()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    private var pickerLabel: String {
        switch store.draft.target {
        case .new: return "New chat"
        case .existing(let slug): return slug
        }
    }

    /// Drag-then-summon affordance — subtle, inside the bar (§5.5).
    /// Accent wash + dashed border only; no label — color change is enough.
    /// Distinct from HUD's "Copied to clipboard" morph (bottom, solid, fades).
    private var dropAffordance: some View {
        Token.shape(radius: Self.radius)
            .fill(Color.accentColor.opacity(0.08))
            .overlay {
                Token.shape(radius: Self.radius)
                    .strokeBorder(Color.accentColor.opacity(0.45), style: StrokeStyle(lineWidth: 1.25, dash: [6, 5]))
            }
            .allowsHitTesting(false)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        for p in providers {
            if p.hasItemConformingToTypeIdentifier("public.image") {
                p.loadDataRepresentation(forTypeIdentifier: "public.image") { data, _ in
                    if let data { Task { @MainActor in store.addImage(filename: "dropped-\(UUID().uuidString.prefix(4)).png", data: data) } }
                }
                return true
            }
            if p.hasItemConformingToTypeIdentifier("public.file-url") {
                p.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                    if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil),
                       let fileData = try? Data(contentsOf: url) {
                        let name = url.lastPathComponent
                        Task { @MainActor in store.addImage(filename: name, data: fileData) }
                    } else if let url = item as? URL, let fileData = try? Data(contentsOf: url) {
                        Task { @MainActor in store.addImage(filename: url.lastPathComponent, data: fileData) }
                    }
                }
                return true
            }
        }
        return false
    }

    /// Commits draft to a chat folder — attachments serialize before text (§5.2).
    private func send() {
        let trimmed = store.draft.serializedMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Resolve model — current chat model if available, else apple-foundation.
        let modelID = UserDefaults.standard.string(forKey: "ChatModelID") ?? "apple-foundation"
        do {
            _ = try store.send(modelID: modelID)
            expanded = false
            recents = store.recentChats(limit: 8)
            conversationReload += 1
        } catch {
            // Empty is guarded above, so a throw here is a real disk failure:
            // the chat folder was not written and the draft is untouched, but
            // the user saw nothing happen. Logged for diagnosis; a user-visible
            // error surface for send failures is a later question.
            DraftStore.log.error("Send failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// A wrapping row. There is no system layout for this — `HStack` does not wrap,
/// `Grid` is fixed-column, and `ViewThatFits` picks one child rather than
/// flowing them — so it is written once here, for the consumers that need it
/// (chips in both composers, image chips in the conversation body).
struct WrapLayout: Layout {
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
