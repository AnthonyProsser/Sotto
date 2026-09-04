//
//  ChatEngineTests.swift
//  SottoTests
//
//  Slice 7. The pure parts of the chat engine: what `chat.md` round-trips, what
//  the SSE decoder makes of a real response body, which tool path the harness
//  picks, and what it records. The parts that are not pure — the three backends
//  actually generating — were probed against the running models instead.
//

import Testing
import Foundation
import FoundationModels
@testable import Sotto

// MARK: - Doubles

/// Yields a fixed script and nothing else.
private struct ScriptedBackend: ChatBackend {
    let id: String
    let backendType: BackendType
    let events: [ChatStreamEvent]

    init(id: String, backendType: BackendType = .openAI, events: [ChatStreamEvent]) {
        self.id = id
        self.backendType = backendType
        self.events = events
    }

    init(id: String, backendType: BackendType = .openAI, text: String) {
        self.init(
            id: id,
            backendType: backendType,
            events: [.token(text), .turnCompleted(model: id, finishReason: "stop")]
        )
    }

    func generateStream(
        messages: [ChatMessage],
        tools: [ChatTool],
        systemPrompt: String?
    ) async throws -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let events = self.events
        return AsyncThrowingStream(ChatStreamEvent.self) { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

/// Calls a tool on the first turn, answers with the result on the second.
private struct ToolCallingBackend: ChatBackend {
    let id: String
    let backendType: BackendType = .openAI
    let call: ToolCall

    func generateStream(
        messages: [ChatMessage],
        tools: [ChatTool],
        systemPrompt: String?
    ) async throws -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let id = self.id
        let call = self.call
        let answered = messages.contains { $0.role == .tool }

        return AsyncThrowingStream(ChatStreamEvent.self) { continuation in
            if answered {
                let result = messages.last { $0.role == .tool }?.content ?? ""
                continuation.yield(.token("The result is: \(result)"))
                continuation.yield(.turnCompleted(model: id, finishReason: "stop"))
            } else {
                continuation.yield(.toolCall(call))
                continuation.yield(.turnCompleted(model: id, finishReason: "tool_calls"))
            }
            continuation.finish()
        }
    }
}

/// Stands in for Apple's backend: runs its own tool loop and reports the record.
private struct SelfExecutingBackend: ChatBackend {
    let id = "self-executing"
    let backendType: BackendType = .appleFoundation
    let executesToolsInternally = true
    let call: ToolCall

    func generateStream(
        messages: [ChatMessage],
        tools: [ChatTool],
        systemPrompt: String?
    ) async throws -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let id = self.id
        let call = self.call
        return AsyncThrowingStream(ChatStreamEvent.self) { continuation in
            continuation.yield(.token("Sunny."))
            continuation.yield(.toolCall(call))
            continuation.yield(.message(ChatMessage(role: .assistant, content: "", model: id, toolCalls: [call])))
            continuation.yield(.message(ChatMessage(role: .tool, content: "68F", toolCallId: call.id, toolName: call.name)))
            continuation.yield(.message(ChatMessage(role: .assistant, content: "Sunny.", model: id)))
            continuation.yield(.turnCompleted(model: id, finishReason: "stop"))
            continuation.finish()
        }
    }
}

/// Counts executions so a double dispatch is visible rather than merely absent.
private final class CountingExecutor: ChatToolExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return _count }

    func execute(call: ToolCall) async throws -> String {
        lock.lock(); _count += 1; lock.unlock()
        return "68F"
    }
}

// MARK: - Serialization

struct ChatSerializerTests {

    private func state(_ messages: [ChatMessage]) -> ChatSessionState {
        ChatSessionState(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            slug: "test-chat",
            title: "Testing Roundtrip",
            created: Date(timeIntervalSince1970: 1_700_000_000),
            updated: Date(timeIntervalSince1970: 1_700_000_500),
            contextSize: 8192,
            models: ["apple-foundation", "qwen2.5:7b"],
            messages: messages
        )
    }

    @Test func roundtripsFrontmatterAndPerTurnModelAttribution() throws {
        let original = state([
            ChatMessage(role: .system, content: "You are a helpful assistant."),
            ChatMessage(role: .user, content: "Hello!"),
            ChatMessage(role: .assistant, content: "Hi there!", model: "apple-foundation"),
            ChatMessage(role: .user, content: "Can you switch models?"),
            ChatMessage(role: .assistant, content: "Switched to Qwen.", model: "qwen2.5:7b")
        ])

        let markdown = ChatSerializer.serialize(state: original)
        // §9.1's readable form survives alongside the parser's markers.
        #expect(markdown.contains("slug: test-chat"))
        #expect(markdown.contains("- qwen2.5:7b"))
        #expect(markdown.contains("### Assistant (apple-foundation)"))
        #expect(markdown.contains("### Assistant (qwen2.5:7b)"))

        let parsed = try ChatSerializer.deserialize(markdown: markdown, defaultSlug: "test-chat")
        #expect(parsed.id == original.id)
        #expect(parsed.title == "Testing Roundtrip")
        #expect(parsed.contextSize == 8192)
        #expect(parsed.models == ["apple-foundation", "qwen2.5:7b"])
        #expect(parsed.messages.count == 5)
        #expect(parsed.messages[2].model == "apple-foundation")
        #expect(parsed.messages[4].model == "qwen2.5:7b")
    }

