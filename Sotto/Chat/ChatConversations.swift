//
//  ChatConversations.swift
//  Sotto
//
//  Slice 10. The live layer over slice 7's engine — the first surface code in
//  the app to call it. Both the main window's detail pane and the overlay's
//  docked panel render the same instance for the same chat, so a reply
//  streamed in one place appears in the other without a reload.
//
//  **One writer.** `ChatSession` (actor) is the only thing that appends turns
//  and rewrites `chat.md`. Before this layer, the overlay's send did its own
//  read-modify-write of the file, which would clobber an in-flight session's
//  save; every send now goes through here.
//

import Foundation
import Observation
import os

/// One open chat: the committed turns, the turn streaming right now, and the
/// failure state §14.3 routes here. Rendering reads `turns` plus the in-flight
/// pseudo-turn (`streamingText` / `turnFailure`), parsed by `ConversationTurn`.
@MainActor
@Observable
final class ChatConversation {

    nonisolated let id: UUID
    /// Empty until the first commit names the chat — a new conversation lives
    /// in memory only, and the sidebar shows it once the folder exists.
    private(set) var slug: String

    private(set) var messages: [ChatMessage] = []
    /// The assistant turn in flight; `.token` deltas append here. Cleared when
    /// the turn's `.message` record lands, which supersedes it.
    private(set) var streamingText = ""
    private(set) var streamingModel: String?
    private(set) var isGenerating = false
    /// §14.3: a generation failure rendered inline, attached to the turn that
    /// failed — never a notification, never a modal.
    private(set) var turnFailure: String?

    /// §14.3's banner slot: model unavailable / load failure, at the top of the
    /// chat surface. Generation failures go to the turn instead, so they stay
    /// beside what the user just asked.
    var failure: String?

    private var session: ChatSession?
    private var task: Task<Void, Never>?

    private static let log = Logger(subsystem: "com.anthonyprosser.Sotto", category: "chat-conversation")

    /// `state` nil makes a new, unsaved conversation; otherwise this opens a
    /// persisted chat with its record intact.
    init(state: ChatSessionState?) {
        if let state {
            id = state.id
            slug = state.slug
            messages = state.messages
        } else {
            id = UUID()
            slug = ""
        }
        initialState = state
    }

    /// Carries a persisted chat's record into the engine session at first use —
    /// created lazily, on the first commit, because `slug` is decided there.
    private let initialState: ChatSessionState?

    var isEmpty: Bool { messages.isEmpty && streamingText.isEmpty && !isGenerating }

    /// What a surface calls this chat before the library has a row for it —
    /// the same derivation the sidebar row uses, so the title bar and the row
    /// cannot disagree once the folder lands. Empty until the first turn,
    /// which is the caller's cue to say "New Chat".
    var title: String {
        messages.isEmpty ? "" : ChatSessionState.derivedTitle(title: nil, messages: messages, slug: slug)
    }

    /// The committed turns for rendering. Parse is the exact inverse of what
    /// `Draft.serializedContent()` wrote, so slices 9's file format renders
    /// unchanged.
    var turns: [ConversationTurn] { messages.compactMap { ConversationTurn.from($0) } }

    /// `turns` plus the in-flight pseudo-turn — the one rendering source for
    /// both surfaces, so the streaming reply looks the same in the window and
    /// in the docked panel.
    var renderableTurns: [ConversationTurn] {
        var all = turns
        if isGenerating || !streamingText.isEmpty || turnFailure != nil {
            all.append(ConversationTurn(
                id: ConversationTurn.streamingID,
                isUser: false,
                model: streamingModel,
                text: streamingText,
                failure: turnFailure,
                pending: isGenerating && streamingText.isEmpty && turnFailure == nil
            ))
        }
        return all
    }

    var folderURL: URL { ChatFolder.root.appendingPathComponent(slug, isDirectory: true) }

    // MARK: - Send

