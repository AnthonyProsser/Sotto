//
//  DraftStore.swift
//  Sotto
//
//  Slice 9 — draft persistence, §5.2. Text+attachments survive close and
//  relaunch via atomic ~/Library/Application Support/Sotto/draft.json. Saves
//  coalesce for 300 ms and flush on overlay hide and quit, so a force-kill can
//  lose the last 300 ms of typing (DECISIONS.md, 2026-09-02). Delete empty.
//

import AppKit
import Foundation
import Observation
import os

@Observable
final class DraftStore {
    static let shared = DraftStore()

    /// Draft persistence failures — save, load, and the send path's catch.
    static let log = Logger(subsystem: "com.anthonyprosser.Sotto", category: "drafts")

    var draft: Draft {
        didSet { scheduleSave() }
    }

    // MARK: - Persistence

    /// Test seam: when set, every save/load/delete lands here instead of the
    /// real Application Support file.
    static var fileURLForTesting: URL?

    static var fileURL: URL {
        if let override = fileURLForTesting { return override }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sotto", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("draft.json")
    }

    init() {
        self.draft = Self.load()
        // Flush the coalesced save on the way out, so a normal quit loses
        // nothing (a force-kill loses at most `saveDelay` of typing).
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.forceSave() }
    }

    init(draft: Draft) {
        // For tests / previews, no load, no quit observer.
        self.draft = draft
    }

    private static func load() -> Draft {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return Draft() }
        guard let data = try? Data(contentsOf: url) else {
            log.error("Draft file unreadable: \(url.path, privacy: .public)")
            return Draft()
        }
        if let decoded = try? JSONDecoder().decode(Draft.self, from: data) {
            return decoded
        }
        // Corrupt file — delete and start empty (don't crash).
        log.error("Draft file corrupt, deleting: \(url.path, privacy: .public)")
        try? FileManager.default.removeItem(at: url)
        return Draft()
    }

    /// How long a save waits for another keystroke. The window a force-kill can
    /// lose (DECISIONS.md, 2026-09-02): a keystroke with an image attached
    /// re-encodes and rewrites the whole image, so writes coalesce rather than
    /// run per keystroke.
    private static let saveDelay: TimeInterval = 0.3
    private var pendingSave: DispatchWorkItem?

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDelay, execute: work)
    }

    /// Flush any coalesced save now — overlay hide and app quit call this, so
    /// the only loss window is a force-kill inside `saveDelay`.
    func forceSave() {
        pendingSave?.cancel()
        pendingSave = nil
        save()
    }

    private func save() {
        let url = Self.fileURL
        do {
            if draft.isEmpty {
                // Empty draft — delete draft.json regardless of target (spec).
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                return
            }
            // Atomic via .atomic + create intermediate
            let data = try JSONEncoder().encode(draft)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            Self.log.error("Draft save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func reset() {
        draft = Draft()
    }

    func clear() { reset() } // alias for History store call sites

    // MARK: - Text helpers

    func setText(_ text: String) { draft.text = text }
    func setAttachments(_ atts: [Draft.Attachment]) { draft.attachments = atts }
    func appendAttachment(_ att: Draft.Attachment) { draft.attachments.append(att) }
    func removeAttachment(id: UUID) { draft.attachments.removeAll { $0.id == id } }
    func removeAttachment(at index: Int) {
        guard draft.attachments.indices.contains(index) else { return }
        draft.attachments.remove(at: index)
    }

    /// Convenience for Dictation / selection paths (WT-A).
    func addSelection(app: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        draft.attachments.append(.selection(id: UUID(), app: app, text: trimmed))
    }

    func addImage(filename: String, data: Data) {
        draft.attachments.append(.image(id: UUID(), filename: filename, data: data))
    }

    func setTarget(_ target: Draft.Target) { draft.target = target }

    // MARK: - Recent chats (picker)

    struct RecentChat: Identifiable, Equatable {
        let id: UUID
        let slug: String
        let title: String?
        let updated: Date
        let snippet: String
        init(id: UUID, slug: String, title: String?, updated: Date, snippet: String = "") {
            self.id = id; self.slug = slug; self.title = title; self.updated = updated; self.snippet = snippet
        }
    }

    /// Recent chats via ChatFolder.root + ChatSerializer, limit 8.
    func recentChats(limit: Int = 8) -> [RecentChat] {
        let root = ChatFolder.root
        guard let contents = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles) else { return [] }
        var out: [RecentChat] = []
        for url in contents {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let mdURL = url.appendingPathComponent("chat.md")
            guard FileManager.default.fileExists(atPath: mdURL.path) else { continue }
            guard let md = try? String(contentsOf: mdURL, encoding: .utf8) else { continue }
            guard let state = try? ChatSerializer.deserialize(markdown: md, defaultSlug: url.lastPathComponent) else { continue }
            let snippet = state.messages.last?.content.prefix(60).description ?? ""
            out.append(RecentChat(id: state.id, slug: state.slug, title: state.title, updated: state.updated, snippet: String(snippet)))
        }
        return out.sorted { $0.updated > $1.updated }.prefix(limit).map { $0 }
    }

    // MARK: - Continuity

    // UserDefaults keys per spec
    static let continuityWindowKey = "OverlayContinuityWindow"
    static let continuityEnabledKey = "OverlayContinuityEnabled"
    private static let lastSendDateKey = "OverlayLastSendDate"
    private static let lastChatSlugKey = "OverlayLastChatSlug"

    var continuityWindow: TimeInterval {
        get {
            if UserDefaults.standard.object(forKey: Self.continuityWindowKey) == nil { return 300 }
            return UserDefaults.standard.double(forKey: Self.continuityWindowKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.continuityWindowKey) }
    }

    var continuityEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: Self.continuityEnabledKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: Self.continuityEnabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.continuityEnabledKey) }
    }

    /// Call on send — records continuity anchor. Resets on send not activity per §5.3.
    func recordSend(slug: String) {
        UserDefaults.standard.set(Date(), forKey: Self.lastSendDateKey)
        UserDefaults.standard.set(slug, forKey: Self.lastChatSlugKey)
    }

    /// Resolve default target if draft has no explicit target (called on overlay show).
    func resolveContinuityIfNeeded() {
        // If draft already has explicit target from retarget or persisted, keep it.
        // But if draft is empty and target is .new, we may fill from continuity.
        // We do not overwrite a retargeted draft that has content.
        if draft.isEmpty && draft.target == .new {
            if let resolved = resolvedContinuityTarget() {
                draft.target = resolved
            }
        }
    }

    func resolvedContinuityTarget() -> Draft.Target? {
        guard continuityEnabled else { return nil }
        let window = continuityWindow
        if window <= 0 { return nil } // 0 means disabled? treat as no continuity
        guard let lastDate = UserDefaults.standard.object(forKey: Self.lastSendDateKey) as? Date,
              let slug = UserDefaults.standard.string(forKey: Self.lastChatSlugKey) else { return nil }
        if Date().timeIntervalSince(lastDate) > window { return nil }
        let url = ChatFolder.root.appendingPathComponent(slug)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return .existing(slug: slug)
    }

    /// Alias for WT-A call sites (`applyContinuityIfNeeded`).
    func applyContinuityIfNeeded() { resolveContinuityIfNeeded() }

    // MARK: - Send — commits draft to a chat folder (ported from History store)

    enum DraftError: LocalizedError {
        case empty
        var errorDescription: String? { "Draft is empty" }
    }

    /// Commit draft to disk. Returns the slug written to.
    /// `modelID` is the current chat model — stored per-turn (§5.3, §9.1).
    @discardableResult
    func send(modelID: String = "apple-foundation") throws -> String {
        let content = draft.serializedContent()
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DraftError.empty }

        let imageDatas = draft.imageAttachments()

        switch draft.target {
        case .new:
            let base = Self.slugify(trimmed)
            let uniqueSlug = Self.uniqueSlug(base)
            let msg = ChatMessage(role: .user, content: trimmed, model: modelID)
            let state = ChatSessionState(slug: uniqueSlug, models: [modelID], messages: [msg])
            try ChatFolder.write(slug: uniqueSlug, markdown: ChatSerializer.serialize(state: state), attachments: imageDatas, to: ChatFolder.root)
            recordSend(slug: uniqueSlug)
            draft = Draft()
            return uniqueSlug
        case .existing(let existingSlug):
            let folder = ChatFolder.root.appendingPathComponent(existingSlug, isDirectory: true)
            let mdURL = folder.appendingPathComponent("chat.md")
            let md = (try? String(contentsOf: mdURL, encoding: .utf8)) ?? ""
            var existing = (try? ChatSerializer.deserialize(markdown: md, defaultSlug: existingSlug)) ?? ChatSessionState(slug: existingSlug, models: [], messages: [])
            if !existing.models.contains(modelID) { existing.models.append(modelID) }
            existing.updated = Date()
            let msg = ChatMessage(role: .user, content: trimmed, model: modelID)
            existing.messages.append(msg)
            var merged = imageDatas
            let existingAttDir = folder.appendingPathComponent("attachments", isDirectory: true)
            if let existingFiles = try? FileManager.default.contentsOfDirectory(at: existingAttDir, includingPropertiesForKeys: nil) {
                for url in existingFiles where merged[url.lastPathComponent] == nil {
                    if let data = try? Data(contentsOf: url) { merged[url.lastPathComponent] = data }
                }
            }
            try ChatFolder.write(slug: existingSlug, markdown: ChatSerializer.serialize(state: existing), attachments: merged, to: ChatFolder.root)
            recordSend(slug: existingSlug)
            // Keep target (stay in same chat) but clear text/attachments for next turn.
            draft.text = ""
            draft.attachments = []
            return existingSlug
        }
    }

    private static func slugify(_ text: String) -> String {
        let base = text.components(separatedBy: .newlines).first ?? text
        let prefix = String(base.prefix(40)).lowercased()
        var slug = prefix
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.isEmpty { slug = "chat-\(ISO8601DateFormatter().string(from: Date()).prefix(10))" }
        let date = ISO8601DateFormatter().string(from: Date()).prefix(10)
        return "\(date)-\(slug)"
    }

    private static func uniqueSlug(_ slug: String) -> String {
        var candidate = slug
        var n = 2
        while FileManager.default.fileExists(atPath: ChatFolder.root.appendingPathComponent(candidate).path) {
            candidate = "\(slug)-\(n)"; n += 1
        }
        return candidate
    }

    // MARK: - Testing helper

    static func deleteFile() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