    /// The defect that made the dual-marker format necessary: models write `###`
    /// constantly, and splitting on it truncated the turn at the first heading.
    @Test func keepsMarkdownHeadingsInsideAnAssistantTurn() throws {
        let content = "Here you go.\n\n### Summary\nIt works.\n\n### Caveats\nNone."
        let markdown = ChatSerializer.serialize(state: state([
            ChatMessage(role: .assistant, content: content, model: "qwen2.5:7b")
        ]))

        let parsed = try ChatSerializer.deserialize(markdown: markdown)
        #expect(parsed.messages.count == 1)
        #expect(parsed.messages[0].content == content)
    }

    @Test func keepsHorizontalRulesAndFencedCodeInsideATurn() throws {
        let content = "Before.\n\n---\n\n```swift\nlet x = 1\n```\n\nAfter."
        let markdown = ChatSerializer.serialize(state: state([
            ChatMessage(role: .user, content: content)
        ]))

        let parsed = try ChatSerializer.deserialize(markdown: markdown)
        #expect(parsed.messages.count == 1)
        #expect(parsed.messages[0].content == content)
    }

    @Test func roundtripsToolCallsAndToolResults() throws {
        let call = ToolCall(id: "call_1", name: "get_weather", arguments: "{\"location\":\"San Francisco\"}")
        let markdown = ChatSerializer.serialize(state: state([
            ChatMessage(role: .user, content: "Weather in SF?"),
            ChatMessage(role: .assistant, content: "", model: "qwen2.5:7b", toolCalls: [call]),
            ChatMessage(role: .tool, content: "68F and sunny", toolCallId: "call_1", toolName: "get_weather"),
            ChatMessage(role: .assistant, content: "It is 68F and sunny.", model: "qwen2.5:7b")
        ]))

        let parsed = try ChatSerializer.deserialize(markdown: markdown)
        #expect(parsed.messages.count == 4)

        #expect(parsed.messages[1].role == .assistant)
        #expect(parsed.messages[1].toolCalls?.count == 1)
        #expect(parsed.messages[1].toolCalls?[0].id == "call_1")
        #expect(parsed.messages[1].toolCalls?[0].name == "get_weather")
        #expect(parsed.messages[1].toolCalls?[0].arguments == "{\"location\":\"San Francisco\"}")

        #expect(parsed.messages[2].role == .tool)
        #expect(parsed.messages[2].content == "68F and sunny")
        #expect(parsed.messages[2].toolCallId == "call_1")
        #expect(parsed.messages[2].toolName == "get_weather")
    }

    @Test func keepsBothContentAndToolCallsOnOneAssistantTurn() throws {
        let call = ToolCall(id: "call_2", name: "search", arguments: "{\"q\":\"sotto\"}")
        let markdown = ChatSerializer.serialize(state: state([
            ChatMessage(role: .assistant, content: "Let me look that up.", model: "m", toolCalls: [call])
        ]))

        let parsed = try ChatSerializer.deserialize(markdown: markdown)
        #expect(parsed.messages[0].content == "Let me look that up.")
        #expect(parsed.messages[0].toolCalls?[0].arguments == "{\"q\":\"sotto\"}")
    }

    /// A chat *about* Sotto's file format must not be able to forge a boundary.
    @Test func escapesALiteralDelimiterInsideAMessage() throws {
        let content = "The parser reads <!-- sotto:msg role=\"user\" --> as a marker."
        let markdown = ChatSerializer.serialize(state: state([
            ChatMessage(role: .user, content: content)
        ]))

        let parsed = try ChatSerializer.deserialize(markdown: markdown)
        #expect(parsed.messages.count == 1)
        #expect(parsed.messages[0].content == content)
    }

    /// §9.1's flag, added in slice 10 — frontmatter carries it only when set,
    /// so every chat written before this slice still parses (`pinned` defaults
    /// false).
    @Test func roundtripsThePinnedFlag() throws {
        var pinned = state([ChatMessage(role: .user, content: "Keep me")])
        pinned.pinned = true
        let markdown = ChatSerializer.serialize(state: pinned)
        #expect(markdown.contains("pinned: true"))

        let parsed = try ChatSerializer.deserialize(markdown: markdown, defaultSlug: "test-chat")
        #expect(parsed.pinned == true)

        let unpinnedMarkdown = ChatSerializer.serialize(state: state([ChatMessage(role: .user, content: "Plain")]))
        #expect(!unpinnedMarkdown.contains("pinned"))
        let unpinnedParsed = try ChatSerializer.deserialize(markdown: unpinnedMarkdown, defaultSlug: "test-chat")
        #expect(unpinnedParsed.pinned == false)
    }

    @Test func survivesAHandEditedHeading() throws {
        let markdown = ChatSerializer.serialize(state: state([
            ChatMessage(role: .assistant, content: "Body.", model: "m")
        ])).replacingOccurrences(of: "### Assistant (m)", with: "### Renamed by hand")

        let parsed = try ChatSerializer.deserialize(markdown: markdown)
        #expect(parsed.messages[0].content == "Body.")
        #expect(parsed.messages[0].model == "m")
    }
}