    /// Commits the user turn and starts generation. Returns the chat's slug,
    /// or nil when the commit failed — `failure` names it, and the caller's
    /// draft is left the way `DraftStore.send` left it on a throw: untouched.
    ///
    /// Runs synchronously up to the stream handoff so the user turn is on
    /// screen and the draft can be cleared before the first token arrives.
    @discardableResult
    func commitAndGenerate(content: String, images: [String: Data], modelID: String) -> String? {
        if isGenerating { return nil }
        failure = nil
        turnFailure = nil

        if !images.isEmpty {
            do {
                try ChatFolder.write(images, to: folderURL)
            } catch {
                failure = "Couldn't save the attachment: \(error.localizedDescription)"
                return nil
            }
        }

        let session: ChatSession
        if let existing = self.session {
            session = existing
        } else if let restored = initialState {
            session = ChatEngine.shared.createSession(
                id: id,
                slug: restored.slug,
                title: restored.title,
                defaultModelId: restored.models.last ?? modelID,
                initialMessages: restored.messages,
                created: restored.created,
                modelsUsed: restored.models,
                pinned: restored.pinned,
                storageRoot: ChatFolder.root
            )
            slug = restored.slug
        } else {
            let slug = ChatFolder.uniqueSlug(ChatFolder.slugify(content))
            session = ChatEngine.shared.createSession(
                id: id, slug: slug, defaultModelId: modelID, storageRoot: ChatFolder.root
            )
            self.slug = slug
        }
        self.session = session

        // On screen immediately; the session appends its own copy inside
        // `sendMessage`, and the authoritative list replaces this one when the
        // stream ends.
        messages.append(ChatMessage(role: .user, content: content, model: modelID))

        streamingText = ""
        streamingModel = modelID
        isGenerating = true

        task = Task { [weak self] in
            await self?.drain(session: session, content: content, modelID: modelID)
        }

        // The sidebar gets its row the moment the chat exists, and the detail
        // pane follows the selection rather than the unsaved conversation.
        if initialState == nil { ChatLibrary.shared.selection = id }
        ChatConversations.postChanged()
        return slug
    }

    /// The engine drain: tokens into `streamingText`, records into `messages`,
    /// failures routed per §14.3. Any exit keeps the session's own save.
    private func drain(session: ChatSession, content: String, modelID: String) async {
        guard let backend = ChatEngine.shared.backend(for: modelID)
            ?? ChatEngine.shared.backend(for: "apple-foundation") else {
            isGenerating = false
            turnFailure = "No chat model is available."
            return
        }
        do {
            let stream = await session.sendMessage(content: content, backend: backend)
            // **The folder exists from the user's turn, not from the reply.**
            // `ChatSession` saves only when the stream ends, so a new chat had
            // no folder for the whole of its first generation — the sidebar
            // had no row to show and nothing to select. `sendMessage` has
            // appended the user message by the time it returns, so this writes
            // exactly what is on screen.
            try? await session.saveToDisk()
            ChatConversations.postChanged()
            for try await event in stream {
                switch event {
                case .token(let delta):
                    streamingText += delta
                case .message(let message):
                    messages.append(message)
                    if message.role == .assistant { streamingText = "" }
                case .toolCall, .turnCompleted:
                    break
                }
            }
            isGenerating = false
            await sync(from: session)
        } catch is CancellationError {
            // The session persists only committed records; the partial tokens
            // stay rendered here until the next send, which is what the user
            // watched arrive.
            isGenerating = false
        } catch {
            isGenerating = false
            switch error as? ChatBackendError {
            case .modelUnavailable, .modelLoadFailed:
                failure = Self.bannerText(for: error)
            default:
                turnFailure = Self.failureText(for: error)
            }
        }
        ChatConversations.postChanged()
    }

    private func sync(from session: ChatSession) async {
        messages = await session.state().messages
    }

    /// §10.4 priority 3's target — one conversation's stop.
    func stop() {
        task?.cancel()
    }

    // MARK: - Pin

    /// The pin goes through the session when one is live (it rewrites
    /// `chat.md` on every save and would revert a file-side flip); a new
    /// conversation has nothing to pin until it exists on disk.
    func setPinned(_ pinned: Bool) {
        guard let session else { return }
        Task {
            await session.setPinned(pinned)
            do {
                try await session.saveToDisk()
            } catch {
                Self.log.error("Pin save failed: \(error.localizedDescription, privacy: .public)")
            }
            ChatConversations.postChanged()
        }
    }

