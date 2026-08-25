import Foundation
import FoundationModels
import os

/// On-device Apple Intelligence backend using `FoundationModels.SystemLanguageModel`.
///
/// **Session isolation:** Instantiates its own `LanguageModelSession` per conversation/session
/// and never shares instances with `Cleanup.swift` (`DECISIONS.md`, 2026-08-19).
public nonisolated final class AppleFoundationBackend: ChatBackend, @unchecked Sendable {
    public let id: String
    public let backendType: BackendType = .appleFoundation

    private let log = Logger(subsystem: "com.anthonyprosser.Sotto", category: "apple-backend")
    private let model: SystemLanguageModel

    public init(id: String = "apple-foundation") {
        self.id = id
        self.model = SystemLanguageModel(
            useCase: .general,
            guardrails: .permissiveContentTransformations
        )
    }

    /// Check if Apple Foundation Models are available on this machine.
    public var isAvailable: Bool {
        if case .available = model.availability {
            return true
        }
        return false
    }

    public func generateStream(
        messages: [ChatMessage],
        tools: [ToolDefinition] = [],
        systemPrompt: String? = nil
    ) async throws -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let modelId = self.id
        let sysPrompt = systemPrompt

        return AsyncThrowingStream(ChatStreamEvent.self) { continuation in
            let task = Task {
                guard case .available = self.model.availability else {
                    let reason = String(describing: self.model.availability)
                    self.log.notice("Apple Foundation model not available: \(reason, privacy: .public)")
                    continuation.finish(throwing: ChatBackendError.modelUnavailable(reason))
                    return
                }

                do {
                    // Create an isolated session for this request/conversation
                    let session = LanguageModelSession(model: self.model)
                    
                    // Build input prompt from conversation history
                    var promptParts: [String] = []
                    if let sys = sysPrompt, !sys.isEmpty {
                        promptParts.append("System: \(sys)")
                    }

                    for msg in messages {
                        switch msg.role {
                        case .system:
                            promptParts.append("System: \(msg.content)")
                        case .user:
                            promptParts.append("User: \(msg.content)")
                        case .assistant:
                            promptParts.append("Assistant: \(msg.content)")
                        case .tool:
                            promptParts.append("Tool Result (\(msg.toolCallId ?? "")): \(msg.content)")
                        }
                    }

                    let fullPrompt = promptParts.joined(separator: "\n\n")

                    // Stream response from LanguageModelSession
                    var previousLength = 0
                    let stream = session.streamResponse(to: fullPrompt)

                    for try await chunk in stream {
                        try Task.checkCancellation()

                        let fullText = chunk.content
                        if fullText.count > previousLength {
                            let startIndex = fullText.index(fullText.startIndex, offsetBy: previousLength)
                            let newTokens = String(fullText[startIndex...])
                            previousLength = fullText.count

                            if !newTokens.isEmpty {
                                continuation.yield(.token(newTokens))
                            }
                        }
                    }

                    continuation.yield(.turnCompleted(model: modelId, finishReason: "stop"))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: ChatBackendError.cancelled)
                } catch {
                    self.log.error("FoundationModels generation error: \(error.localizedDescription, privacy: .public)")
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}