// MARK: - OpenAI SSE decoding

struct OpenAIStreamDecoderTests {

    private func run(_ lines: [String]) -> [OpenAIStreamDecoder.Event] {
        var decoder = OpenAIStreamDecoder()
        var events = lines.flatMap { decoder.decode(line: $0) }
        events += decoder.finish()
        return events
    }

    @Test func decodesContentDeltasAndDone() {
        let events = run([
            "data: {\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}",
            "",
            "data: {\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}",
            "data: [DONE]"
        ])

        #expect(events == [.token("Hel"), .token("lo"), .finished(reason: "stop")])
    }

    @Test func ignoresCommentsAndMalformedFrames() {
        let events = run([
            ": ping",
            "event: message",
            "data: not json at all",
            "data: {\"choices\":[]}",
            "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}",
            "data: [DONE]"
        ])

        #expect(events == [.token("ok"), .finished(reason: "stop")])
    }

    /// The case a naive decoder gets wrong: arguments arrive as fragments and are
    /// only valid concatenated, and the name arrives once in the first frame.
    @Test func reassemblesToolCallArgumentsSplitAcrossFrames() {
        let events = run([
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_a\",\"function\":{\"name\":\"get_weather\",\"arguments\":\"\"}}]}}]}",
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\\\"loc\\\"\"}}]}}]}",
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\":\\\"SF\\\"}\"}}]}}]}",
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}"
        ])

        #expect(events.count == 2)
        guard case .toolCall(let call) = events[0] else {
            Issue.record("expected a tool call, got \(events[0])")
            return
        }
        #expect(call.id == "call_a")
        #expect(call.name == "get_weather")
        #expect(call.arguments == "{\"loc\":\"SF\"}")
        #expect(events[1] == .finished(reason: "tool_calls"))
    }

    @Test func emitsMultipleToolCallsInIndexOrder() {
        let events = run([
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":1,\"id\":\"b\",\"function\":{\"name\":\"second\",\"arguments\":\"{}\"}}]}}]}",
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"a\",\"function\":{\"name\":\"first\",\"arguments\":\"{}\"}}]}}]}",
            "data: [DONE]"
        ])

        let names = events.compactMap { event -> String? in
            if case .toolCall(let call) = event { return call.name }
            return nil
        }
        #expect(names == ["first", "second"])
    }

    /// llama-server closes the body without a `[DONE]` frame.
    @Test func flushesWhenTheBodyEndsWithoutDone() {
        let events = run([
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"a\",\"function\":{\"name\":\"f\",\"arguments\":\"{}\"}}]}}]}"
        ])

        #expect(events.count == 2)
        #expect(events.last == .finished(reason: "stop"))
    }

    @Test func stopsProducingEventsAfterTheTurnEnds() {
        var decoder = OpenAIStreamDecoder()
        _ = decoder.decode(line: "data: [DONE]")
        #expect(decoder.decode(line: "data: {\"choices\":[{\"delta\":{\"content\":\"late\"}}]}").isEmpty)
        #expect(decoder.finish().isEmpty)
    }

    /// LM Studio's own UI prints the base URL with `/v1` already on it.
    @Test func doesNotDoubleAppendTheVersionPath() {
        #expect(OpenAICompatibleBackend.completionsURL(base: URL(string: "http://localhost:1234")!).absoluteString
                == "http://localhost:1234/v1/chat/completions")
        #expect(OpenAICompatibleBackend.completionsURL(base: URL(string: "http://localhost:1234/v1")!).absoluteString
                == "http://localhost:1234/v1/chat/completions")
        #expect(OpenAICompatibleBackend.completionsURL(base: URL(string: "http://localhost:1234/v1/")!).absoluteString
                == "http://localhost:1234/v1/chat/completions")
    }

    @Test func sendsToolResultsBackWithTheirCallId() throws {
        let body = OpenAICompatibleBackend.requestBody(
            model: "m",
            messages: [ChatMessage(role: .tool, content: "68F", toolCallId: "call_a", toolName: "get_weather")],
            tools: [],
            systemPrompt: nil
        )
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages[0]["tool_call_id"] as? String == "call_a")
        #expect(messages[0]["name"] as? String == "get_weather")
    }
}

// MARK: - Capability detection

struct CapabilityDetectionTests {

    /// `tools = true` was hardcoded, which made the fallback unreachable and the
    /// native path a silent no-op on models with no tool support.
    @Test func readsToolSupportFromTheChatTemplate() {
        #expect(CapabilityRegistry.toolsSupported(chatTemplate: nil) == false)
        #expect(CapabilityRegistry.toolsSupported(chatTemplate: "{% for message in messages %}{{ message.content }}{% endfor %}") == false)
        #expect(CapabilityRegistry.toolsSupported(chatTemplate: "{% if tools %}<tools>{{ tools }}</tools>{% endif %}") == true)
    }

    @Test func readsGeometryAndVisionFromConfigJSON() throws {
        let config = """
        {"model_type":"llama","architectures":["LlamaForCausalLM"],"num_hidden_layers":52,
         "num_attention_heads":16,"num_key_value_heads":2,"hidden_size":2048,"head_dim":128,
         "max_position_embeddings":131072}
        """
        let (capability, geometry) = try CapabilityRegistry.parseMLXConfig(data: Data(config.utf8))

        #expect(capability.vision == false)
        #expect(capability.tools == false)  // no template supplied
        #expect(capability.maxContext == 131_072)
        #expect(geometry == ModelGeometry(layerCount: 52, kvHeadCount: 2, headDimension: 128))
    }

