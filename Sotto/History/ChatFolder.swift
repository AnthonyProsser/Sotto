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
/// Nothing in Sotto reads these yet. Obsidian opening the folder is an
/// accident of Markdown, not a requirement (`DECISIONS.md`, 2026-08-19).
nonisolated enum ChatFolder {

    static var root: URL {
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
        let attachmentsDir = folder.appendingPathComponent("attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: attachmentsDir, withIntermediateDirectories: true)
        try markdown.write(to: folder.appendingPathComponent("chat.md"), atomically: true, encoding: .utf8)
        for (name, data) in attachments {
            try data.write(to: attachmentsDir.appendingPathComponent(name), options: .atomic)
        }
        return folder
    }
}
