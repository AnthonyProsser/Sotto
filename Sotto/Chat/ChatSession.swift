import Foundation
import os

/// State and multi-turn message management for a single chat conversation.
public actor ChatSession {
    public nonisolated let id: UUID
    public nonisolated let slug: String
    public var title: String?
    public private(set) var activeModelId: String
    public private(set) var messages: [ChatMessage] = []
    public private(set) var modelsUsed: [String] = []
    public private(set) var created: Date
    public private(set) var updated: Date
    public var contextSize: Int = 4096
    public var systemPrompt: String?

    public var tools: [ToolDefinition] = []
    public var toolExecutors: [String: ChatToolExecutor] = [:]

    private let storageRoot: URL?
    private let log = Logger(subsystem: "com.anthonyprosser.Sotto", category: "chat-session")

    public init(
        id: UUID = UUID(),
        slug: String? = nil,
        title: String? = nil,
        activeModelId: String = "apple-foundation",
        initialMessages: [ChatMessage] = [],
        storageRoot: URL? = nil
    ) {
        let sid = id
        self.id = sid
        self.slug = slug ?? "chat-\(sid.uuidString.prefix(8).lowercased())"
        self.title = title
        self.activeModelId = activeModelId
        self.modelsUsed = [activeModelId]
        self.messages = initialMessages
        self.created = Date()
        self.updated = Date()
        self.storageRoot = storageRoot
    }

    /// Switch active model mid-conversation, preserving conversation history
    /// while attributing subsequent turns to the new model.
    public func switchModel(to newModelId: String) {
        self.activeModelId = newModelId
        if !modelsUsed.contains(newModelId) {
            modelsUsed.append(newModelId)
        }
        self.updated = Date()
        log.notice("Switched model to \(newModelId, privacy: .public)")
    }

    /// Register a tool with its execution handler for this conversation.
    public func registerTool(_ tool: ToolDefinition, executor: ChatToolExecutor) {
        tools.removeAll { $0.name == tool.name }
        tools.append(tool)
        toolExecutors[tool.name] = executor
    }

    /// Send a user message, run the tool/generation loop, stream tokens, and persist state.
    public func sendMessage(
        content: String,
        selection: String? = nil,
        backend: ChatBackend
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        var userContent = content
        if let sel = selection, !sel.isEmpty {
            userContent = "```selection\n\(sel)\n```\n\(content)"
        }

        let userMsg = ChatMessage(role: .user, content: userContent)
        self.messages.append(userMsg)
        self.updated = Date()

        if !modelsUsed.contains(backend.id) {
            modelsUsed.append(backend.id)
        }

        let modelId = backend.id
        let history = self.messages
        let sessionTools = self.tools
        let sessionExecutors = self.toolExecutors
        let sysPrompt = self.systemPrompt
        let capability = CapabilityRegistry.shared.capability(for: modelId) ?? ModelCapability(
            vision: false,
            tools: true,
            maxContext: 4096,
            backendType: backend.backendType
        )

        // Set Activity signal
        Task { @MainActor in
            Activity.shared.set(.generating, true)
        }

        let harnessStream = ChatHarness.shared.executeLoop(
            messages: history,
            backend: backend,
            capability: capability,
            tools: sessionTools,
            toolExecutors: sessionExecutors,
            systemPrompt: sysPrompt
        )

        return AsyncThrowingStream(ChatStreamEvent.self) { continuation in
            let forwardTask = Task {
                var accumulatedTokens = ""
                do {
                    for try await event in harnessStream {
                        try Task.checkCancellation()

                        switch event {
                        case .token(let token):
                            accumulatedTokens += token
                            continuation.yield(.token(token))
                        case .toolCall(let toolCall):
                            continuation.yield(.toolCall(toolCall))
                        case .turnCompleted(let m, let reason):
                            continuation.yield(.turnCompleted(model: m, finishReason: reason))
                        }
                    }

                    // Append assistant message to history
                    self.appendAssistantMessage(content: accumulatedTokens, model: modelId)
                    try self.saveToDisk()

                    await MainActor.run {
                        Activity.shared.set(.generating, false)
                    }

                    continuation.finish()
                } catch is CancellationError {
                    await MainActor.run {
                        Activity.shared.set(.generating, false)
                    }
                    continuation.finish(throwing: ChatBackendError.cancelled)
                } catch {
                    await MainActor.run {
                        Activity.shared.set(.generating, false)
                    }
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                forwardTask.cancel()
                Task { @MainActor in
                    Activity.shared.set(.generating, false)
                }
            }
        }
    }

    private func appendAssistantMessage(content: String, model: String) {
        let assistantMsg = ChatMessage(role: .assistant, content: content, model: model)
        self.messages.append(assistantMsg)
        self.updated = Date()
    }

    /// Snapshot current state as `ChatSessionState`.
    public func state() -> ChatSessionState {
        ChatSessionState(
            id: id,
            slug: slug,
            title: title,
            created: created,
            updated: updated,
            contextSize: contextSize,
            models: modelsUsed,
            messages: messages
        )
    }

    /// Persist current session markdown with YAML frontmatter to `ChatFolder`.
    public func saveToDisk() throws {
        let root = storageRoot ?? ChatFolder.root
        let currentState = state()
        let markdown = ChatSerializer.serialize(state: currentState)
        try ChatFolder.write(slug: slug, markdown: markdown, to: root)
    }
}