    @Test func detectsVisionFromAVisionConfig() throws {
        let config = "{\"model_type\":\"qwen2_vl\",\"vision_config\":{},\"num_hidden_layers\":28}"
        let (capability, _) = try CapabilityRegistry.parseMLXConfig(data: Data(config.utf8))
        #expect(capability.vision == true)
    }

    @Test func fallsBackToTheTemplateWhenOllamaOmitsCapabilities() throws {
        let show = "{\"template\":\"{% if tools %}{{ tools }}{% endif %}\",\"model_info\":{}}"
        let (capability, _) = try CapabilityRegistry.parseOllamaShow(data: Data(show.utf8))
        #expect(capability.tools == true)
    }
}

// MARK: - Model discovery

struct ModelStoreTests {

    private func makeModel(named name: String, in root: URL, template: String?, templateInConfig: Bool) throws -> URL {
        let directory = root.appending(path: name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("""
        {"model_type":"llama","num_hidden_layers":4,"num_attention_heads":8,
         "num_key_value_heads":2,"hidden_size":512,"head_dim":64,"max_position_embeddings":8192}
        """.utf8).write(to: directory.appending(path: "config.json"))
        try Data(count: 1024).write(to: directory.appending(path: "model.safetensors"))

        if let template {
            if templateInConfig {
                let config = ["chat_template": template]
                try JSONSerialization.data(withJSONObject: config)
                    .write(to: directory.appending(path: "tokenizer_config.json"))
            } else {
                try Data("{}".utf8).write(to: directory.appending(path: "tokenizer_config.json"))
                try Data(template.utf8).write(to: directory.appending(path: "chat_template.jinja"))
            }
        }
        return directory
    }

    @Test func readsWeightsSizeGeometryAndCapability() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "sotto-models-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try makeModel(named: "test-model", in: root, template: "{% if tools %}{% endif %}", templateInConfig: true)

        let models = ModelStore.discover(in: root)
        #expect(models.count == 1)
        #expect(models[0].id == "test-model")
        #expect(models[0].weightsBytes == 1024)
        #expect(models[0].capability.tools == true)
        #expect(models[0].capability.maxContext == 8192)
        #expect(models[0].geometry == ModelGeometry(layerCount: 4, kvHeadCount: 2, headDimension: 64))
    }

    /// Newer MLX conversions — G9v3-3B among them — leave `chat_template` out of
    /// `tokenizer_config.json` and write a sibling `.jinja` instead. Reading only
    /// the first place reports "no template," and therefore no tool support.
    @Test func findsAChatTemplateInASiblingJinjaFile() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "sotto-models-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try makeModel(named: "jinja-model", in: root, template: "{% if tools %}{% endif %}", templateInConfig: false)

        #expect(ModelStore.discover(in: root)[0].capability.tools == true)
    }

    @Test func skipsDirectoriesWithNoWeightsAndMissingRoots() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "sotto-models-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "metadata-only"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("{\"model_type\":\"llama\"}".utf8)
            .write(to: root.appending(path: "metadata-only/config.json"))

        #expect(ModelStore.discover(in: root).isEmpty)
        #expect(ModelStore.discover(in: root.appending(path: "does-not-exist")).isEmpty)
    }

    @Test func estimatesMemoryFromWeightsAndGeometry() {
        let model = LocalModel(
            id: "m",
            directory: URL(fileURLWithPath: "/tmp/m"),
            weightsBytes: 1_681_564_038,
            capability: ModelCapability(vision: false, tools: true, maxContext: 131_072, backendType: .mlx),
            geometry: ModelGeometry(layerCount: 52, kvHeadCount: 2, headDimension: 128)
        )

        // §2.3: 2 * 52 * 2 * 128 * 4096 * 2
        let estimate = model.memoryEstimate(contextLength: 4096)
        #expect(estimate.kvCacheBytes == 2 * 52 * 2 * 128 * 4096 * 2)
        #expect(estimate.totalBytes == Int64(Double(model.weightsBytes + estimate.kvCacheBytes) * 1.15))
    }
}

// MARK: - The harness

struct ChatHarnessTests {

    private let nativeTools = ModelCapability(vision: false, tools: true, maxContext: 4096, backendType: .openAI)
    private let noNativeTools = ModelCapability(vision: false, tools: false, maxContext: 4096, backendType: .openAI)

