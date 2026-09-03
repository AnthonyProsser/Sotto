//
//  ChatWorkspace.swift
//  Sotto
//
//  Slice 10. The Chat half of §10.2 — chat list, conversation, and the
//  composer that makes the window a full chat surface. The Audio twin is
//  `AudioWorkspace`; the two sidebars are the same control in two modes, and
//  the turn anatomy is `ConversationTurnView`'s, shared with the docked
//  panel.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Sidebar

/// §10.2's chat list: pinned first, newest first, searched by the mode-scoped
/// field `MainWindowView` applies.
struct ChatSidebar: View {
    @Bindable var library: ChatLibrary

    @State private var pendingDelete: ChatLibrary.Chat?

    var body: some View {
        VStack(spacing: 0) {
            newChat
            list
        }
    }

    /// The slot the disabled `Transcribe File…` stub holds on the Audio side —
    /// the sidebar's action, not the detail pane's (2026-08-23, `DECISIONS.md`),
    /// and the twin it was reserved for. Enabled, because the chat engine is
    /// this slice's cargo.
    private var newChat: some View {
        Button {
            library.selection = nil
            ChatConversations.shared.beginNew()
        } label: {
            Label("New Chat", systemImage: "square.and.pencil")
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
        // The list scrolls under nothing — it clips at its own top edge — so
        // this gap is the whole separation between the action and the first
        // row, and at 8 a scrolled row came within a hair of the label. 14 is
        // the same figure on both sidebars; they are one control in two modes
        // (§10.2) and must not drift.
        .padding(.bottom, 14)
    }

    private var list: some View {
        List(library.visible, selection: $library.selection) { chat in
            ChatRow(chat: chat)
                .tag(chat.id)
                .contextMenu {
                    Button(chat.pinned ? "Unpin" : "Pin") {
                        library.togglePin(chat)
                    }
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([chat.folder])
                    }
                    Divider()
                    Button("Delete…", role: .destructive) {
                        pendingDelete = chat
                    }
                }
        }
        .listStyle(.sidebar)
        .overlay { emptyState }
        // The system's own destructive-action sheet — the Audio sidebar's
        // ruling applies here verbatim: a question asked because the user just
        // pressed Delete, not §2's interrupted-work kind of modal.
        .confirmationDialog(
            "Delete this chat?",
            isPresented: .init(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { chat in
            Button("Delete", role: .destructive) { library.delete(chat) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The conversation and its attachments are removed from disk. This cannot be undone.")
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if library.visible.isEmpty {
            if !library.search.isEmpty {
                ContentUnavailableView.search(text: library.search)
            } else {
                ContentUnavailableView(
                    "No Chats",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("New Chat starts one. Sends from the overlay land here too.")
                )
            }
        }
    }
}

/// Title, date, snippet, pin — the row's four, in the RecordingRow order.
/// The title is derived (`ChatLibrary.Chat.title`): frontmatter's when a
/// writer set one, else the first user message, else the slug.
struct ChatRow: View {
    let chat: ChatLibrary.Chat

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text(chat.title)
                    .lineLimit(1)
                if chat.pinned {
                    Image(systemName: "pin.fill")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Pinned")
                }
            }

            HStack {
                Text(chat.updated.formatted(date: .abbreviated, time: .shortened))
                Text(chat.snippet)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Detail

/// The conversation and its composer. The active conversation is the selected
/// chat's live session — hydrated from disk on selection — or, when nothing is
/// selected, the New Chat that has not been committed yet.
struct ChatDetail: View {
    @Bindable var library: ChatLibrary

    @State private var text = ""
    @State private var attachments: [Draft.Attachment] = []

    /// The conversation the pane renders. Reads are tracked through the
    /// observable registry; creation happens in `hydrate`, off the body.
    ///
    /// **Keyed on the selection, not on `library.selected`.** A chat that has
    /// just been sent is selected before its folder exists, so the library has
    /// no row for it for the length of the first generation; the registry does.
    private var active: ChatConversation? {
        if let id = library.selection {
            return ChatConversations.shared.conversation(for: id)
        }
        return ChatConversations.shared.pendingNew
    }

    /// The window title. The library row's title once there is one, the live
    /// conversation's own derivation while there is not, and "New Chat" only
    /// when nothing has been sent — it was the last of those unconditionally
    /// for any chat the library had not caught up with.
    private var title: String {
        if let chat = library.selected { return chat.title }
        if let active, !active.title.isEmpty { return active.title }
        return "New Chat"
    }

    var body: some View {
        VStack(spacing: 0) {
            if let conversation = active {
                if conversation.messages.isEmpty && !conversation.isGenerating {
                    // New Chat: the bar and nothing else — no title copy, no
                    // empty-state prose (Anthony, Slice 10). Centred at the
                    // overlay's column width. The first send appends the user
                    // turn synchronously, so this branch flips to the
                    // conversation on the same runloop.
                    composer(conversation)
                        .frame(maxWidth: OverlayView.width)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    if let failure = conversation.failure {
                        FailureBanner(message: failure) { conversation.failure = nil }
                        Divider()
                    }
                    body(conversation)
                    composer(conversation)
                }
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbar {
            if let chat = library.selected {
                ToolbarItem(placement: .primaryAction) { pinButton(chat) }
            }
        }
        .onChange(of: library.selection, initial: true) { _, _ in
            hydrate()
        }
        .onChange(of: active?.id) { _, _ in
            // A different pane, a different draft — the overlay's draft rules
            // do not reach here, and half-typed text in one chat must not
            // commit to another.
            text = ""
            attachments = []
        }
    }

    private func hydrate() {
        if let chat = library.selected {
            _ = ChatConversations.shared.open(chat)
        } else if ChatConversations.shared.pendingNew == nil {
            // Nothing selected and no pending New Chat yet — the window opened
            // straight onto Chat mode. `active` reads `pendingNew`, so it has
            // to exist before the first body pass renders the centred bar.
            ChatConversations.shared.beginNew()
        }
    }

    /// The pin belongs to the chat on disk, so it shows only for a committed
    /// chat — a New Chat has no row and nothing to pin. In the window's
    /// toolbar now, beside the title the same move put there (Slice 10).
    private func pinButton(_ chat: ChatLibrary.Chat) -> some View {
        Button {
            library.togglePin(chat)
        } label: {
            Image(systemName: chat.pinned ? "pin.fill" : "pin")
        }
        .foregroundStyle(chat.pinned ? AnyShapeStyle(Token.Accent.primary) : AnyShapeStyle(.secondary))
        .help(chat.pinned ? "Unpin" : "Pin — kept first in the list")
        .accessibilityLabel(chat.pinned ? "Unpin chat" : "Pin chat")
    }

    /// The window title's second line: the selected chat's timestamp, empty
    /// for a New Chat. `.navigationSubtitle` is text only, which is why the
    /// pin is a toolbar item rather than part of this.
    private var subtitle: String {
        guard let chat = library.selected else { return "" }
        return chat.updated.formatted(date: .abbreviated, time: .shortened)
    }

    private func composer(_ conversation: ChatConversation) -> some View {
        ChatComposer(
            text: $text,
            attachments: $attachments,
            isGenerating: conversation.isGenerating,
            onSend: { send(to: conversation) },
            onStop: { conversation.stop() }
        )
    }

    /// The plain scroll the window wants — the docked panel's fade and
    /// height-hugging are wash-specific. Follows the stream unless the user
    /// scrolls away, the same rule `ConversationView` runs.
    private func body(_ conversation: ChatConversation) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(conversation.renderableTurns) { turn in
                        ConversationTurnView(turn: turn).id(turn.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                max(0, geometry.contentOffset.y + geometry.contentInsets.top)
            } action: { old, offset in
                if offset < old - 4 { detached = true }
                scrollOffset = offset
            }
            .onChange(of: conversation.messages.count) { _, _ in
                detached = false
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: conversation.streamingText) { _, _ in
                guard !detached else { return }
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    @State private var scrollOffset: CGFloat = 0
    @State private var detached = false

    // MARK: - Send

    /// The commit is the same one the overlay makes — `commitAndGenerate` —
    /// so a chat continued here and one continued in the panel are the same
    /// records. A failed commit leaves the draft typed, with the banner
    /// naming why.
    private func send(to conversation: ChatConversation) {
        let draft = Draft(text: text, attachments: attachments)
        let content = draft.serializedContent()
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let modelID = UserDefaults.standard.string(forKey: "ChatModelID") ?? "apple-foundation"
        _ = conversation.commitAndGenerate(
            content: content,
            images: draft.imageAttachments(),
            modelID: modelID
        )
        if conversation.failure == nil {
            text = ""
            attachments = []
        }
    }
}

// MARK: - Composer

/// The window's composer: chips, field, control row — Frame 2's stacked
/// shape at pane width, with the same field, chips, add menu, and send
/// control the overlay composes from. No chat picker (§6.4: inside the app
/// the sidebar is the target), and one shape rather than the overlay's
/// inline→stacked pair — a wide pane has no narrow line to overflow.
private struct ChatComposer: View {
    @Binding var text: String
    @Binding var attachments: [Draft.Attachment]
    let isGenerating: Bool
    let onSend: () -> Void
    let onStop: () -> Void

    @State private var fieldHeight: CGFloat = ComposerField.lineHeight
    /// The inline→stacked trigger on the overlay; always stacked here, so
    /// bound and ignored.
    @State private var fieldOverflow = false

    private static let pad: CGFloat = 13
    private static let chipsGap: CGFloat = 11
    private static let fieldGap: CGFloat = 15
    private static let gap: CGFloat = 12
    /// Six lines, then internal scroll (§5.8).
    private static let fieldMaxLines = 6

    var body: some View {
        // The overlay's docked composer, wholesale (§0.3): the same single
        // glass bar, specular rim, and three-stop shadow as
        // `OverlayView.panelComposer`, at pane width. The conversation list
        // above it is unchanged — the glass is the chat bar only (Anthony,
        // Slice 10).
        GlassEffectContainer(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                if !attachments.isEmpty {
                    ComposerChips(attachments: attachments) { attachments.remove(at: $0) }
                    Spacer(minLength: 0).frame(height: Self.chipsGap)
                }
                field
                Spacer(minLength: 0).frame(height: Self.fieldGap)
                HStack(spacing: Self.gap) {
                    addContext
                    Spacer(minLength: 0)
                    sendControl
                }
            }
            .padding(Self.pad)
            .glassEffect(Token.Material.overlay, in: Token.shape(radius: OverlayView.radius))
        }
        .specularRim(radius: OverlayView.radius)
        .shadow(color: Color.black.opacity(0.10), radius: 6, x: 0, y: 4)
        .shadow(color: Color.black.opacity(0.08), radius: 16, x: 0, y: 10)
        .shadow(color: Color.black.opacity(0.05), radius: 32, x: 0, y: 18)
        .padding(.horizontal)
        .padding(.bottom)
    }

    private var field: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text("Message")
                    .font(.title3)
                    .foregroundStyle(Color(nsColor: .placeholderTextColor))
                    .frame(height: ComposerField.lineHeight)
                    .allowsHitTesting(false)
            }
            ComposerField(
                text: $text,
                maxLines: Self.fieldMaxLines,
                height: $fieldHeight,
                overflow: $fieldOverflow,
                // Return during generation does nothing — the stop control is
                // the explicit route, and a habitual Return must not kill the
                // reply.
                onSend: isGenerating ? {} : onSend,
                onImagePaste: { data, name in
                    attachments.append(.image(id: UUID(), filename: name, data: data))
                }
            )
            .frame(height: fieldHeight)
        }
    }

    private var addContext: some View {
        ComposerAddMenu(
            onAddFile: pickFile,
            hasAttachments: !attachments.isEmpty,
            onClear: { attachments.removeAll() }
        )
    }

    @ViewBuilder
    private var sendControl: some View {
        if isGenerating {
            ComposerSendButton(isGenerating: true, action: onStop)
        } else {
            ComposerSendButton(action: onSend)
                .disabled(
                    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && attachments.isEmpty
                )
        }
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK, let url = panel.url,
           let data = try? Data(contentsOf: url) {
            attachments.append(.image(id: UUID(), filename: url.lastPathComponent, data: data))
        }
    }
}
