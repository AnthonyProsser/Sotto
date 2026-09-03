//
//  ChatLibrary.swift
//  Sotto
//
//  Slice 10. What the Chat workspace reads — §10.2's chat list, over the
//  folders slice 5 writes and slices 9–10 populate.
//

import Foundation
import Observation

/// The Chat mode's model: `chats/` folders, loaded, sorted, and filtered.
///
/// **Nothing here is a second store.** `ChatFolder`/`ChatSerializer` own the
/// on-disk shape and `ChatSession` owns every conversational write; this type
/// reads, caches for the window's lifetime, and reloads on
/// `.chatsDidChange`. Its only direct write is the pin on a chat that is not
/// open anywhere — a live session gets it instead, because the session
/// rewrites `chat.md` on every save and would revert a file-side flip.
///
/// The Audio twin is `AudioLibrary`; the two sidebars are the same control in
/// two modes (§10.2), so the shape — including pinned-first ordering and the
/// mode-scoped search binding — matches it deliberately.
@MainActor
@Observable
final class ChatLibrary {
    static let shared = ChatLibrary()

    /// One chat plus the folder it lives in.
    struct Chat: Identifiable, Equatable, Sendable {
        var state: ChatSessionState
        var folder: URL

        var id: UUID { state.id }
        var slug: String { state.slug }
        var created: Date { state.created }
        var updated: Date { state.updated }
        var pinned: Bool { state.pinned }

        /// **Derived, never stored** — `ChatSessionState.derivedTitle`, shared
        /// with the live conversation the window titles before its first save.
        /// The row truncates with `lineLimit(1)`, so no length is picked here —
        /// the same answer `AudioLibrary.Recording.title` gives for recordings.
        var title: String { state.derivedTitle }

        /// What the overlay picker showed before this library existed: the last
        /// turn, short.
        var snippet: String {
            let last = state.messages.last?.content ?? ""
            return String(last.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        }

        func matches(_ query: String) -> Bool {
            guard !query.isEmpty else { return true }
            if title.localizedStandardContains(query) { return true }
            return state.messages.contains { $0.content.localizedStandardContains(query) }
        }
    }

    private(set) var chats: [Chat] = []
    private(set) var isLoaded = false

    var selection: UUID?
    var search = ""

    private init() {
        NotificationCenter.default.addObserver(
            forName: ChatFolder.chatsDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// **Pinned first, then newest first** — §10.2's chat list and the Audio
    /// sidebar's rule, one control in two modes.
    var visible: [Chat] { Self.ordered(chats, matching: search) }

    nonisolated static func ordered(_ chats: [Chat], matching query: String) -> [Chat] {
        chats
            .filter { $0.matches(query) }
            .sorted {
                $0.pinned == $1.pinned ? $0.updated > $1.updated : $0.pinned
            }
    }

    var selected: Chat? {
        selection.flatMap { id in chats.first { $0.id == id } }
    }

    func refresh() {
        let root = ChatFolder.root
        Task.detached(priority: .userInitiated) {
            let loaded = Self.read(root)
            await MainActor.run { self.apply(loaded) }
        }
    }

    private func apply(_ loaded: [Chat]) {
        chats = loaded
        isLoaded = true
        // The chat can be deleted from under the selection while the window
        // was closed.
        //
        // **A live conversation is not absent, it is unwritten.** A chat's
        // folder does not exist until its first save, and the send that
        // selects it posts `.chatsDidChange` in the same breath — so this
        // read finished before the disk caught up and cleared the selection
        // the send had just made, leaving the pane titled "New Chat" with
        // nothing highlighted in the sidebar. `ChatConversations` is the
        // authority on what is open; only a chat missing from both is gone.
        if let selection, !loaded.contains(where: { $0.id == selection }),
           ChatConversations.shared.conversation(for: selection) == nil {
            self.selection = nil
        }
    }

    // MARK: - Writing

    func togglePin(_ chat: Chat) {
        if let conversation = ChatConversations.shared.conversation(for: chat.id) {
            conversation.setPinned(!chat.pinned)
        } else {
            var state = chat.state
            state.pinned.toggle()
            do {
                try ChatFolder.write(
                    slug: chat.folder.lastPathComponent,
                    markdown: ChatSerializer.serialize(state: state),
                    to: ChatFolder.root
                )
            } catch {
                return
            }
            ChatConversations.postChanged()
        }
    }

    /// **Manual delete mirrors the Audio sidebar's** (2026-08-20,
    /// `DECISIONS.md`) and extends §9.1, which gives chats a pin but no
    /// removal. The folder goes whole — a `chat.md` without its attachments
    /// would render image turns that cannot resolve. A generating chat is
    /// stopped first; deleting the folder under a streaming session would let
    /// its next save resurrect it.
    func delete(_ chat: Chat) {
        ChatConversations.shared.discard(chat.id)
        try? FileManager.default.removeItem(at: chat.folder)
        if selection == chat.id { selection = nil }
        ChatConversations.postChanged()
    }

    nonisolated private static func read(_ root: URL) -> [Chat] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ) else { return [] }
        var out: [Chat] = []
        for url in contents where url.hasDirectoryPath {
            let mdURL = url.appendingPathComponent("chat.md")
            guard let md = try? String(contentsOf: mdURL, encoding: .utf8),
                  let state = try? ChatSerializer.deserialize(
                      markdown: md, defaultSlug: url.lastPathComponent
                  ) else { continue }
            out.append(Chat(state: state, folder: url))
        }
        return out
    }
}