    private func collect(_ stream: AsyncThrowingStream<ChatStreamEvent, Error>) async throws -> [ChatStreamEvent] {
        var events: [ChatStreamEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }

    private func messages(_ events: [ChatStreamEvent]) -> [ChatMessage] {
        events.compactMap { if case .message(let m) = $0 { return m } else { return nil } }
    }

    private func text(_ events: [ChatStreamEvent]) -> String {
        events.compactMap { if case .token(let t) = $0 { return t } else { return nil } }.joined()
    }

    private func weatherTool(_ executor: any ChatToolExecutor) -> ChatTool {
        ChatTool(
            definition: ToolDefinition(
                name: "get_weather",
                description: "Get weather for a location",
                parametersJSONSchema: "{\"type\":\"object\",\"properties\":{\"location\":{\"type\":\"string\"}},\"required\":[\"location\"]}"
            ),
            executor: executor
        )
    }

    @Test func runsTheToolLoopAndRecordsEveryTurnOfIt() async throws {
        let executor = CountingExecutor()
        let call = ToolCall(id: "call_1", name: "get_weather", arguments: "{\"location\":\"SF\"}")

        let events = try await collect(ChatHarness.shared.executeLoop(
            messages: [ChatMessage(role: .user, content: "Weather in SF?")],
            backend: ToolCallingBackend(id: "tool-model", call: call),
            capability: nativeTools,
            tools: [weatherTool(executor)]
        ))

        #expect(executor.count == 1)

        // The record, not the token stream: call, result, answer.
        let recorded = messages(events)
        #expect(recorded.count == 3)
        #expect(recorded[0].role == .assistant)
        #expect(recorded[0].toolCalls?[0].name == "get_weather")
        #expect(recorded[1].role == .tool)
        #expect(recorded[1].content == "68F")
        #expect(recorded[1].toolCallId == "call_1")
        #expect(recorded[1].toolName == "get_weather")
        #expect(recorded[2].role == .assistant)
        #expect(recorded[2].content == "The result is: 68F")
    }

    /// The backend already ran the tool; collecting its announcement would run it again.
    @Test func doesNotRedispatchASelfExecutingBackendsCalls() async throws {
        let executor = CountingExecutor()
        let call = ToolCall(id: "call_1", name: "get_weather", arguments: "{}")

        let events = try await collect(ChatHarness.shared.executeLoop(
            messages: [ChatMessage(role: .user, content: "Weather?")],
            backend: SelfExecutingBackend(call: call),
            capability: nativeTools,
            tools: [weatherTool(executor)]
        ))

        #expect(executor.count == 0)

        let recorded = messages(events)
        #expect(recorded.count == 3)
        #expect(recorded[0].toolCalls?.count == 1)
        #expect(recorded[1].role == .tool)
        // Its own final answer, recorded once — not doubled by the harness.
        #expect(recorded.filter { $0.role == .assistant && $0.content == "Sunny." }.count == 1)
    }

    @Test func injectsTheToolSchemaOnlyWhenTheModelHasNoNativeSupport() {
        let definition = ToolDefinition(name: "calculator", description: "Do maths")
        let injected = ChatHarness.injectJSONSchemaFallback(tools: [definition], systemPrompt: "Be brief.")
        #expect(injected.contains("Be brief."))
        #expect(injected.contains("calculator"))

        #expect(ChatHarness.injectJSONSchemaFallback(tools: [], systemPrompt: "Be brief.") == "Be brief.")
    }

    @Test func parsesAFencedJSONToolCall() {
        let parsed = ChatHarness.parseJSONToolFallback(content: """
        ```json
        {"tool": "calculator", "arguments": {"expression": "42 * 2"}}
        ```
        """)
        #expect(parsed?.name == "calculator")
        #expect(parsed?.arguments.contains("42 * 2") == true)
    }

    /// The leak: protocol JSON reached the transcript concatenated with the answer.
    @Test func holdsBackFallbackJSONAndNeverShowsIt() async throws {
        let executor = CountingExecutor()
        let call = "{\"tool\": \"get_weather\", \"arguments\": {\"location\": \"SF\"}}"

        let events = try await collect(ChatHarness.shared.executeLoop(
            messages: [ChatMessage(role: .user, content: "Weather in SF?")],
            backend: ScriptedBackend(id: "small", events: [
                .token("{\"tool\": \"get_"),
                .token("weather\", \"argu"),
                .token("ments\": {\"location\": \"SF\"}}"),
                .turnCompleted(model: "small", finishReason: "stop")
            ]),
            capability: noNativeTools,
            tools: [weatherTool(executor)],
            maxToolTurns: 1
        ))

        #expect(executor.count == 1)
        #expect(text(events).isEmpty)
        #expect(!text(events).contains("\"tool\""))
        #expect(!(messages(events).first?.content.contains(call) ?? false))
        #expect(messages(events)[0].toolCalls?[0].name == "get_weather")
    }

    /// Holding every turn would cost live streaming on answers that are not calls.
    @Test func streamsPlainTextImmediatelyOnTheFallbackPath() async throws {
        let events = try await collect(ChatHarness.shared.executeLoop(
            messages: [ChatMessage(role: .user, content: "Hello")],
            backend: ScriptedBackend(id: "small", events: [
                .token("Hel"), .token("lo there."),
                .turnCompleted(model: "small", finishReason: "stop")
            ]),
            capability: noNativeTools,
            tools: [weatherTool(CountingExecutor())]
        ))

        #expect(text(events) == "Hello there.")
        #expect(messages(events)[0].content == "Hello there.")
    }

    @Test func reportsAnUnregisteredToolInsteadOfFailingTheTurn() async throws {
        let call = ToolCall(id: "c", name: "unknown_tool", arguments: "{}")
        let events = try await collect(ChatHarness.shared.executeLoop(
            messages: [ChatMessage(role: .user, content: "Go")],
            backend: ToolCallingBackend(id: "m", call: call),
            capability: nativeTools,
            tools: [weatherTool(CountingExecutor())]
        ))

        let result = try #require(messages(events).first { $0.role == .tool })
        #expect(result.content.contains("not registered"))
    }

    @Test func stopsAtTheToolTurnCeiling() async throws {
        // A backend that only ever calls tools would otherwise loop forever.
        let backend = ScriptedBackend(id: "looping", events: [
            .toolCall(ToolCall(id: "c", name: "get_weather", arguments: "{}")),
            .turnCompleted(model: "looping", finishReason: "tool_calls")
        ])
        let executor = CountingExecutor()

        let events = try await collect(ChatHarness.shared.executeLoop(
            messages: [ChatMessage(role: .user, content: "Go")],
            backend: backend,
            capability: nativeTools,
            tools: [weatherTool(executor)],
            maxToolTurns: 3
        ))

        #expect(executor.count == 3)
        #expect(events.last == .turnCompleted(model: "looping", finishReason: "max_tool_turns_reached"))
    }
}

// MARK: - Session and engine

struct ChatSessionTests {

