import Foundation
import os

/// Protocol for custom or MCP tool execution.
public nonisolated protocol ChatToolExecutor: Sendable {
    func execute(call: ToolCall) async throws -> String
}

/// Simple closure-based tool executor.
public nonisolated struct BlockToolExecutor: ChatToolExecutor {
    private let block: @Sendable (ToolCall) async throws -> String

    public init(_ block: @escaping @Sendable (ToolCall) async throws -> String) {
        self.block = block
    }

    public func execute(call: ToolCall) async throws -> String {
        try await block(call)
    }
}

/// The multi-turn conversation and tool execution harness loop (~400 lines).
///
/// Handles:
/// - Native tool calling for models declaring `tools == true` in `CapabilityRegistry`
/// - Prompt-and-parse JSON schema fallback for smaller models declaring `tools == false`
/// - Tool execution, result injection, and iterative generation until model finishes
public nonisolated final class ChatHarness: @unchecked Sendable {
    private let log = Logger(subsystem: "com.anthonyprosser.Sotto", category: "chat-harness")

    public static let shared = ChatHarness()

    public init() {}

    /// Format JSON schema fallback prompt for models without native tool tokens.
    public static func injectJSONSchemaFallback(
        tools: [ToolDefinition],
        systemPrompt: String?
    ) -> String {
        guard !tools.isEmpty else {
            return systemPrompt ?? ""
        }

        var text = (systemPrompt != nil && !systemPrompt!.isEmpty) ? "\(systemPrompt!)\n\n" : ""
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

    /// Attempt to parse JSON fallback tool call from plain assistant response text.
    public static func parseJSONToolFallback(content: String) -> ToolCall? {
        var jsonText = content.trimmingCharacters(in: .whitespacesAndNewlines)

        if let jsonBlockStart = jsonText.range(of: "```json") {
            let after = jsonText[jsonBlockStart.upperBound...]
            if let endFence = after.range(of: "```") {
                jsonText = String(after[..<endFence.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else if let genericBlockStart = jsonText.range(of: "```") {
            let after = genericBlockStart.upperBound < jsonText.endIndex ? jsonText[genericBlockStart.upperBound...] : ""
            if let endFence = after.range(of: "```") {
                jsonText = String(after[..<endFence.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        guard jsonText.hasPrefix("{") && jsonText.hasSuffix("}"),
              let data = jsonText.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let toolName = (obj["tool"] as? String) ?? (obj["name"] as? String)
        guard let name = toolName, !name.isEmpty else {
            return nil
        }

        let argsObj = obj["arguments"] ?? obj["parameters"] ?? [:]
        let argsData = (try? JSONSerialization.data(withJSONObject: argsObj)) ?? Data("{}".utf8)
        let argsString = String(data: argsData, encoding: .utf8) ?? "{}"

        return ToolCall(id: UUID().uuidString, name: name, arguments: argsString)
    }

    /// Execute multi-turn generation loop with tool execution.
    public func executeLoop(
        messages: [ChatMessage],
        backend: ChatBackend,
        capability: ModelCapability,
        tools: [ToolDefinition] = [],
        toolExecutors: [String: ChatToolExecutor] = [:],
        systemPrompt: String? = nil,
        maxToolTurns: Int = 8
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        return AsyncThrowingStream(ChatStreamEvent.self) { continuation in
            let task = Task {
                do {
                    var history = messages
                    var currentTurn = 0
                    let supportsNativeTools = capability.tools
                    let nativeTools = supportsNativeTools ? tools : []

                    let effectiveSystemPrompt: String? = supportsNativeTools
                        ? systemPrompt
                        : Self.injectJSONSchemaFallback(tools: tools, systemPrompt: systemPrompt)

                    while currentTurn < maxToolTurns {
                        try Task.checkCancellation()
                        currentTurn += 1

                        var turnTokens = ""
                        var turnToolCalls: [ToolCall] = []

                        let stream = try await backend.generateStream(
                            messages: history,
                            tools: nativeTools,
                            systemPrompt: effectiveSystemPrompt
                        )

                        for try await event in stream {
                            try Task.checkCancellation()

                            switch event {
                            case .token(let token):
                                turnTokens += token
                                continuation.yield(.token(token))

                            case .toolCall(let toolCall):
                                turnToolCalls.append(toolCall)
                                continuation.yield(.toolCall(toolCall))

                            case .turnCompleted(let model, let reason):
                                if turnToolCalls.isEmpty && !supportsNativeTools {
                                    // Check JSON fallback parsing
                                    if let fallbackCall = Self.parseJSONToolFallback(content: turnTokens) {
                                        turnToolCalls.append(fallbackCall)
                                        continuation.yield(.toolCall(fallbackCall))
                                    }
                                }

                                if turnToolCalls.isEmpty {
                                    continuation.yield(.turnCompleted(model: model, finishReason: reason))
                                }
                            }
                        }

                        // If no tool calls were requested, the conversation turn is complete
                        if turnToolCalls.isEmpty {
                            continuation.finish()
                            return
                        }

                        // Record assistant turn with tool calls in history
                        let assistantMsg = ChatMessage(
                            role: .assistant,
                            content: turnTokens,
                            model: backend.id,
                            toolCalls: turnToolCalls
                        )
                        history.append(assistantMsg)

                        // Execute all requested tool calls
                        for call in turnToolCalls {
                            try Task.checkCancellation()

                            let toolResultText: String
                            if let executor = toolExecutors[call.name] {
                                do {
                                    toolResultText = try await executor.execute(call: call)
                                } catch {
                                    toolResultText = "Error executing tool '\(call.name)': \(error.localizedDescription)"
                                }
                            } else {
                                toolResultText = "Error: Tool '\(call.name)' is not registered."
                            }

                            let toolResultMsg = ChatMessage(
                                role: .tool,
                                content: toolResultText,
                                toolCallId: call.id
                            )
                            history.append(toolResultMsg)
                        }

                        // Loop continues to feed tool results back to backend for the next turn
                    }

                    continuation.yield(.turnCompleted(model: backend.id, finishReason: "max_tool_turns_reached"))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: ChatBackendError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}
