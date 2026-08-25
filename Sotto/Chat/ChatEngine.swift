import Foundation
import os

/// High-level coordinator managing chat sessions, backend instances, and execution.
public nonisolated final class ChatEngine: @unchecked Sendable {
    public static let shared = ChatEngine()

    private let lock = NSLock()
    private var activeSessions: [UUID: ChatSession] = [:]
    private var backends: [String: ChatBackend] = [:]

    private let log = Logger(subsystem: "com.anthonyprosser.Sotto", category: "chat-engine")

    public init() {
        // Register default Apple Foundation backend
        let apple = AppleFoundationBackend()
        self.backends[apple.id] = apple
        self.backends["system"] = apple
    }

    /// Register a backend with the engine.
    public func registerBackend(_ backend: ChatBackend) {
        lock.lock()
        defer { lock.unlock() }
        backends[backend.id] = backend
    }

    /// Retrieve a registered backend by ID.
    public func backend(for id: String) -> ChatBackend? {
        lock.lock()
        defer { lock.unlock() }
        return backends[id]
    }

    /// Create or retrieve a new chat session.
    public func createSession(
        id: UUID = UUID(),
        slug: String? = nil,
        title: String? = nil,
        defaultModelId: String = "apple-foundation",
        storageRoot: URL? = nil
    ) -> ChatSession {
        let session = ChatSession(
            id: id,
            slug: slug,
            title: title,
            activeModelId: defaultModelId,
            storageRoot: storageRoot
        )
        lock.lock()
        activeSessions[id] = session
        lock.unlock()
        return session
    }

    /// Retrieve an existing session by ID.
    public func session(for id: UUID) -> ChatSession? {
        lock.lock()
        defer { lock.unlock() }
        return activeSessions[id]
    }

    /// Remove a session from active tracking.
    public func closeSession(id: UUID) {
        lock.lock()
        activeSessions.removeValue(forKey: id)
        lock.unlock()
    }
}
