import Foundation

/// Serialized state of a chat conversation for persistence and roundtripping.
public nonisolated struct ChatSessionState: Sendable, Codable, Equatable {
    public let id: UUID
    public let slug: String
    public var title: String?
    public var created: Date
    public var updated: Date
    public var contextSize: Int
    public var models: [String]
    public var messages: [ChatMessage]

    public init(
        id: UUID = UUID(),
        slug: String,
        title: String? = nil,
        created: Date = Date(),
        updated: Date = Date(),
        contextSize: Int = 4096,
        models: [String] = [],
        messages: [ChatMessage] = []
    ) {
        self.id = id
        self.slug = slug
        self.title = title
        self.created = created
        self.updated = updated
        self.contextSize = contextSize
        self.models = models
        self.messages = messages
    }
}

/// Serializer for Markdown chats with structured YAML frontmatter,
/// per-turn model attribution (`### Assistant (model_id)`), and fenced selection/tool blocks.
public nonisolated enum ChatSerializer {
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

    private static func formatDate(_ date: Date) -> String {
        isoFormatter.string(from: date)
    }

    private static func parseDate(_ string: String) -> Date? {
        isoFormatter.date(from: string) ?? fallbackISOFormatter.date(from: string)
    }

    /// Serialize chat session state into Markdown with YAML frontmatter.
    public static func serialize(state: ChatSessionState) -> String {
        var out = "---\n"
        out += "id: \(state.id.uuidString)\n"
        out += "slug: \(state.slug)\n"
        if let title = state.title, !title.isEmpty {
            out += "title: \(title)\n"
        }
        out += "created: \(formatDate(state.created))\n"
        out += "updated: \(formatDate(state.updated))\n"
        out += "contextSize: \(state.contextSize)\n"
        out += "models:\n"
        for m in state.models {
            out += "  - \(m)\n"
        }
        out += "---\n\n"

        for message in state.messages {
            switch message.role {
            case .system:
                out += "### System\n\(message.content)\n\n"
            case .user:
                out += "### User\n\(message.content)\n\n"
            case .assistant:
                let modelTag = message.model.map { " (\($0))" } ?? ""
                out += "### Assistant\(modelTag)\n"
                if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                    for call in toolCalls {
                        out += "```tool:call:\(call.name):\(call.id)\n\(call.arguments)\n```\n"
                    }
                }
                if !message.content.isEmpty {
                    out += "\(message.content)\n"
                }
                out += "\n"
            case .tool:
                let callId = message.toolCallId ?? "call"
                out += "```tool:result:\(callId)\n\(message.content)\n```\n\n"
            }
        }

        return out.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// Parse Markdown with YAML frontmatter into chat session state.
    public static func deserialize(markdown: String, defaultSlug: String = "chat") throws -> ChatSessionState {
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("---") else {
            // Unstructured markdown
            return ChatSessionState(
                id: UUID(),
                slug: defaultSlug,
                messages: [ChatMessage(role: .user, content: trimmed)]
            )
        }

        let parts = trimmed.components(separatedBy: "---")
        guard parts.count >= 3 else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: [], debugDescription: "Malformed YAML frontmatter delimiters")
            )
        }

        let frontmatter = parts[1]
        let body = parts.dropFirst(2).joined(separator: "---").trimmingCharacters(in: .whitespacesAndNewlines)

        var id = UUID()
        var slug = defaultSlug
        var title: String? = nil
        var created = Date()
        var updated = Date()
        var contextSize = 4096
        var models: [String] = []

        // Parse frontmatter lines
        var inModelsList = false
        for rawLine in frontmatter.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if inModelsList {
                if line.hasPrefix("- ") {
                    models.append(String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces))
                    continue
                } else if !line.hasPrefix(" ") && line.contains(":") {
                    inModelsList = false
                }
            }

            if line.hasPrefix("id:") {
                let val = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                if let parsedId = UUID(uuidString: val) { id = parsedId }
            } else if line.hasPrefix("slug:") {
                slug = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("title:") {
                title = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("created:") {
                let val = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces)
                if let parsed = parseDate(val) { created = parsed }
            } else if line.hasPrefix("updated:") {
                let val = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces)
                if let parsed = parseDate(val) { updated = parsed }
            } else if line.hasPrefix("contextSize:") {
                let val = String(line.dropFirst(12)).trimmingCharacters(in: .whitespaces)
                if let size = Int(val) { contextSize = size }
            } else if line.hasPrefix("models:") {
                inModelsList = true
            }
        }

        // Parse body messages
        var messages: [ChatMessage] = []
        let turnSections = body.components(separatedBy: "\n### ")

        for (index, section) in turnSections.enumerated() {
            let s = (index == 0 && section.hasPrefix("### ")) ? String(section.dropFirst(4)) : section
            let trimmedSection = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedSection.isEmpty { continue }

            let lines = trimmedSection.components(separatedBy: .newlines)
            let header = lines.first ?? ""
            let contentLines = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

            if header.hasPrefix("System") {
                messages.append(ChatMessage(role: .system, content: contentLines))
            } else if header.hasPrefix("User") {
                messages.append(ChatMessage(role: .user, content: contentLines))
            } else if header.hasPrefix("Assistant") {
                var modelName: String? = nil
                if let openParen = header.firstIndex(of: "("),
                   let closeParen = header.firstIndex(of: ")"),
                   openParen < closeParen {
                    let start = header.index(after: openParen)
                    modelName = String(header[start..<closeParen]).trimmingCharacters(in: .whitespaces)
                }

                // Check for embedded tool calls
                var toolCalls: [ToolCall] = []
                var cleanContent = contentLines

                if contentLines.contains("```tool:call:") {
                    let blocks = contentLines.components(separatedBy: "```tool:call:")
                    var nonToolParts: [String] = []
                    if !blocks[0].isEmpty { nonToolParts.append(blocks[0]) }

                    for b in blocks.dropFirst() {
                        if let endFence = b.range(of: "```") {
                            let metaAndArgs = String(b[..<endFence.lowerBound])
                            let remainder = String(b[endFence.upperBound...])
                            if !remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                nonToolParts.append(remainder)
                            }

                            let metaParts = metaAndArgs.components(separatedBy: .newlines)
                            let metaHeader = metaParts.first ?? ""
                            let args = metaParts.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                            let tokens = metaHeader.components(separatedBy: ":")
                            let name = tokens.first ?? "unknown"
                            let callId = tokens.count > 1 ? tokens[1] : UUID().uuidString

                            toolCalls.append(ToolCall(id: callId, name: name, arguments: args))
                        }
                    }
                    cleanContent = nonToolParts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                }

                messages.append(ChatMessage(
                    role: .assistant,
                    content: cleanContent,
                    model: modelName,
                    toolCalls: toolCalls.isEmpty ? nil : toolCalls
                ))
            } else if header.hasPrefix("tool:result:") {
                let callId = String(header.dropFirst(12)).trimmingCharacters(in: .whitespaces)
                messages.append(ChatMessage(
                    role: .tool,
                    content: contentLines,
                    toolCallId: callId
                ))
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
            messages: messages
        )
    }
}
