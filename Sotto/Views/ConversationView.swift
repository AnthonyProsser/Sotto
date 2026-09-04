//
//  ConversationView.swift
//  Sotto
//
//  Slice 9. The conversation body inside the docked panel — "Chat panel light
//  and dark mode.pdf" (2026-09-01). Slice 10 adds the live path: when a chat
//  is open somewhere, its conversation renders from the open session and the
//  turn streaming right now appears as it types itself. The turn anatomy is
//  one implementation shared with the main window's pane
//  (`ConversationTurnView`).
//

import SwiftUI

/// One rendered turn, parsed back out of a stored message — the exact inverse
/// of `Draft.serializedContent()`, which wrote it. `model` and `failure` ride
/// the turn for §9.1's attribution and §14.3's inline failure line.
struct ConversationTurn: Identifiable {
    let id: UUID
    let isUser: Bool
    var model: String? = nil
    var sources: [Source] = []
    var images: [String] = []
    var text: String = ""
    /// A generation failure attached to this turn (§14.3) — slice 10's live
    /// layer sets it on the in-flight turn; stored turns never carry one,
    /// because a failed turn is not committed.
    var failure: String? = nil
    /// True while the turn exists only as awaiting tokens: the ellipsis state.
    var pending: Bool = false

    /// Stable identity for the in-flight pseudo-turn, so token updates mutate
    /// one view instead of tearing it down per delta.
    static let streamingID = UUID()

    struct Source: Identifiable {
        let id = UUID()
        let app: String
        let text: String
    }

    /// Splits a stored message back into sources, images, and the remaining
    /// text.
    static func from(_ message: ChatMessage) -> ConversationTurn? {
        switch message.role {
        case .user, .assistant:
            var turn = ConversationTurn(id: message.id, isUser: message.role == .user, model: message.model)
            var rest = message.content

            // Fenced selection blocks — the fence is as long as the content
            // needs (CommonMark's longer-fence rule), so match the run.
            if let regex = try? NSRegularExpression(pattern: "(`{3,})selection app=\"((?:[^\"\\\\]|\\\\.)*)\"\\n([\\s\\S]*?)\\n\\1") {
                let full = NSRange(rest.startIndex..., in: rest)
                var sourceRanges: [Range<String.Index>] = []
                regex.enumerateMatches(in: rest, range: full) { match, _, _ in
                    guard let match else { return }
                    if let appRange = Range(match.range(at: 2), in: rest),
                       let textRange = Range(match.range(at: 3), in: rest) {
                        let app = rest[appRange]
                            .replacingOccurrences(of: "\\\"", with: "\"")
                            .replacingOccurrences(of: "\\\\", with: "\\")
                        turn.sources.append(Source(app: app, text: rest[textRange].trimmingCharacters(in: .whitespacesAndNewlines)))
                    }
                    if let r = Range(match.range, in: rest) { sourceRanges.append(r) }
                }
                for range in sourceRanges.reversed() {
                    rest = rest.replacingCharacters(in: range, with: "")
                }
            }

            // Image attachments as written by `serializedContent`.
            if let regex = try? NSRegularExpression(pattern: "!\\[[^\\]]*\\]\\(attachments/([^)]+)\\)") {
                let full = NSRange(rest.startIndex..., in: rest)
                var imageRanges: [Range<String.Index>] = []
                regex.enumerateMatches(in: rest, range: full) { match, _, _ in
                    guard let match, let nameRange = Range(match.range(at: 1), in: rest) else { return }
                    turn.images.append(String(rest[nameRange]))
                    if let r = Range(match.range, in: rest) { imageRanges.append(r) }
                }
                for range in imageRanges.reversed() {
                    rest = rest.replacingCharacters(in: range, with: "")
                }
            }

            turn.text = rest.trimmingCharacters(in: .whitespacesAndNewlines)
            return turn
        case .system, .tool:
            // Tool rendering is slice 12's — no tools exist until MCP lands, so
            // the seam stays here rather than a treatment designed twice.
            return nil
        }
    }
}

