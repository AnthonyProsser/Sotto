import Foundation
import FoundationModels
import os

/// On-device Apple Intelligence backend using `FoundationModels.SystemLanguageModel`.
///
/// **Session isolation:** a fresh `LanguageModelSession` per turn, never shared
/// with cleanup's. Reusing one session for two simultaneous requests throws
/// `concurrentRequests` deterministically (`DECISIONS.md`, 2026-08-19).
///
/// **This backend runs its own tool loop**, because `LanguageModelSession` calls
/// the tool and feeds the result back without returning control. The harness is
/// told so via `executesToolsInternally`, and what happened is reported from the
/// session's own `Transcript` after the turn — that transcript is the record, so
/// reconstructing one from the token stream would be a second, worse source.
nonisolated final class AppleFoundationBackend: ChatBackend, @unchecked Sendable {
    let id: String
    let backendType: BackendType = .appleFoundation
    let executesToolsInternally = true

    private let log = Logger(subsystem: "com.anthonyprosser.Sotto", category: "apple-backend")
    private let model: SystemLanguageModel

    init(id: String = "apple-foundation") {
        self.id = id
        // `.permissiveContentTransformations`, not the default set: the default
        // guardrails refuse on the user's own content.
        self.model = SystemLanguageModel(
            useCase: .general,
            guardrails: .permissiveContentTransformations
        )
    }

    /// Whether Apple Intelligence is enabled and ready on this machine.
    var isAvailable: Bool {
        if case .available = model.availability { return true }
        return false
    }

    func generateStream(
        messages: [ChatMessage],
        tools: [ChatTool],
        systemPrompt: String?
    ) async throws -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let modelId = self.id

        return AsyncThrowingStream(ChatStreamEvent.self) { continuation in
            let task = Task {
                guard case .available = self.model.availability else {
                    // Not a failure — a configuration state, routed to the
                    // settings pane that owns it (`rules/design.md` §10).
                    let reason = String(describing: self.model.availability)
                    self.log.notice("Apple Foundation model not available: \(reason, privacy: .public)")
                    continuation.finish(throwing: ChatBackendError.modelUnavailable(reason))
                    return
                }

                do {
                    let bridged = try tools.map { try BridgedTool($0) }
                    let (history, prompt) = Self.split(messages: messages)

                    let session = LanguageModelSession(
                        model: self.model,
                        tools: bridged,
                        transcript: Self.transcript(
                            systemPrompt: systemPrompt,
                            tools: bridged,
                            history: history
                        )
                    )
                    let baseline = session.transcript.count

                    var previousLength = 0
                    for try await chunk in session.streamResponse(to: prompt) {
                        try Task.checkCancellation()

                        // Snapshots are cumulative, so the new text is the tail.
                        let text = chunk.content
                        guard text.count > previousLength else { continue }
                        let start = text.index(text.startIndex, offsetBy: previousLength)
                        previousLength = text.count
                        continuation.yield(.token(String(text[start...])))
                    }

                    for message in Self.record(
                        of: session.transcript,
                        after: baseline,
                        model: modelId
                    ) {
                        if let calls = message.toolCalls {
                            for call in calls { continuation.yield(.toolCall(call)) }
                        }
                        continuation.yield(.message(message))
                    }

                    continuation.yield(.turnCompleted(model: modelId, finishReason: "stop"))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: ChatBackendError.cancelled)
                } catch let error as ChatBackendError {
                    continuation.finish(throwing: error)
                } catch {
                    self.log.error("FoundationModels generation error: \(error.localizedDescription, privacy: .public)")
                    continuation.finish(throwing: ChatBackendError.invalidResponse(error.localizedDescription))
                }
            }

            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    // MARK: - History

    /// Splits history from the turn's prompt. `streamResponse(to:)` supplies the
    /// prompt itself, so the last user message must not also be in the transcript.
    static func split(messages: [ChatMessage]) -> (history: [ChatMessage], prompt: String) {
        guard let index = messages.lastIndex(where: { $0.role == .user }) else {
            return (messages, "")
        }
        return (Array(messages[..<index]), messages[index].content)
    }

    static func transcript(
        systemPrompt: String?,
        tools: [BridgedTool],
        history: [ChatMessage]
    ) -> Transcript {
        var entries: [Transcript.Entry] = []

        let instructions = ([systemPrompt] + history.filter { $0.role == .system }.map(\.content))
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        if !instructions.isEmpty || !tools.isEmpty {
            entries.append(.instructions(Transcript.Instructions(
                segments: [.text(Transcript.TextSegment(content: instructions))],
                toolDefinitions: tools.map { Transcript.ToolDefinition(tool: $0) }
            )))
        }

        for message in history {
            switch message.role {
            case .system:
                continue  // already folded into instructions
            case .user:
                entries.append(.prompt(Transcript.Prompt(
                    segments: [.text(Transcript.TextSegment(content: message.content))]
                )))
            case .assistant:
                if let calls = message.toolCalls, !calls.isEmpty {
                    entries.append(.toolCalls(Transcript.ToolCalls(calls.map { call in
                        Transcript.ToolCall(
                            id: call.id,
                            toolName: call.name,
                            arguments: (try? GeneratedContent(json: call.arguments)) ?? GeneratedContent(call.arguments)
                        )
                    })))
                }
                if !message.content.isEmpty {
                    entries.append(.response(Transcript.Response(
                        assetIDs: [],
                        segments: [.text(Transcript.TextSegment(content: message.content))]
                    )))
                }
            case .tool:
                entries.append(.toolOutput(Transcript.ToolOutput(
                    id: message.toolCallId ?? UUID().uuidString,
                    toolName: message.toolName ?? "tool",
                    segments: [.text(Transcript.TextSegment(content: message.content))]
                )))
            }
        }

        return Transcript(entries: entries)
    }

    /// The messages this turn added, read back out of the session's transcript.
    static func record(of transcript: Transcript, after baseline: Int, model: String) -> [ChatMessage] {
        guard baseline < transcript.count else { return [] }

        return transcript[baseline...].compactMap { entry -> ChatMessage? in
            switch entry {
            case .instructions, .prompt:
                // The prompt is the message the caller already holds.
                return nil
            case .toolCalls(let calls):
                return ChatMessage(
                    role: .assistant,
                    content: "",
                    model: model,
                    toolCalls: calls.map {
                        ToolCall(id: $0.id, name: $0.toolName, arguments: $0.arguments.jsonString)
                    }
                )
            case .toolOutput(let output):
                return ChatMessage(
                    role: .tool,
                    content: text(of: output.segments),
                    toolCallId: output.id,
                    toolName: output.toolName
                )
            case .response(let response):
                return ChatMessage(role: .assistant, content: text(of: response.segments), model: model)
            @unknown default:
                return nil
            }
        }
    }

    private static func text(of segments: [Transcript.Segment]) -> String {
        segments.map { segment in
            switch segment {
            case .text(let text): return text.content
            case .structure(let structure): return structure.content.jsonString
            @unknown default: return ""
            }
        }.joined()
    }
}