    private func drain(_ stream: AsyncThrowingStream<ChatStreamEvent, Error>) async throws {
        for try await _ in stream {}
    }

    @Test func switchesModelsMidConversationAndAttributesEachTurn() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "sotto-chat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let session = ChatSession(slug: "switching", activeModelId: "apple-foundation", storageRoot: root)

        try await drain(await session.sendMessage(
            content: "First turn",
            backend: ScriptedBackend(id: "apple-foundation", text: "Hello from Apple Foundation")
        ))
        await session.switchModel(to: "mlx-qwen-7b")
        try await drain(await session.sendMessage(
            content: "Second turn",
            backend: ScriptedBackend(id: "mlx-qwen-7b", backendType: .mlx, text: "Hello from Qwen")
        ))

        let state = await session.state()
        #expect(state.models == ["apple-foundation", "mlx-qwen-7b"])
        #expect(state.messages.count == 4)
        #expect(state.messages[1].model == "apple-foundation")
        #expect(state.messages[1].content == "Hello from Apple Foundation")
        #expect(state.messages[3].model == "mlx-qwen-7b")

        let markdown = try String(contentsOf: root.appending(path: "switching/chat.md"), encoding: .utf8)
        #expect(markdown.contains("### Assistant (apple-foundation)"))
        #expect(markdown.contains("### Assistant (mlx-qwen-7b)"))

        // What was written is what reloads.
        let reloaded = try ChatSerializer.deserialize(markdown: markdown)
        #expect(reloaded.messages.map(\.content) == state.messages.map(\.content))
    }

    /// The flattening bug: the session recorded concatenated tokens, so calls and
    /// results — which never appear as tokens — never reached `chat.md` at all.
    @Test func persistsTheWholeToolCallAndResultHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "sotto-chat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        CapabilityRegistry.shared.register(
            modelId: "tool-model",
            capability: ModelCapability(vision: false, tools: true, maxContext: 4096, backendType: .openAI)
        )
        defer { CapabilityRegistry.shared.unregister(modelId: "tool-model") }

        let session = ChatSession(slug: "tools", activeModelId: "tool-model", storageRoot: root)
        await session.registerTool(
            ToolDefinition(name: "get_weather", description: "Weather"),
            executor: CountingExecutor()
        )

        try await drain(await session.sendMessage(
            content: "Weather in SF?",
            backend: ToolCallingBackend(id: "tool-model", call: ToolCall(id: "call_1", name: "get_weather", arguments: "{\"location\":\"SF\"}"))
        ))

        let state = await session.state()
        #expect(state.messages.map(\.role) == [.user, .assistant, .tool, .assistant])
        #expect(state.messages[1].toolCalls?[0].name == "get_weather")
        #expect(state.messages[2].content == "68F")

        let reloaded = try ChatSerializer.deserialize(
            markdown: try String(contentsOf: root.appending(path: "tools/chat.md"), encoding: .utf8)
        )
        #expect(reloaded.messages.map(\.role) == [.user, .assistant, .tool, .assistant])
        #expect(reloaded.messages[1].toolCalls?[0].arguments == "{\"location\":\"SF\"}")
        #expect(reloaded.messages[2].toolCallId == "call_1")
    }

    @Test func quotesASelectionIntoTheUserTurn() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "sotto-chat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let session = ChatSession(slug: "selection", storageRoot: root)
        try await drain(await session.sendMessage(
            content: "Explain this",
            selection: "let x = 1",
            backend: ScriptedBackend(id: "m", text: "It binds a constant.")
        ))

        let content = await session.state().messages[0].content
        #expect(content.contains("```selection\nlet x = 1\n```"))
        #expect(content.hasSuffix("Explain this"))
    }

    @Test func managesSessionLifecycleAndBackendRegistration() {
        let engine = ChatEngine()
        engine.registerBackend(ScriptedBackend(id: "custom-ollama", text: "hi"))

        #expect(engine.backend(for: "custom-ollama")?.backendType == .openAI)
        #expect(engine.backend(for: "apple-foundation") != nil)

        let id = UUID()
        #expect(engine.createSession(id: id, slug: "custom-session").slug == "custom-session")
        #expect(engine.session(for: id) != nil)
        engine.closeSession(id: id)
        #expect(engine.session(for: id) == nil)
    }
}

