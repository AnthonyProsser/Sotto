import Foundation

/// Role of a message in a chat conversation.
nonisolated enum ChatRole: String, Sendable, Codable, Equatable {
    case system, user, assistant, tool
}

/// A structured tool call requested by a model.
nonisolated struct ToolCall: Sendable, Codable, Equatable, Identifiable {
    let id: String
    let name: String
    /// JSON object, encoded as a string. Kept as text because it crosses three
    /// backends that each have their own argument representation.
    let arguments: String

    init(id: String = UUID().uuidString, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// Definition of a tool exposed to the model.
nonisolated struct ToolDefinition: Sendable, Codable, Equatable {
    let name: String
    let description: String
    let parametersJSONSchema: String

    init(name: String, description: String, parametersJSONSchema: String = "{}") {
        self.name = name
        self.description = description
        self.parametersJSONSchema = parametersJSONSchema
    }
}

/// Runs one tool call.
nonisolated protocol ChatToolExecutor: Sendable {
    func execute(call: ToolCall) async throws -> String
}

/// Closure-based executor.
nonisolated struct BlockToolExecutor: ChatToolExecutor {
    private let block: @Sendable (ToolCall) async throws -> String

    init(_ block: @escaping @Sendable (ToolCall) async throws -> String) {
        self.block = block
    }

    func execute(call: ToolCall) async throws -> String {
        try await block(call)
    }
}

/// A tool the model may call, paired with the code that runs it.
///
/// Both halves travel together because backends disagree about who drives the
/// loop: Foundation Models calls the tool itself and needs the executor, while
/// MLX and the OpenAI adapter only announce the call and let `ChatHarness`
/// dispatch. One type keeps that difference inside the backends.
nonisolated struct ChatTool: Sendable {
    let definition: ToolDefinition
    let executor: any ChatToolExecutor

    init(definition: ToolDefinition, executor: any ChatToolExecutor) {
        self.definition = definition
        self.executor = executor
    }
}

/// Single message in a chat conversation.
nonisolated struct ChatMessage: Sendable, Codable, Equatable, Identifiable {
    let id: UUID
    let role: ChatRole
    let content: String
    /// Assistant turns only: which model produced this turn (§9.1).
    let model: String?
    let toolCalls: [ToolCall]?
    /// Tool results only: the `ToolCall.id` this answers.
    let toolCallId: String?
    /// Tool results only: kept so a reloaded transcript can name the tool.
    let toolName: String?
    let timestamp: Date

    init(
        id: UUID = UUID(),
        role: ChatRole,
        content: String,
        model: String? = nil,
        toolCalls: [ToolCall]? = nil,
        toolCallId: String? = nil,
        toolName: String? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.model = model
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.timestamp = timestamp
    }
}

/// Events yielded during streamed generation.
///
/// `token` and `toolCall` are for live display and are allowed to be partial or
/// superseded. `message` is the record: exactly the messages that belong in the
/// transcript, in order. Persisting the token stream instead is what flattened
/// tool calls into assistant prose in the first implementation.
nonisolated enum ChatStreamEvent: Sendable, Equatable {
    case token(String)
    case toolCall(ToolCall)
    case message(ChatMessage)
    case turnCompleted(model: String, finishReason: String?)
}

/// Unified async streaming contract for model backends.
nonisolated protocol ChatBackend: Sendable {
    var id: String { get }
    var backendType: BackendType { get }

    /// True when the backend runs the tool loop itself, so `ChatHarness` must not
    /// dispatch the same call a second time.
    var executesToolsInternally: Bool { get }

    func generateStream(
        messages: [ChatMessage],
        tools: [ChatTool],
        systemPrompt: String?
    ) async throws -> AsyncThrowingStream<ChatStreamEvent, Error>
}

extension ChatBackend {
    var executesToolsInternally: Bool { false }
}

/// Common backend errors.
///
/// There is no central error surface — each of these is routed by whichever
/// slice owns the surface that started the work (`rules/design.md` §10).
/// `modelUnavailable` is a configuration state and belongs in settings;
/// `modelLoadFailed` is a runtime failure and belongs on the chat surface.
nonisolated enum ChatBackendError: LocalizedError, Sendable, Equatable {
    case modelUnavailable(String)
    case modelLoadFailed(String)
    case connectionFailed(String)
    case invalidResponse(String)
    case contextLengthExceeded(Int)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .modelUnavailable(let reason):
            return "Model unavailable: \(reason)"
        case .modelLoadFailed(let reason):
            return "Model failed to load: \(reason)"
        case .connectionFailed(let reason):
            return "Connection failed: \(reason)"
        case .invalidResponse(let reason):
            return "Invalid response: \(reason)"
        case .contextLengthExceeded(let maxCtx):
            return "Context length exceeded (maximum \(maxCtx) tokens)"
        case .cancelled:
            return "Generation was cancelled"
        }
    }
}
