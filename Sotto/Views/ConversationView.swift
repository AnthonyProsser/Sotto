//
//  ConversationView.swift
//  Sotto
//
//  Slice 9. Read-only history inside the chat panel — "Chat panel light and
//  dark mode.pdf" (2026-09-01). Generation does not exist yet, so assistant
//  turns render only if a chat file carries one; today send writes user turns
//  alone.
//

import SwiftUI

/// The conversation body of the docked panel: past turns parsed back out of
/// the chat's `chat.md`, rendered in the drawn anatomy — quoted source line on
/// a 2 pt accent rule, question, `SOTTO` label, semibold answer. The field's
/// top edge hugs this content (24 pt above the first line, parent padding) up
/// to the 70 % ceiling; past it, this is the sole scroll region (§5.8).
struct ConversationView: View {
    let slug: String
    /// 70 % ceiling minus the composer's own height — the most this body may
    /// take before it scrolls.
    let maxHeight: CGFloat
    /// Bumped by the parent after a send, so the turn just committed appears.
    var reload: Int = 0

    /// One rendered turn. `sources` and `images` come back out of the draft
    /// serialization — fenced `selection` blocks and attachment markdown.
    struct Turn: Identifiable {
        let id: UUID
        let isUser: Bool
        var sources: [Source] = []
        var images: [String] = []
        var text: String = ""
    }

    struct Source: Identifiable {
        let id = UUID()
        let app: String
        let text: String
    }

    @State private var turns: [Turn] = []
    /// The measured height of the body, so the scroll region hugs short
    /// conversations instead of pinning the field at its ceiling.
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(turns) { turn in
                        turnView(turn).id(turn.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 24)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight = $0 }
            }
            .frame(height: min(contentHeight + 1, maxHeight))
            .onAppear { load(scroll: false, proxy: proxy) }
            .onChange(of: slug) { _, _ in load(scroll: false, proxy: proxy) }
            .onChange(of: reload) { _, _ in load(scroll: true, proxy: proxy) }
        }
    }

    @ViewBuilder
    private func turnView(_ turn: Turn) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !turn.isUser {
                Text("SOTTO")
                    .font(.caption.weight(.medium))
                    .tracking(1.5)
                    .foregroundStyle(.secondary)
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
            }
        }
    }

    private func load(scroll: Bool, proxy: ScrollViewProxy) {
        let url = ChatFolder.root.appendingPathComponent(slug, isDirectory: true)
            .appendingPathComponent("chat.md")
        guard let md = try? String(contentsOf: url, encoding: .utf8),
              let state = try? ChatSerializer.deserialize(markdown: md, defaultSlug: slug) else {
            turns = []
            return
        }
        turns = state.messages.compactMap { turn(from: $0) }
        if scroll {
            DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    /// Splits a stored message back into sources, images, and the remaining
    /// text — the exact inverse of `Draft.serializedContent()`, which wrote it.
    private func turn(from message: ChatMessage) -> Turn? {
        switch message.role {
        case .user, .assistant:
            var turn = Turn(id: message.id, isUser: message.role == .user)
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
            return nil
        }
    }
}