// MARK: - Apple backend translation

struct AppleFoundationTranslationTests {

    @Test func splitsTheLastUserMessageOutAsThePrompt() {
        let (history, prompt) = AppleFoundationBackend.split(messages: [
            ChatMessage(role: .user, content: "First"),
            ChatMessage(role: .assistant, content: "Answer", model: "m"),
            ChatMessage(role: .user, content: "Second")
        ])

        // The prompt must not also be in the transcript, or the model sees it twice.
        #expect(prompt == "Second")
        #expect(history.count == 2)
        #expect(history.last?.role == .assistant)
    }

    @Test func buildsATranscriptCarryingToolCallsAndOutputs() {
        let transcript = AppleFoundationBackend.transcript(
            systemPrompt: "Be brief.",
            tools: [],
            history: [
                ChatMessage(role: .user, content: "Weather?"),
                ChatMessage(role: .assistant, content: "", model: "m",
                            toolCalls: [ToolCall(id: "c1", name: "get_weather", arguments: "{\"location\":\"SF\"}")]),
                ChatMessage(role: .tool, content: "68F", toolCallId: "c1", toolName: "get_weather"),
                ChatMessage(role: .assistant, content: "68F.", model: "m")
            ]
        )

        let kinds = transcript.map { entry -> String in
            switch entry {
            case .instructions(_): return "instructions"
            case .prompt(_): return "prompt"
            case .toolCalls(_): return "toolCalls"
            case .toolOutput(_): return "toolOutput"
            case .response(_): return "response"
            @unknown default: return "?"
            }
        }
        #expect(kinds == ["instructions", "prompt", "toolCalls", "toolOutput", "response"])
    }

    @Test func convertsAJSONSchemaIntoAGenerationSchema() throws {
        // Building it at all is the test: `GenerationSchema` throws on a bad root,
        // and this is the shape every MCP tool arrives in.
        _ = try BridgedTool.schema(name: "get_weather", jsonSchema: """
        {"type":"object",
         "properties":{"location":{"type":"string","description":"City"},
                       "days":{"type":"integer"},
                       "units":{"type":"string","enum":["c","f"]},
                       "tags":{"type":"array","items":{"type":"string"}}},
         "required":["location"]}
        """)
        _ = try BridgedTool.schema(name: "no_args", jsonSchema: "{}")
    }
}

// MARK: - Chat library — pure ordering/search, plus the one disk-touching write

struct ChatLibraryTests {

    private func chat(_ title: String, updated: Date, pinned: Bool = false, body: String = "") -> ChatLibrary.Chat {
        let state = ChatSessionState(
            slug: title.lowercased(),
            title: title,
            updated: updated,
            pinned: pinned,
            messages: body.isEmpty ? [] : [ChatMessage(role: .user, content: body)]
        )
        return ChatLibrary.Chat(state: state, folder: URL(fileURLWithPath: "/tmp/\(title)"))
    }

    @Test func pinnedChatsSortBeforeUnpinnedRegardlessOfDate() {
        let old = chat("Old pinned", updated: Date(timeIntervalSince1970: 0), pinned: true)
        let new = chat("New", updated: Date(timeIntervalSince1970: 1000))
        let ordered = ChatLibrary.ordered([new, old], matching: "")
        #expect(ordered.map(\.title) == ["Old pinned", "New"])
    }

    @Test func withinTheSameTierNewestSortsFirst() {
        let earlier = chat("Earlier", updated: Date(timeIntervalSince1970: 0))
        let later = chat("Later", updated: Date(timeIntervalSince1970: 1000))
        let ordered = ChatLibrary.ordered([earlier, later], matching: "")
        #expect(ordered.map(\.title) == ["Later", "Earlier"])
    }

    @Test func searchMatchesTitleOrAnyMessageBody() {
        let byTitle = chat("Weekend plans", updated: Date())
        let byBody = chat("Untitled", updated: Date(), body: "let's talk about kayaking")
        let neither = chat("Taxes", updated: Date(), body: "receipts")

        let matched = ChatLibrary.ordered([byTitle, byBody, neither], matching: "kayak")
        #expect(Set(matched.map(\.title)) == ["Untitled"])

        let matchedTitle = ChatLibrary.ordered([byTitle, byBody, neither], matching: "weekend")
        #expect(Set(matchedTitle.map(\.title)) == ["Weekend plans"])
    }

    @MainActor
    @Test func deleteRemovesTheFolderAndClearsAMatchingSelection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sotto-chatlib-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let state = ChatSessionState(slug: "to-delete", messages: [ChatMessage(role: .user, content: "hi")])
        let folder = try ChatFolder.write(slug: "to-delete", markdown: ChatSerializer.serialize(state: state), to: root)
        let chat = ChatLibrary.Chat(state: state, folder: folder)

        let library = ChatLibrary.shared
        library.selection = chat.id
        library.delete(chat)

        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(library.selection == nil)
    }
}

// MARK: - Chat conversation — hydration, streamed attribution, cancellation