// MARK: - Tool bridging

/// One of Sotto's tools presented as a native `FoundationModels.Tool`.
///
/// `Arguments` is `GeneratedContent` rather than a concrete `Generable` struct
/// because the tool list is only known at runtime — it comes from enabled MCP
/// servers, not from types the compiler has seen. `DynamicGenerationSchema` is
/// the framework's own answer to that, and it is what makes constrained decoding
/// work here: the model is held to the tool's schema instead of being asked to
/// produce JSON and hoped at, which is the whole reason to prefer native tools
/// over `ChatHarness`'s prompt-and-parse path.
nonisolated struct BridgedTool: FoundationModels.Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let name: String
    let description: String
    let parameters: GenerationSchema

    private let executor: any ChatToolExecutor

    init(_ tool: ChatTool) throws {
        self.name = tool.definition.name
        self.description = tool.definition.description
        self.executor = tool.executor
        self.parameters = try Self.schema(
            name: tool.definition.name,
            jsonSchema: tool.definition.parametersJSONSchema
        )
    }

    func call(arguments: GeneratedContent) async throws -> String {
        try await executor.execute(call: ToolCall(name: name, arguments: arguments.jsonString))
    }

    // MARK: - JSON Schema → GenerationSchema

    static func schema(name: String, jsonSchema: String) throws -> GenerationSchema {
        let node = (try? JSONSerialization.jsonObject(with: Data(jsonSchema.utf8))) as? [String: Any] ?? [:]
        return try GenerationSchema(root: dynamic(name: name, description: nil, node: node), dependencies: [])
    }

    /// Handles the subset of JSON Schema tools actually use: objects, arrays,
    /// string enums, and the four scalars. Anything unrecognised becomes a
    /// string, which the model can still fill and the executor still parses.
    static func dynamic(name: String, description: String?, node: [String: Any]) -> DynamicGenerationSchema {
        if let choices = node["enum"] as? [String], !choices.isEmpty {
            return DynamicGenerationSchema(name: name, description: description, anyOf: choices)
        }

        let type = node["type"] as? String ?? (node["properties"] != nil ? "object" : "string")
        switch type {
        case "object":
            let properties = node["properties"] as? [String: Any] ?? [:]
            let required = Set(node["required"] as? [String] ?? [])
            return DynamicGenerationSchema(
                name: name,
                description: description,
                properties: properties.keys.sorted().map { key in
                    let child = properties[key] as? [String: Any] ?? [:]
                    return DynamicGenerationSchema.Property(
                        name: key,
                        description: child["description"] as? String,
                        schema: dynamic(name: key, description: child["description"] as? String, node: child),
                        isOptional: !required.contains(key)
                    )
                }
            )
        case "array":
            return DynamicGenerationSchema(
                arrayOf: dynamic(name: "\(name)Item", description: nil, node: node["items"] as? [String: Any] ?? [:]),
                minimumElements: node["minItems"] as? Int,
                maximumElements: node["maxItems"] as? Int
            )
        case "integer":
            return DynamicGenerationSchema(type: Int.self)
        case "number":
            return DynamicGenerationSchema(type: Double.self)
        case "boolean":
            return DynamicGenerationSchema(type: Bool.self)
        default:
            return DynamicGenerationSchema(type: String.self)
        }
    }
}
