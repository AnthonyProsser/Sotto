import Foundation
import os

/// State and multi-turn message management for a single chat conversation.
actor ChatSession {
    nonisolated let id: UUID
    nonisolated let slug: String
    var title: String?
    private(set) var activeModelId: String
    private(set) var messages: [ChatMessage] = []
    private(set) var modelsUsed: [String] = []
    private(set) var created: Date
    private(set) var updated: Date
    var contextSize: Int = 4096
    var systemPrompt: String?

    private(set) var tools: [ChatTool] = []

    private let storageRoot: URL?
    private let log = Logger(subsystem: "com.anthonyprosser.Sotto", category: "chat-session")

    init(
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
    /// while attributing subsequent turns to the new model (§9.1).
    func switchModel(to newModelId: String) {
        self.activeModelId = newModelId
        if !modelsUsed.contains(newModelId) {
            modelsUsed.append(newModelId)
        }
        self.updated = Date()
        log.notice("Switched model to \(newModelId, privacy: .public)")
    }

    /// Register a tool with its execution handler for this conversation.
    func registerTool(_ tool: ToolDefinition, executor: any ChatToolExecutor) {
        tools.removeAll { $0.definition.name == tool.name }
        tools.append(ChatTool(definition: tool, executor: executor))
    }

    /// Send a user message, run the tool/generation loop, stream tokens, and persist state.
    func sendMessage(
        content: String,
        selection: String? = nil,
        backend: ChatBackend
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        var userContent = content
        if let selection, !selection.isEmpty {
            userContent = "```selection\n\(selection)\n```\n\(content)"
        }

        let userMsg = ChatMessage(role: .user, content: userContent)
        self.messages.append(userMsg)
        self.updated = Date()

        if !modelsUsed.contains(backend.id) {
            modelsUsed.append(backend.id)
        }

        let modelId = backend.id
        let capability = CapabilityRegistry.shared.capability(for: modelId) ?? ModelCapability(
            vision: false,
            // Unknown means unknown: the prompt-and-parse fallback works on any
            // model, so it is the safe assumption. Claiming native tools for a
            // model that has none removes the capability silently.
            tools: false,
            maxContext: contextSize,
            backendType: backend.backendType
        )

        let harnessStream = ChatHarness.shared.executeLoop(
            messages: self.messages,
            backend: backend,
            capability: capability,
            tools: self.tools,
            systemPrompt: self.systemPrompt
        )

        Task { @MainActor in Activity.shared.set(.generating, true) }

        return AsyncThrowingStream(ChatStreamEvent.self) { continuation in
            let forwardTask = Task {
                do {
                    for try await event in harnessStream {
                        try Task.checkCancellation()

                        // `.message` is the record and `.token` is the display.
                        // Recording the concatenated tokens instead is what
                        // flattened tool calls into assistant prose: the calls
                        // and their results never appeared in the token stream
                        // at all, so nothing about them reached `chat.md`.
                        if case .message(let message) = event {
                            await self.record(message)
                        }
                        continuation.yield(event)
                    }

                    try await self.save()
                    await MainActor.run { Activity.shared.set(.generating, false) }
                    continuation.finish()
                } catch is CancellationError {
                    // A cancelled turn keeps whatever completed. Discarding it
                    // would lose a tool result the user watched run.
                    try? await self.save()
                    await MainActor.run { Activity.shared.set(.generating, false) }
                    continuation.finish(throwing: ChatBackendError.cancelled)
                } catch {
                    try? await self.save()
                    await MainActor.run { Activity.shared.set(.generating, false) }
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                forwardTask.cancel()
                Task { @MainActor in Activity.shared.set(.generating, false) }
            }
        }
    }

    private func record(_ message: ChatMessage) {
        messages.append(message)
        updated = Date()
    }

    private func save() throws {
        try saveToDisk()
    }

    /// Snapshot current state as `ChatSessionState`.
    func state() -> ChatSessionState {
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
    func saveToDisk() throws {
        try ChatFolder.write(
            slug: slug,
            markdown: ChatSerializer.serialize(state: state()),
            to: storageRoot ?? ChatFolder.root
        )
    }
}