/// Yields tokens with a delay between each, so a test can cancel mid-stream and
/// observe what survives — `ScriptedBackend` finishes before a cancel could ever
/// land.
private struct SlowScriptedBackend: ChatBackend {
    let id: String
    let backendType: BackendType = .openAI
    let tokens: [String]
    let delayNanoseconds: UInt64

    func generateStream(
        messages: [ChatMessage],
        tools: [ChatTool],
        systemPrompt: String?
    ) async throws -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let tokens = self.tokens
        let delay = self.delayNanoseconds
        let id = self.id
        return AsyncThrowingStream(ChatStreamEvent.self) { continuation in
            let task = Task {
                for token in tokens {
                    try Task.checkCancellation()
                    try await Task.sleep(nanoseconds: delay)
                    continuation.yield(.token(token))
                }
                continuation.yield(.turnCompleted(model: id, finishReason: "stop"))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@MainActor
@Suite(.serialized)
struct ChatConversationTests {

    /// `commitAndGenerate` and `stop()` both spawn work on `Task`s the test has
    /// no handle to — poll rather than assume a fixed delay finishes it.
    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func withScratchRoot(_ body: () async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sotto-chatconv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        ChatFolder.rootForTesting = root
        defer {
            ChatFolder.rootForTesting = nil
            try? FileManager.default.removeItem(at: root)
        }
        try await body()
    }

    @Test func hydratesAnOldChatAndAppendsTheContinuation() async throws {
        try await withScratchRoot {
            let backend = ScriptedBackend(id: "hydrate-model", text: "Still here.")
            ChatEngine.shared.registerBackend(backend)

            let existing = ChatSessionState(
                slug: "already-going",
                messages: [
                    ChatMessage(role: .user, content: "First question", model: "hydrate-model"),
                    ChatMessage(role: .assistant, content: "First answer", model: "hydrate-model")
                ]
            )
            _ = try ChatFolder.write(
                slug: existing.slug, markdown: ChatSerializer.serialize(state: existing), to: ChatFolder.root
            )

            let conversation = ChatConversations.shared.open(ChatLibrary.Chat(
                state: existing, folder: ChatFolder.root.appendingPathComponent(existing.slug)
            ))
            defer { ChatConversations.shared.discard(conversation.id) }

            #expect(conversation.turns.count == 2)
            conversation.commitAndGenerate(content: "Second question", images: [:], modelID: "hydrate-model")
            await waitUntil { !conversation.isGenerating }

            #expect(conversation.turns.count == 4)
            #expect(conversation.turns.last?.text == "Still here.")
        }
    }

    @Test func sendAttributesTheStreamedReplyToItsModel() async throws {
        try await withScratchRoot {
            let backend = ScriptedBackend(id: "attributed-model", text: "The answer.")
            ChatEngine.shared.registerBackend(backend)

            let conversation = ChatConversations.shared.beginNew()
            defer { ChatConversations.shared.discard(conversation.id) }

            conversation.commitAndGenerate(content: "A question", images: [:], modelID: "attributed-model")
            await waitUntil { !conversation.isGenerating }

            let reply = try #require(conversation.turns.last)
            #expect(reply.text == "The answer.")
            #expect(reply.model == "attributed-model")
        }
    }

    @Test func cancelKeepsThePartialTextAndCommitsNoAssistantTurn() async throws {
        try await withScratchRoot {
            let backend = SlowScriptedBackend(
                id: "slow-model", tokens: ["One ", "Two ", "Three "], delayNanoseconds: 100_000_000
            )
            ChatEngine.shared.registerBackend(backend)

            let conversation = ChatConversations.shared.beginNew()
            defer { ChatConversations.shared.discard(conversation.id) }

            conversation.commitAndGenerate(content: "Count for me", images: [:], modelID: "slow-model")
            await waitUntil(timeout: 1) { !conversation.streamingText.isEmpty }
            #expect(!conversation.streamingText.isEmpty)

            conversation.stop()
            await waitUntil { !conversation.isGenerating }

            #expect(!conversation.streamingText.isEmpty)
            #expect(!conversation.turns.contains { !$0.isUser })
        }
    }
}

// MARK: - ConversationTurn parsing

/// `ConversationTurn.from` is the read side of the chat file format — the exact
/// inverse of `Draft.serializedContent()`. Slice 10 renders both the window and
/// the docked panel through it, so drift between the writer and this parser
/// drops a quoted selection or an attached image with no error anywhere.
@MainActor
struct ConversationTurnParseTests {
    @Test func splitsAUserMessageBackIntoSourcesImagesAndText() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let draft = Draft(text: "what changed here?", attachments: [
            .selection(id: UUID(), app: "Xcode", text: "let x = 1"),
            .image(id: UUID(), filename: "shot.png", data: png),
        ])
        let message = ChatMessage(role: .user, content: draft.serializedContent())

        let turn = try #require(ConversationTurn.from(message))
        #expect(turn.isUser)
        #expect(turn.sources.count == 1)
        #expect(turn.sources.first?.app == "Xcode")
        #expect(turn.sources.first?.text == "let x = 1")
        #expect(turn.images == ["shot.png"])
        #expect(turn.text == "what changed here?")
    }

    @Test func returnsNilForASystemMessage() {
        let message = ChatMessage(role: .system, content: "You are a helpful assistant.")
        #expect(ConversationTurn.from(message) == nil)
    }
}
