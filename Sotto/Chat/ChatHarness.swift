import Foundation
import os

/// The multi-turn loop (§7.1): messages → model → if tool calls, execute, append, repeat.
///
/// Two tool paths, chosen by `ModelCapability.tools`:
///
/// - **Native** — the model emits structured calls the backend reports as
///   `.toolCall`, and this loop dispatches them.
/// - **Prompt-and-parse** — the tool list goes into the system prompt and the
///   model answers with a JSON object, which `FallbackToolBuffer` recognises.
///   Still needed even with MLX in the graph: `MLXLMCommon` only parses
///   `<tool_call>` tags, so anything not using that convention lands here.
///
/// A backend that runs its own loop (`executesToolsInternally`) is passed
/// through untouched — dispatching its calls again would run every tool twice.
nonisolated final class ChatHarness: @unchecked Sendable {
    private let log = Logger(subsystem: "com.anthonyprosser.Sotto", category: "chat-harness")

    static let shared = ChatHarness()

    init() {}

    /// Holds back tokens only while they could still turn out to be a fallback
    /// tool call, so protocol JSON never reaches the transcript or the screen.
    ///
    /// The instruction tells the model to answer with a bare JSON object, so the
    /// first non-whitespace character settles it: anything that is not `{` or a
    /// fence can be released immediately and streamed normally from then on.
    /// Buffering the whole turn instead would cost live streaming on every
    /// answer these models give, tool call or not.
    struct FallbackToolBuffer {
        private(set) var held = ""
        private(set) var isHolding = true

        /// Returns the text that may be shown now, if any.
        mutating func append(_ token: String) -> String? {
            guard isHolding else { return token }
            held += token

            let trimmed = held.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let first = trimmed.first else { return nil }

            if first == "{" || first == "`" {
                return nil
            }
            isHolding = false
            let release = held
            held = ""
            return release
        }

        /// At end of turn: the parsed call, or the text to show and record.
        mutating func resolve() -> (call: ToolCall?, text: String) {
            guard isHolding else { return (nil, "") }
            isHolding = false
            let text = held
            held = ""
            if let call = ChatHarness.parseJSONToolFallback(content: text) {
                return (call, "")
            }
            return (nil, text)
        }
    }

    /// The tool list, rendered into a system prompt for models with no native format.
    static func injectJSONSchemaFallback(
        tools: [ToolDefinition],
        systemPrompt: String?
    ) -> String {
        guard !tools.isEmpty else { return systemPrompt ?? "" }

        var text = ""
        if let systemPrompt, !systemPrompt.isEmpty {
            text += "\(systemPrompt)\n\n"
        }
        text += "You have access to the following tools:\n"
        for tool in tools {
            text += "- \(tool.name): \(tool.description)\n  Schema: \(tool.parametersJSONSchema)\n"
        }
        text += """

        If you want to invoke a tool, you MUST respond ONLY with a JSON object in the following format:
        ```json
        {
          "tool": "<tool_name>",
          "arguments": { <arguments> }
        }
        ```
        If no tool is needed, respond with your normal plain text answer.
        """
        return text
    }

    /// Parses a fallback tool call out of plain assistant text.
    static func parseJSONToolFallback(content: String) -> ToolCall? {
        var jsonText = content.trimmingCharacters(in: .whitespacesAndNewlines)

        if let fenceStart = jsonText.range(of: "```json") ?? jsonText.range(of: "```") {
            let after = jsonText[fenceStart.upperBound...]
            if let fenceEnd = after.range(of: "```") {
                jsonText = String(after[..<fenceEnd.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        guard jsonText.hasPrefix("{"), jsonText.hasSuffix("}"),
              let data = jsonText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = (object["tool"] as? String) ?? (object["name"] as? String),
              !name.isEmpty else {
            return nil
        }

        let arguments = object["arguments"] ?? object["parameters"] ?? [:]
        let encoded = (try? JSONSerialization.data(withJSONObject: arguments)) ?? Data("{}".utf8)
        return ToolCall(name: name, arguments: String(data: encoded, encoding: .utf8) ?? "{}")
    }

    func executeLoop(
        messages: [ChatMessage],
        backend: ChatBackend,
        capability: ModelCapability,
        tools: [ChatTool] = [],
        systemPrompt: String? = nil,
        maxToolTurns: Int = 8
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream(ChatStreamEvent.self) { continuation in
            let task = Task {
                do {
                    try await self.run(
                        messages: messages,
                        backend: backend,
                        capability: capability,
                        tools: tools,
                        systemPrompt: systemPrompt,
                        maxToolTurns: maxToolTurns,
                        into: continuation
                    )
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: ChatBackendError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private func run(
        messages: [ChatMessage],
        backend: ChatBackend,
        capability: ModelCapability,
        tools: [ChatTool],
        systemPrompt: String?,
        maxToolTurns: Int,
        into continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation
    ) async throws {
        var history = messages
        let usesFallback = !tools.isEmpty && !capability.tools && !backend.executesToolsInternally
        let executors = Dictionary(
            tools.map { ($0.definition.name, $0.executor) },
            uniquingKeysWith: { _, last in last }
        )

        let effectiveSystemPrompt = usesFallback
            ? Self.injectJSONSchemaFallback(tools: tools.map(\.definition), systemPrompt: systemPrompt)
            : systemPrompt

        for _ in 0..<maxToolTurns {
            try Task.checkCancellation()

            var text = ""
            var calls: [ToolCall] = []
            var buffer = FallbackToolBuffer()
            var completion: (model: String, reason: String?)?

            let stream = try await backend.generateStream(
                messages: history,
                tools: usesFallback ? [] : tools,
                systemPrompt: effectiveSystemPrompt
            )

            for try await event in stream {
                try Task.checkCancellation()

                switch event {
                case .token(let token):
                    if usesFallback {
                        if let visible = buffer.append(token) {
                            text += visible
                            continuation.yield(.token(visible))
                        }
                    } else {
                        text += token
                        continuation.yield(.token(token))
                    }

                case .toolCall(let call):
                    // A self-executing backend reports its calls so the surface
                    // can show them; collecting one here would run it a second
                    // time, because the backend has already run it.
                    if !backend.executesToolsInternally {
                        calls.append(call)
                    }
                    continuation.yield(.toolCall(call))

                case .message(let message):
                    // A self-executing backend reports its own record directly.
                    history.append(message)
                    continuation.yield(.message(message))

                case .turnCompleted(let model, let reason):
                    completion = (model, reason)
                }
            }

            if usesFallback {
                let (call, remaining) = buffer.resolve()
                if let call {
                    calls.append(call)
                    continuation.yield(.toolCall(call))
                } else if !remaining.isEmpty {
                    text += remaining
                    continuation.yield(.token(remaining))
                }
            }

            guard !calls.isEmpty else {
                // A backend that executes internally has already reported its
                // assistant turn as `.message`; recording `text` too would double it.
                if !backend.executesToolsInternally {
                    let assistant = ChatMessage(role: .assistant, content: text, model: backend.id)
                    history.append(assistant)
                    continuation.yield(.message(assistant))
                }
                if let completion {
                    continuation.yield(.turnCompleted(model: completion.model, finishReason: completion.reason))
                }
                return
            }

            let assistant = ChatMessage(
                role: .assistant,
                content: text,
                model: backend.id,
                toolCalls: calls
            )
            history.append(assistant)
            continuation.yield(.message(assistant))

            for call in calls {
                try Task.checkCancellation()

                let output: String
                if let executor = executors[call.name] {
                    do {
                        output = try await executor.execute(call: call)
                    } catch {
                        log.error("Tool \(call.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                        output = "Error executing tool '\(call.name)': \(error.localizedDescription)"
                    }
                } else {
                    output = "Error: Tool '\(call.name)' is not registered."
                }

                let result = ChatMessage(
                    role: .tool,
                    content: output,
                    toolCallId: call.id,
                    toolName: call.name
                )
                history.append(result)
                continuation.yield(.message(result))
            }
        }

        log.notice("Tool loop hit its \(maxToolTurns) turn ceiling")
        continuation.yield(.turnCompleted(model: backend.id, finishReason: "max_tool_turns_reached"))
    }
}
