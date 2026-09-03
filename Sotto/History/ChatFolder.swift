//
//  ChatFolder.swift
//  Sotto
//
//  Slice 5. The chat on-disk shape, with no caller until slice 9.
//

import Foundation

/// One folder per chat: `chat.md` plus `attachments/`.
///
/// Written now so slice 9 fills a hole rather than inventing a format.
/// Obsidian opening the folder is an accident of Markdown, not a requirement
/// (`DECISIONS.md`, 2026-08-19).
nonisolated enum ChatFolder {

    /// Posted on main after any write to `chats/` — a send, a pin, a delete.
    /// `ChatLibrary` reloads on it, which is how the window's sidebar, the
    /// overlay's picker, and the docked panel stay one view of one store.
    /// The audio twin is `.audioHistoryDidChange`.
    nonisolated static let chatsDidChange = Notification.Name("SottoChatsDidChange")

    /// Test seam: when set, `root` returns this instead of the real
    /// Application Support folder. Mirrors `DraftStore.fileURLForTesting` —
    /// slice 10's live layer (`ChatLibrary`, `ChatConversations`) reads and
    /// writes through `root` with no injectable parameter of its own, so
    /// nothing else lets a test keep it off the real chats folder.
    static var rootForTesting: URL?

    static var root: URL {
        if let override = rootForTesting { return override }
        let url = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sotto/chats", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    static func write(
        slug: String,
        markdown: String,
        attachments: [String: Data] = [:],
        to root: URL
    ) throws -> URL {
        let folder = root.appendingPathComponent(slug, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try markdown.write(to: folder.appendingPathComponent("chat.md"), atomically: true, encoding: .utf8)
        try write(attachments, to: folder)
        return folder
    }

    /// Image data into `attachments/`, without touching `chat.md`. The
    /// conversation layer writes images *before* the session saves the markdown
    /// that names them, so a turn never references a file that is not there.
    static func write(_ attachments: [String: Data], to folder: URL) throws {
        let dir = folder.appendingPathComponent("attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, data) in attachments {
            try data.write(to: dir.appendingPathComponent(name), options: .atomic)
        }
    }

    // MARK: - Slugs

    /// First line, lowercased, `-`-joined, date-prefixed. Moved here from
    /// `DraftStore` in slice 10, where the conversation layer decides the slug
    /// at first commit; the rule is unchanged.
    nonisolated static func slugify(_ text: String) -> String {
        let base = text.components(separatedBy: .newlines).first ?? text
        let prefix = String(base.prefix(40)).lowercased()
        var slug = prefix
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.isEmpty { slug = "chat-\(ISO8601DateFormatter().string(from: Date()).prefix(10))" }
        let date = ISO8601DateFormatter().string(from: Date()).prefix(10)
        return "\(date)-\(slug)"
    }

    nonisolated static func uniqueSlug(_ slug: String) -> String {
        var candidate = slug
        var n = 2
        while FileManager.default.fileExists(atPath: root.appendingPathComponent(candidate).path) {
            candidate = "\(slug)-\(n)"; n += 1
        }
        return candidate
    }
}
