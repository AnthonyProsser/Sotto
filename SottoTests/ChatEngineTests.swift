import Testing
import Foundation
@testable import Sotto

// MARK: - Mock Backend for Testing

private struct MockBackend: ChatBackend {
    let id: String
    let backendType: BackendType
    let responses: [String]

    init(id: String, backendType: BackendType = .openAI, responses: [String] = ["Mock response"]) {
        self.id = id
        self.backendType = backendType
        self.responses = responses
    }

    func generateStream(
        messages: [ChatMessage],
        tools: [ToolDefinition] = [],
        systemPrompt: String? = nil
    ) async throws -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let modelId = self.id
        let resps = self.responses

        return AsyncThrowingStream(ChatStreamEvent.self) { continuation in
            for resp in resps {
                continuation.yield(.token(resp))
            }
            continuation.yield(.turnCompleted(model: modelId, finishReason: "stop"))
            continuation.finish()
        }
    }
}

private struct MockToolCallingBackend: ChatBackend {
    let id: String
    let backendType: BackendType = .appleFoundation
    let toolCallToEmit: ToolCall

    func generateStream(
        messages: [ChatMessage],
        tools: [ToolDefinition] = [],
        systemPrompt: String? = nil
    ) async throws -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let modelId = self.id
        let call = self.toolCallToEmit

        return AsyncThrowingStream(ChatStreamEvent.self) { continuation in
            // Check if last message is a tool response
            if let last = messages.last, last.role == .tool {
                continuation.yield(.token("The result is: \(last.content)"))
                continuation.yield(.turnCompleted(model: modelId, finishReason: "stop"))
                continuation.finish()
            } else {
                continuation.yield(.toolCall(call))
                continuation.yield(.turnCompleted(model: modelId, finishReason: "tool_calls"))
                continuation.finish()
            }
        }
    }
}

// MARK: - Tests

struct ChatEngineTests {

    @Test func serializerRoundtripsYAMLFrontmatterAndMessages() throws {
        let state = ChatSessionState(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            slug: "test-chat",
            title: "Testing Roundtrip",
            created: Date(timeIntervalSince1970: 1_700_000_000),
            updated: Date(timeIntervalSince1970: 1_700_000_500),
            contextSize: 8192,
            models: ["apple-foundation", "qwen2.5:7b"],
            messages: [
                ChatMessage(role: .system, content: "You are a helpful assistant."),
                ChatMessage(role: .user, content: "Hello!"),
                ChatMessage(role: .assistant, content: "Hi there!", model: "apple-foundation"),
                ChatMessage(role: .user, content: "Can you switch models?"),
                ChatMessage(role: .assistant, content: "Switched to Qwen.", model: "qwen2.5:7b")
            ]
        )

        let markdown = ChatSerializer.serialize(state: state)
        #expect(markdown.contains("slug: test-chat"))
        #expect(markdown.contains("- apple-foundation"))
        #expect(markdown.contains("- qwen2.5:7b"))
        #expect(markdown.contains("### Assistant (apple-foundation)"))
        #expect(markdown.contains("### Assistant (qwen2.5:7b)"))

        let parsed = try ChatSerializer.deserialize(markdown: markdown, defaultSlug: "test-chat")
        #expect(parsed.id == state.id)
        #expect(parsed.slug == "test-chat")
        #expect(parsed.title == "Testing Roundtrip")
        #expect(parsed.contextSize == 8192)
        #expect(parsed.models == ["apple-foundation", "qwen2.5:7b"])
        #expect(parsed.messages.count == 5)
        #expect(parsed.messages[2].model == "apple-foundation")
        #expect(parsed.messages[4].model == "qwen2.5:7b")
    }