    // MARK: - Failure wording (§14.3: per error, living with the feature)

    private static func bannerText(for error: Error) -> String {
        switch error as? ChatBackendError {
        case .modelUnavailable:
            "The on-device chat model isn't available. Turn on Apple Intelligence in System Settings, or choose another model."
        case .modelLoadFailed:
            "The chat model couldn't be loaded. Try again, or choose another model."
        default:
            "The chat model isn't available."
        }
    }

    private static func failureText(for error: Error) -> String {
        switch error as? ChatBackendError {
        case .connectionFailed:
            "Couldn't reach the local server. Check that it is running."
        case .contextLengthExceeded:
            "This conversation has outgrown the model's context. Start a new chat."
        case .invalidResponse:
            "The model returned something unreadable."
        case .cancelled:
            ""
        default:
            "Generation failed: \(error.localizedDescription)"
        }
    }
}

/// The registry of open conversations, keyed by chat id — `ChatEngine` holds
/// the sessions, this holds what the surfaces render. Also the receiver of
/// §10.4's stop-generation broadcast.
@MainActor
@Observable
final class ChatConversations {

    static let shared = ChatConversations()

    private var conversations: [UUID: ChatConversation] = [:]

    /// The New Chat created in the window and not yet committed — the detail
    /// pane renders it before the sidebar has a row for it.
    private(set) var pendingNew: ChatConversation?

    private init() {
        // §10.4 priority 3 fires when Sotto is frontmost (`OverlayPanel
        // .escRemainderFromTap`); until slice 10 nothing observed it, because
        // nothing generated. One broadcast stops every running conversation.
        NotificationCenter.default.addObserver(
            forName: .sottoCancelGeneration, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopAll() }
        }
    }

    static func postChanged() {
        NotificationCenter.default.post(name: ChatFolder.chatsDidChange, object: nil)
    }

    func conversation(for id: UUID) -> ChatConversation? { conversations[id] }

    func conversation(slug: String) -> ChatConversation? {
        conversations.values.first { $0.slug == slug }
    }

    /// A fresh, unsaved conversation. Reuses the pending one while it is still
    /// empty, so "New Chat" pressed twice does not orphan a half-typed pane
    /// (the §5.2 draft instinct, applied to the window's composer).
    @discardableResult
    func beginNew() -> ChatConversation {
        if let pending = pendingNew, pending.isEmpty, !pending.isGenerating {
            return pending
        }
        let conversation = ChatConversation(state: nil)
        conversations[conversation.id] = conversation
        pendingNew = conversation
        return conversation
    }

    /// Opens a chat from the library — live if it already is, hydrated from
    /// its `chat.md` otherwise. Idempotent, so any surface can call it.
    @discardableResult
    func open(_ chat: ChatLibrary.Chat) -> ChatConversation {
        if let live = conversations[chat.id] { return live }
        let conversation = ChatConversation(state: chat.state)
        conversations[conversation.id] = conversation
        return conversation
    }

    /// Opens by slug — the overlay's target is a slug, not a library row.
    func open(slug: String) -> ChatConversation? {
        if let live = conversation(slug: slug) { return live }
        let url = ChatFolder.root.appendingPathComponent(slug, isDirectory: true)
            .appendingPathComponent("chat.md")
        guard let md = try? String(contentsOf: url, encoding: .utf8),
              let state = try? ChatSerializer.deserialize(markdown: md, defaultSlug: slug) else {
            return nil
        }
        return open(ChatLibrary.Chat(state: state, folder: url.deletingLastPathComponent()))
    }

    /// Cancel, close the engine session, and drop — deletion's first step, so
    /// a generating chat cannot resurrect its folder with its next save.
    func discard(_ id: UUID) {
        conversations[id]?.stop()
        ChatEngine.shared.closeSession(id: id)
        conversations.removeValue(forKey: id)
        if pendingNew?.id == id { pendingNew = nil }
    }

    func stopAll() {
        for conversation in conversations.values where conversation.isGenerating {
            conversation.stop()
        }
    }
}
