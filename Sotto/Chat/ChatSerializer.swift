import Foundation

/// Serialized state of a chat conversation.
nonisolated struct ChatSessionState: Sendable, Codable, Equatable {
    let id: UUID
    var slug: String
    var title: String?
    var created: Date
    var updated: Date
    var contextSize: Int
    var models: [String]
    var pinned: Bool
    var messages: [ChatMessage]

    init(
        id: UUID = UUID(),
        slug: String,
        title: String? = nil,
        created: Date = Date(),
        updated: Date = Date(),
        contextSize: Int = 4096,
        models: [String] = [],
        pinned: Bool = false,
        messages: [ChatMessage] = []
    ) {
        self.id = id
        self.slug = slug
        self.title = title
        self.created = created
        self.updated = updated
        self.contextSize = contextSize
        self.models = models
        self.pinned = pinned
        self.messages = messages
    }

    /// **Derived, never stored.** The frontmatter's `title` when a writer set
    /// one, else the first user message's first line, else the slug.
    ///
    /// Lives here rather than on `ChatLibrary.Chat` because the sidebar row is
    /// no longer the only caller: the window's title bar has to name a chat
    /// that has been sent but not yet written to disk, and that one has no
    /// library row to ask. Static so a live `ChatConversation` — which holds
    /// messages and a slug but no state snapshot — reads the same rule.
    static func derivedTitle(title: String?, messages: [ChatMessage], slug: String) -> String {
        if let title, !title.isEmpty { return title }
        let first = messages.first { $0.role == .user }?.content ?? ""
        let line = first.components(separatedBy: .newlines).first ?? first
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? slug : trimmed
    }

    var derivedTitle: String {
        Self.derivedTitle(title: title, messages: messages, slug: slug)
    }
}

