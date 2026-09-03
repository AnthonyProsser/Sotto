//
//  Draft.swift
//  Sotto
//
//  Slice 9 — deferred-commit draft, §5.2. Nothing is committed until send.
//  Attachments serialize before text, CommonMark longer-fence (max+1 ≥3).
//

import Foundation

/// The transient overlay draft. Not a chat yet.
struct Draft: Codable, Equatable, Sendable {
    var text: String
    var attachments: [Attachment]
    var target: Target

    init(text: String = "", attachments: [Attachment] = [], target: Target = .new) {
        self.text = text
        self.attachments = attachments
        self.target = target
    }

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty }

    // MARK: - Attachment

    enum Attachment: Codable, Equatable, Sendable, Identifiable {
        case selection(id: UUID, app: String, text: String)
        case image(id: UUID, filename: String, data: Data)

        // Custom Codable with discriminator

        private enum Kind: String, Codable { case selection, image }

        private enum Keys: String, CodingKey { case kind, id, app, text, filename, data }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            let kind = try c.decode(Kind.self, forKey: .kind)
            switch kind {
            case .selection:
                let id = try c.decode(UUID.self, forKey: .id)
                let app = try c.decode(String.self, forKey: .app)
                let text = try c.decode(String.self, forKey: .text)
                self = .selection(id: id, app: app, text: text)
            case .image:
                let id = try c.decode(UUID.self, forKey: .id)
                let filename = try c.decode(String.self, forKey: .filename)
                let data = try c.decode(Data.self, forKey: .data)
                self = .image(id: id, filename: filename, data: data)
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            switch self {
            case .selection(let id, let app, let text):
                try c.encode(Kind.selection, forKey: .kind)
                try c.encode(id, forKey: .id)
                try c.encode(app, forKey: .app)
                try c.encode(text, forKey: .text)
            case .image(let id, let filename, let data):
                try c.encode(Kind.image, forKey: .kind)
                try c.encode(id, forKey: .id)
                try c.encode(filename, forKey: .filename)
                try c.encode(data, forKey: .data)
            }
        }

        var id: UUID {
            switch self {
            case .selection(let id, _, _): return id
            case .image(let id, _, _): return id
            }
        }

        /// Display name for chip.
        var displayName: String {
            switch self {
            case .selection(_, let app, let text):
                let preview = text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(32)
                return "\(app): \(preview)"
            case .image(_, let filename, _):
                return filename
            }
        }

        /// Alias for call sites that used `chipLabel`.
        var chipLabel: String { displayName }
    }

    // MARK: - Target

    enum Target: Codable, Equatable, Sendable {
        case new
        case existing(slug: String)

        private enum Kind: String, Codable { case new, existing }
        private enum Keys: String, CodingKey { case kind, slug }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            // Back-compat: earlier builds wrote "newChat" literal.
            if let raw = try? c.decode(String.self, forKey: .kind), raw == "newChat" {
                self = .new; return
            }
            let kind = try c.decode(Kind.self, forKey: .kind)
            switch kind {
            case .new: self = .new
            case .existing:
                let slug = try c.decode(String.self, forKey: .slug)
                self = .existing(slug: slug)
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            switch self {
            case .new:
                try c.encode(Kind.new, forKey: .kind)
            case .existing(let slug):
                try c.encode(Kind.existing, forKey: .kind)
                try c.encode(slug, forKey: .slug)
            }
        }
    }

    // MARK: - Serialization for send

    /// Wire order: attachments first, then text. Each selection as fenced block
    /// with `selection app="..."`. Images as markdown `![filename](attachments/filename)`
    /// (file written to chat's attachments/ on send).
    func serializedContent() -> String {
        var parts: [String] = []
        for att in attachments {
            switch att {
            case .selection(_, let app, let text):
                parts.append(fencedSelection(app: app, text: text))
            case .image(_, let filename, _):
                parts.append("![\(filename)](attachments/\(filename))")
            }
        }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty { parts.append(body) }
        return parts.joined(separator: "\n\n")
    }

    /// Attachments as separate data map for ChatFolder.write
    func imageAttachments() -> [String: Data] {
        var out: [String: Data] = [:]
        for att in attachments {
            if case .image(_, let filename, let data) = att {
                out[filename] = data
            }
        }
        return out
    }

    /// Compatibility alias — earlier store used `serializedMessage`.
    var serializedMessage: String { serializedContent() }

    // MARK: - CommonMark longer fence

    func fencedSelection(app: String, text: String) -> String {
        let fence = fenceString(for: text)
        let escapedApp = app
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\(fence)selection app=\"\(escapedApp)\"\n\(text)\n\(fence)"
    }

    /// Longest run of ` in text, fence is max+1, at least 3.
    func fenceString(for text: String) -> String {
        var maxRun = 0
        var run = 0
        for ch in text {
            if ch == "`" { run += 1; maxRun = max(maxRun, run) } else { run = 0 }
        }
        let len = max(maxRun + 1, 3)
        return String(repeating: "`", count: len)
    }
}