    @Test func harnessExecutesToolLoopAndAppendsResults() async throws {
        let toolCall = ToolCall(id: "call_weather_1", name: "get_weather", arguments: "{\"location\":\"San Francisco\"}")
        let backend = MockToolCallingBackend(id: "tool-model", toolCallToEmit: toolCall)

        let toolDef = ToolDefinition(name: "get_weather", description: "Get weather for a location")
        let toolExecutor = BlockToolExecutor { call in
            #expect(call.name == "get_weather")
            return "68F and Sunny"
        }

        let capability = ModelCapability(vision: false, tools: true, maxContext: 4096, backendType: .appleFoundation)

        var streamEvents: [ChatStreamEvent] = []
        let stream = ChatHarness.shared.executeLoop(
            messages: [ChatMessage(role: .user, content: "What's the weather in SF?")],
            backend: backend,
            capability: capability,
            tools: [toolDef],
            toolExecutors: ["get_weather": toolExecutor]
        )

        for try await event in stream {
            streamEvents.append(event)
        }

        #expect(streamEvents.contains { event in
            if case .toolCall(let tc) = event {
                return tc.name == "get_weather"
            }
            return false
        })

        #expect(streamEvents.contains { event in
            if case .token(let token) = event {
                return token.contains("68F and Sunny")
            }
            return false
        })
    }

    @Test func harnessParsesJSONToolFallbackForSmallerModels() {
        let jsonOutput = """
        I will look that up for you.
        ```json
        {
          "tool": "calculator",
          "arguments": {
            "expression": "42 * 2"
          }
        }
        ```
        """
        let parsed = ChatHarness.parseJSONToolFallback(content: jsonOutput)
        #expect(parsed != nil)
        #expect(parsed?.name == "calculator")
        #expect(parsed?.arguments.contains("42 * 2") == true)
    }

    @Test func sessionHandlesMidConversationModelSwitchingAndPersistence() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sotto-chat-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let session = ChatSession(
            slug: "session-switching-test",
            activeModelId: "apple-foundation",
            storageRoot: root
        )

        let backendA = MockBackend(id: "apple-foundation", responses: ["Hello from Apple Foundation"])
        let streamA = await session.sendMessage(content: "First turn", backend: backendA)
        for try await _ in streamA {}

        // Switch model
        await session.switchModel(to: "mlx-qwen-7b")

        let backendB = MockBackend(id: "mlx-qwen-7b", backendType: .mlx, responses: ["Hello from Qwen"])
        let streamB = await session.sendMessage(content: "Second turn", backend: backendB)
        for try await _ in streamB {}

        let state = await session.state()
        #expect(state.models == ["apple-foundation", "mlx-qwen-7b"])
        #expect(state.messages.count == 4) // User1, Assistant1, User2, Assistant2
        #expect(state.messages[1].model == "apple-foundation")
        #expect(state.messages[3].model == "mlx-qwen-7b")

        // Check disk file written by ChatFolder
        let chatFile = root.appendingPathComponent("session-switching-test/chat.md")
        #expect(FileManager.default.fileExists(atPath: chatFile.path))

        let fileContent = try String(contentsOf: chatFile, encoding: .utf8)
        #expect(fileContent.contains("### Assistant (apple-foundation)"))
        #expect(fileContent.contains("### Assistant (mlx-qwen-7b)"))
        #expect(fileContent.contains("- apple-foundation"))
        #expect(fileContent.contains("- mlx-qwen-7b"))
    }

    @Test func engineManagesSessionLifecycleAndBackendRegistration() {
        let engine = ChatEngine()
        let customBackend = MockBackend(id: "custom-ollama", backendType: .openAI)
        engine.registerBackend(customBackend)

        let retrieved = engine.backend(for: "custom-ollama")
        #expect(retrieved?.id == "custom-ollama")
        #expect(retrieved?.backendType == .openAI)

        let sessionId = UUID()
        let session = engine.createSession(id: sessionId, slug: "custom-session")
        #expect(session.slug == "custom-session")

        let fetched = engine.session(for: sessionId)
        #expect(fetched != nil)

        engine.closeSession(id: sessionId)
        #expect(engine.session(for: sessionId) == nil)
    }
}