/// The drawn turn anatomy, one implementation for both surfaces: `YOU` /
/// `SOTTO` label, quoted source line on a 2 pt accent rule, question,
/// semibold answer.
struct ConversationTurnView: View {
    let turn: ConversationTurn

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Both sides are labelled the same way now (Anthony, Slice 10) — the
            // user's turn says "YOU" exactly as the reply says "SOTTO", same
            // caption weight and tracking. The model sub-label stays on the
            // reply only: §9.1's per-turn attribution, quieter than the label.
            HStack(spacing: 6) {
                Text(turn.isUser ? "YOU" : "SOTTO")
                    .font(.caption.weight(.medium))
                    .tracking(1.5)
                    .foregroundStyle(.secondary)
                if !turn.isUser, let model = turn.model {
                    Text(Self.modelLabel(model))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            ForEach(turn.sources) { source in
                // Decision 40's anatomy: the quoted source line on a 2 pt
                // accent rule, nothing drawn around it.
                HStack(alignment: .top, spacing: 8) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.accentColor)
                        .frame(width: 2)
                    Text(source.text)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            if !turn.images.isEmpty {
                WrapLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(turn.images, id: \.self) { name in
                        HStack(spacing: 4) {
                            Image(systemName: "photo").font(.caption2)
                            Text(name).font(.caption).lineLimit(1)
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.primary.opacity(0.06), in: .capsule)
                    }
                }
            }
            if !turn.text.isEmpty {
                Text(turn.text)
                    .font(turn.isUser ? .body : .body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            } else if turn.pending {
                // First token not arrived: listening, not frozen. Text, not a
                // spinner — the conversation's type is the only vocabulary it
                // has.
                Text("…")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            if let failure = turn.failure {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                    Text(failure)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// `mlx-community/Qwen3-8B-4bit` renders as `Qwen3-8B-4bit`; the frontmatter
    /// keeps the full id.
    static func modelLabel(_ model: String) -> String {
        model.split(separator: "/").last.map(String.init) ?? model
    }
}

/// The conversation body of the docked panel: past turns parsed back out of
/// the chat's `chat.md` — or, when the chat is open live, out of the open
/// session — rendered in the drawn anatomy. The field's top edge sits
/// `OverlayView.topInset` above the first line (the tint ramp completes just
/// above the text) up to the 70 % ceiling; past it, this is the sole scroll
/// region (§5.8). Scrolled-away turns dissolve through a fade at the
/// viewport's top edge instead of clipping hard against it.
struct ConversationView: View {
    let slug: String
    /// 70 % ceiling minus the composer's own height — the most this body may
    /// take before it scrolls.
    let maxHeight: CGFloat
    /// Bumped by the parent after a send, so the turn just committed appears
    /// when the chat is not open live.
    var reload: Int = 0
    /// The open conversation for this chat, when one exists — its turns render
    /// as they are, including the turn streaming right now. `nil` reads
    /// `chat.md`, the pre-slice-10 behaviour.
    var live: ChatConversation?

    /// The height of the top fade — how much viewport the dissolve takes,
    /// about two `.body` line boxes. One edit to change.
    private static let fadeHeight: CGFloat = 30

    @State private var diskTurns: [ConversationTurn] = []
    /// The measured height of the body, so the scroll region hugs short
    /// conversations instead of pinning the field at its ceiling.
    @State private var contentHeight: CGFloat = 0
    /// Distance scrolled from the content top — drives the top fade.
    @State private var scrollOffset: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    /// Set when the user scrolls up mid-stream; streaming stops following them
    /// until they return to the bottom.
    @State private var detached = false

    private var turns: [ConversationTurn] {
        live?.renderableTurns ?? diskTurns
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(turns) { turn in
                        ConversationTurnView(turn: turn).id(turn.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 24)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight = $0 }
            }
            .frame(height: min(contentHeight + 1, maxHeight))
            .mask { topFade }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                viewportHeight = geometry.containerSize.height
                // Insets are zero here, but the sum is the honest offset, and
                // rubber-banding past the top goes negative — clamp to rest.
                return max(0, geometry.contentOffset.y + geometry.contentInsets.top)
            } action: { old, offset in
                // A deliberate upward scroll detaches the follow; the bottom
                // reattaches. Content growth does not move the offset, so it
                // cannot falsely detach mid-stream.
                if offset < old - 4 { detached = true }
                scrollOffset = offset
                if contentHeight - scrollOffset - viewportHeight < 40 { detached = false }
            }
            .onAppear {
                load(scroll: false, proxy: proxy)
                // The docked panel opens at the newest turn, whether it is a
                // live session or a disk read — `load`'s own scroll only fires
                // for the disk path, so the jump is unconditional here.
                jumpToBottom(proxy)
            }
            // Opening the overlay onto a chat that was already docked does not
            // remount this view, so `onAppear` can't be the only hook — the
            // panel posts on every show and this lands the newest turn each time.
            .onReceive(NotificationCenter.default.publisher(for: .sottoOverlayDidShow)) { _ in
                jumpToBottom(proxy)
            }
            .onChange(of: slug) { _, _ in load(scroll: false, proxy: proxy) }
            .onChange(of: reload) { _, _ in load(scroll: true, proxy: proxy) }
            // A committed turn ends the follow question — always jump.
            .onChange(of: live?.messages.count) { _, _ in
                detached = false
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            // Stream follows the bottom unless the user scrolled away.
            .onChange(of: live?.streamingText ?? "") { _, _ in
                guard !detached else { return }
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    /// The top fade: clear at the viewport's top edge, opaque `fadeHeight`
    /// down. The ramp's height grows in with the first `fadeHeight` points of
    /// scroll, so a turn scrolling out dissolves continuously instead of
    /// clipping (Anthony, 2026-09-01) and an unscrolled conversation is
    /// untouched. The stop location is a fraction of the viewport, which is
    /// `maxHeight` whenever there is anything to scroll.
    private var topFade: some View {
        Rectangle().fill(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black,
                          location: min(scrollOffset, Self.fadeHeight)
                              / max(min(contentHeight + 1, maxHeight), 1)),
                ],
                startPoint: .top, endPoint: .bottom
            )
        )
    }

    /// Land on the newest turn after the layout pass settles. `detached` is
    /// cleared so a stream that arrives next keeps following.
    private func jumpToBottom(_ proxy: ScrollViewProxy) {
        detached = false
        DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
    }

    private func load(scroll: Bool, proxy: ScrollViewProxy) {
        guard live == nil else { return }
        let url = ChatFolder.root.appendingPathComponent(slug, isDirectory: true)
            .appendingPathComponent("chat.md")
        guard let md = try? String(contentsOf: url, encoding: .utf8),
              let state = try? ChatSerializer.deserialize(markdown: md, defaultSlug: slug) else {
            diskTurns = []
            return
        }
        diskTurns = state.messages.compactMap { ConversationTurn.from($0) }
        if scroll {
            DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }
}
