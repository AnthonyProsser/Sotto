import Foundation
import os

/// High-level coordinator managing chat sessions and backend instances.
nonisolated final class ChatEngine: @unchecked Sendable {
    static let shared = ChatEngine()

    private let lock = NSLock()
    private var activeSessions: [UUID: ChatSession] = [:]
    private var backends: [String: ChatBackend] = [:]

    private let log = Logger(subsystem: "com.anthonyprosser.Sotto", category: "chat-engine")

    init() {
        // Apple's on-device model is the default so chat works at first run with
        // nothing downloaded (`rules/models-and-network.md` §1.1).
        let apple = AppleFoundationBackend()
        self.backends[apple.id] = apple
        self.backends["system"] = apple
    }

    /// Register a backend with the engine.
    func registerBackend(_ backend: ChatBackend) {
        lock.lock()
        defer { lock.unlock() }
        backends[backend.id] = backend
    }

    /// Retrieve a registered backend by ID.
    func backend(for id: String) -> ChatBackend? {
        lock.lock()
        defer { lock.unlock() }
        return backends[id]
    }

    /// Every model already on disk, registered as a backend and a capability.
    ///
    /// Discovery only — §7.4's acquisition ladder, the curated browser, and the
    /// download surface are slice 8's. This exists because slice 7's chat cannot
    /// run a local model it has no way to name.
    @discardableResult
    func registerLocalModels(in root: URL = ModelStore.root) -> [LocalModel] {
        let models = ModelStore.registerAll(in: root)
        for model in models {
            registerBackend(MLXBackend(model: model))
        }
        return models
    }

    /// Create a new chat session. The optional `created`/`modelsUsed` carry a
    /// persisted conversation back in (slice 10's restore) — rewriting a 2026
    /// chat with today's date, or collapsing its per-turn model list to one
    /// model, would falsify the record §9.1 keeps.
    func createSession(
        id: UUID = UUID(),
        slug: String? = nil,
        title: String? = nil,
        defaultModelId: String = "apple-foundation",
        initialMessages: [ChatMessage] = [],
        created: Date = Date(),
        modelsUsed: [String]? = nil,
        pinned: Bool = false,
        storageRoot: URL? = nil
    ) -> ChatSession {
        let session = ChatSession(
            id: id,
            slug: slug,
            title: title,
            activeModelId: defaultModelId,
            initialMessages: initialMessages,
            created: created,
            modelsUsed: modelsUsed,
            pinned: pinned,
            storageRoot: storageRoot
        )
        lock.lock()
        activeSessions[id] = session
        lock.unlock()
        return session
    }

    /// Retrieve an existing session by ID.
    func session(for id: UUID) -> ChatSession? {
        lock.lock()
        defer { lock.unlock() }
        return activeSessions[id]
    }

    /// Remove a session from active tracking.
    func closeSession(id: UUID) {
        lock.lock()
        activeSessions.removeValue(forKey: id)
        lock.unlock()
    }
}