/// `chat.md` — YAML frontmatter plus turns (§9.1).
///
/// Every turn carries **two** markers: an HTML comment the parser reads, and a
/// `### Speaker (model)` heading a human and Obsidian read. Splitting on the
/// heading is what the first implementation did, and it silently discarded
/// everything after the first Markdown `###` a model happened to write — which
/// models write constantly. The comment renders as nothing, so the file still
/// looks like the format §9.1 describes.
///
/// Content is written through byte-exact, with one exception: the literal
/// delimiter token is escaped so no message can forge a turn boundary.
nonisolated enum ChatSerializer {

    private static let delimiterOpen = "<!-- sotto:"
    private static let delimiterClose = "-->"
    /// Only fires if a message literally contains the delimiter token, which in
    /// practice means a chat about Sotto's own file format.
    private static let escapedOpen = "<!--&#32;sotto:"

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let fallbackISOFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parseDate(_ string: String) -> Date? {
        isoFormatter.date(from: string) ?? fallbackISOFormatter.date(from: string)
    }

    // MARK: - Serialize

    static func serialize(state: ChatSessionState) -> String {
        var out = "---\n"
        out += "id: \(state.id.uuidString)\n"
        out += "slug: \(state.slug)\n"
        if let title = state.title, !title.isEmpty {
            out += "title: \(title)\n"
        }
        if state.pinned {
            out += "pinned: true\n"
        }
        out += "created: \(isoFormatter.string(from: state.created))\n"
        out += "updated: \(isoFormatter.string(from: state.updated))\n"
        out += "contextSize: \(state.contextSize)\n"
        out += "models:\n"
        for m in state.models {
            out += "  - \(m)\n"
        }
        out += "---\n"

        for message in state.messages {
            out += "\n" + messageDelimiter(for: message) + "\n"
            out += heading(for: message) + "\n"

            // Body before tool calls: a section runs from its own marker to the
            // next one, so content written after a `toolcall` marker would parse
            // back as that call's arguments.
            let body = escape(message.content)
            if !body.isEmpty {
                out += body + "\n"
            }

            for call in message.toolCalls ?? [] {
                out += "\n" + delimiter("toolcall", ["id": call.id, "name": call.name]) + "\n"
                out += "```json\n\(escape(call.arguments))\n```\n"
            }
        }

        return out
    }

    private static func messageDelimiter(for message: ChatMessage) -> String {
        var attributes = ["role": message.role.rawValue]
        if let model = message.model { attributes["model"] = model }
        if let callId = message.toolCallId { attributes["call"] = callId }
        if let name = message.toolName { attributes["name"] = name }
        return delimiter("msg", attributes)
    }

    /// Sorted so the output is stable across runs — dictionaries are not ordered,
    /// and an unstable file diffs against itself.
    private static func delimiter(_ kind: String, _ attributes: [String: String]) -> String {
        let pairs = attributes.keys.sorted().map { key in
            " \(key)=\"\(escapeAttribute(attributes[key]!))\""
        }
        return "\(delimiterOpen)\(kind)\(pairs.joined()) \(delimiterClose)"
    }

    private static func heading(for message: ChatMessage) -> String {
        switch message.role {
        case .system:
            return "### System"
        case .user:
            return "### User"
        case .assistant:
            return "### Assistant" + (message.model.map { " (\($0))" } ?? "")
        case .tool:
            return "### Tool" + (message.toolName.map { " (\($0))" } ?? "")
        }
    }

    private static func escape(_ content: String) -> String {
        content.replacingOccurrences(of: delimiterOpen, with: escapedOpen)
    }

    private static func unescape(_ content: String) -> String {
        content.replacingOccurrences(of: escapedOpen, with: delimiterOpen)
    }

    /// Escaping `>` is what makes an unterminated `-->` impossible inside a value.
    private static func escapeAttribute(_ value: String) -> String {
        var out = ""
        for character in value {
            switch character {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case ">": out += "\\g"
            default: out.append(character)
            }
        }
        return out
    }

    private static func unescapeAttribute(_ value: String) -> String {
        var out = ""
        var escaped = false
        for character in value {
            if escaped {
                switch character {
                case "g": out.append(">")
                default: out.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                out.append(character)
            }
        }
        return out
    }

    // MARK: - Deserialize

    static func deserialize(markdown: String, defaultSlug: String = "chat") throws -> ChatSessionState {
        let (frontmatter, body) = splitFrontmatter(markdown)

        guard let frontmatter else {
            return ChatSessionState(
                slug: defaultSlug,
                messages: body.isEmpty ? [] : [ChatMessage(role: .user, content: body)]
            )
        }

        var id = UUID()
        var slug = defaultSlug
        var title: String?
        var created = Date()
        var updated = Date()
        var contextSize = 4096
        var models: [String] = []
        var pinned = false
        var inModelsList = false

        for rawLine in frontmatter.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if inModelsList {
                if line.hasPrefix("- ") {
                    models.append(String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces))
                    continue
                }
                inModelsList = false
            }

            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon])
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)

            switch key {
            case "id": if let parsed = UUID(uuidString: value) { id = parsed }
            case "slug": slug = value
            case "title": title = value
            case "created": if let parsed = parseDate(value) { created = parsed }
            case "updated": if let parsed = parseDate(value) { updated = parsed }
            case "contextSize": if let size = Int(value) { contextSize = size }
            case "pinned": pinned = value == "true"
            case "models": inModelsList = true
            default: break
            }
        }

        return ChatSessionState(
            id: id,
            slug: slug,
            title: title,
            created: created,
            updated: updated,
            contextSize: contextSize,
            models: models,
            pinned: pinned,
            messages: parseMessages(body)
        )
    }

    /// Splits on the closing `---` that stands alone on its own line, so a `---`
    /// horizontal rule inside a message cannot end the frontmatter.
    private static func splitFrontmatter(_ markdown: String) -> (String?, String) {
        let lines = markdown.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return (nil, markdown.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let close = lines.dropFirst().firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "---"
        }) else {
            return (nil, markdown.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let frontmatter = lines[1..<close].joined(separator: "\n")
        let body = lines[(close + 1)...].joined(separator: "\n")
        return (frontmatter, body.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private struct Marker {
        let kind: String
        let attributes: [String: String]
        let start: String.Index
        let end: String.Index
    }

    private static func markers(in body: String) -> [Marker] {
        var found: [Marker] = []
        var cursor = body.startIndex

        while let open = body.range(of: delimiterOpen, range: cursor..<body.endIndex) {
            guard let close = body.range(of: delimiterClose, range: open.upperBound..<body.endIndex) else {
                break
            }
            let inner = body[open.upperBound..<close.lowerBound]
            let kind = inner.prefix { !$0.isWhitespace }
            found.append(Marker(
                kind: String(kind),
                attributes: parseAttributes(String(inner.dropFirst(kind.count))),
                start: open.lowerBound,
                end: close.upperBound
            ))
            cursor = close.upperBound
        }
        return found
    }

    private static func parseAttributes(_ text: String) -> [String: String] {
        var attributes: [String: String] = [:]
        var cursor = text.startIndex

        while let equals = text.range(of: "=\"", range: cursor..<text.endIndex) {
            let key = text[cursor..<equals.lowerBound].trimmingCharacters(in: .whitespaces)
            var index = equals.upperBound
            var raw = ""
            var escaped = false
            while index < text.endIndex {
                let character = text[index]
                if escaped {
                    raw.append(character)
                    escaped = false
                } else if character == "\\" {
                    raw.append(character)
                    escaped = true
                } else if character == "\"" {
                    break
                } else {
                    raw.append(character)
                }
                index = text.index(after: index)
            }
            if !key.isEmpty {
                attributes[key] = unescapeAttribute(raw)
            }
            cursor = index < text.endIndex ? text.index(after: index) : text.endIndex
        }
        return attributes
    }

    private static func parseMessages(_ body: String) -> [ChatMessage] {
        let found = markers(in: body)
        guard !found.isEmpty else { return [] }

        var messages: [ChatMessage] = []
        var pendingToolCalls: [ToolCall] = []

        /// Content runs from the end of a marker to the start of the next one.
        func section(_ index: Int) -> String {
            let start = found[index].end
            let end = index + 1 < found.count ? found[index + 1].start : body.endIndex
            return String(body[start..<end])
        }

        func flush(_ message: ChatMessage?) {
            guard var message else { return }
            if !pendingToolCalls.isEmpty {
                message = ChatMessage(
                    id: message.id,
                    role: message.role,
                    content: message.content,
                    model: message.model,
                    toolCalls: pendingToolCalls,
                    toolCallId: message.toolCallId,
                    toolName: message.toolName,
                    timestamp: message.timestamp
                )
                pendingToolCalls = []
            }
            messages.append(message)
        }

        var current: ChatMessage?

        for index in found.indices {
            let marker = found[index]
            let attributes = marker.attributes

            switch marker.kind {
            case "msg":
                flush(current)
                let role = ChatRole(rawValue: attributes["role"] ?? "") ?? .user
                current = ChatMessage(
                    role: role,
                    content: unescape(stripHeading(section(index))),
                    model: attributes["model"],
                    toolCallId: attributes["call"],
                    toolName: attributes["name"]
                )

            case "toolcall":
                pendingToolCalls.append(ToolCall(
                    id: attributes["id"] ?? UUID().uuidString,
                    name: attributes["name"] ?? "",
                    arguments: unescape(stripFence(section(index)))
                ))

            default:
                break
            }
        }
        flush(current)

        return messages
    }

    /// Drops the decorative `### Speaker` line. It carries no information the
    /// marker does not already hold, and hand-editing it in Obsidian is harmless.
    private static func stripHeading(_ section: String) -> String {
        var lines = section.components(separatedBy: .newlines)
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        if lines.first?.hasPrefix("### ") == true {
            lines.removeFirst()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripFence(_ section: String) -> String {
        var lines = section.components(separatedBy: .newlines)
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        if lines.first?.hasPrefix("```") == true {
            lines.removeFirst()
            if let closing = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "```" }) {
                lines = Array(lines[..<closing])
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
