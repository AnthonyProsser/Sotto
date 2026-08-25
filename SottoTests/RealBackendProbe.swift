// Temporary probe — not part of the suite. Deleted after the run.
import Testing
import Foundation
@testable import Sotto

private func report(_ line: String) {
    let url = URL(fileURLWithPath: "/tmp/probe_out.txt")
    let text = line + "\n"
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(Data(text.utf8))
        try? handle.close()
    } else {
        try? Data(text.utf8).write(to: url)
    }
}

private struct EchoExecutor: ChatToolExecutor {
    func execute(call: ToolCall) async throws -> String {
        report("    tool called: \(call.name)(\(call.arguments))")
        return "18 degrees and raining"
    }
}

private let weather = ChatTool(
    definition: ToolDefinition(
        name: "get_weather",
        description: "Get the current weather for a city.",
        parametersJSONSchema: "{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\",\"description\":\"City name\"}},\"required\":[\"city\"]}"
    ),
    executor: EchoExecutor()
)

struct RealBackendProbe {

    @Test func probeMLX() async throws {
        let models = ModelStore.discover()
        report("=== MLX ===")
        report("models on disk: \(models.map(\.id))")
        guard !models.isEmpty else { report("NO MODELS"); return }

        for model in models {
            let estimate = model.memoryEstimate(contextLength: 4096)
            report("""
              \(model.id): weights \(estimate.weightsBytes / 1_048_576) MB, \
            KV \(estimate.kvCacheBytes / 1_048_576) MB, total \(estimate.totalBytes / 1_048_576) MB, \
            \(String(format: "%.1f", estimate.percentageOfRAM * 100))% of RAM, amber=\(estimate.isAmber), \
            tools=\(model.capability.tools), vision=\(model.capability.vision), ctx=\(model.capability.maxContext)
            """)
        }

        // Generate on each model in turn — the switch is what exercises unload.
        for model in models {
            let backend = MLXBackend(model: model)
            let started = Date()
            var text = ""
            var calls: [ToolCall] = []

            let stream = ChatHarness.shared.executeLoop(
                messages: [ChatMessage(role: .user, content: "Name three colours. Answer in one short sentence.")],
                backend: backend,
                capability: model.capability,
                tools: []
            )
            for try await event in stream {
                switch event {
                case .token(let t): text += t
                case .toolCall(let c): calls.append(c)
                default: break
                }
            }

            let elapsed = Date().timeIntervalSince(started)
            report("  \(model.id) → \(String(format: "%.1f", elapsed))s, \(text.count) chars")
            report("    \(text.prefix(200).replacingOccurrences(of: "\n", with: " ⏎ "))")
            report("    resident after turn: \(await MLXRuntime.shared.loadedModelID ?? "none")")
        }

        // Multi-turn on the last model, plus a tool call through whichever path
        // its capability selects.
        if let model = models.last {
            let backend = MLXBackend(model: model)
            var history: [ChatMessage] = [
                ChatMessage(role: .user, content: "My name is Anthony."),
                ChatMessage(role: .assistant, content: "Nice to meet you, Anthony.", model: model.id),
                ChatMessage(role: .user, content: "What is my name? Answer with just the name.")
            ]
            var text = ""
            for try await event in ChatHarness.shared.executeLoop(
                messages: history, backend: backend, capability: model.capability, tools: []
            ) {
                if case .token(let t) = event { text += t }
            }
            report("  multi-turn recall (\(model.id)): \(text.prefix(120).replacingOccurrences(of: "\n", with: " ⏎ "))")

            history = [ChatMessage(role: .user, content: "What is the weather in Bristol? Use the tool.")]
            var recorded: [ChatMessage] = []
            for try await event in ChatHarness.shared.executeLoop(
                messages: history, backend: backend, capability: model.capability, tools: [weather], maxToolTurns: 3
            ) {
                if case .message(let m) = event { recorded.append(m) }
            }
            report("  tool path (\(model.capability.tools ? "native" : "fallback")) recorded roles: \(recorded.map { $0.role.rawValue })")
            for m in recorded {
                report("    \(m.role.rawValue): calls=\(m.toolCalls?.map(\.name) ?? []) content=\(m.content.prefix(120).replacingOccurrences(of: "\n", with: " ⏎ "))")
            }
        }

        await MLXRuntime.shared.unload()
        report("  after unload: \(await MLXRuntime.shared.loadedModelID ?? "none")")
    }

    @Test func probeApple() async throws {
        report("=== Apple Foundation ===")
        let backend = AppleFoundationBackend()
        report("available: \(backend.isAvailable)")
        guard backend.isAvailable else { return }

        let capability = CapabilityRegistry.appleFoundationDefault

        var text = ""
        var chunks = 0
        for try await event in ChatHarness.shared.executeLoop(
            messages: [ChatMessage(role: .user, content: "Name three colours. Answer in one short sentence.")],
            backend: backend, capability: capability, tools: []
        ) {
            if case .token(let t) = event { text += t; chunks += 1 }
        }
        report("  plain: \(chunks) chunks — \(text.prefix(200).replacingOccurrences(of: "\n", with: " ⏎ "))")

        // Multi-turn, carried by the Transcript rather than a flattened prompt.
        var recall = ""
        for try await event in ChatHarness.shared.executeLoop(
            messages: [
                ChatMessage(role: .user, content: "My name is Anthony."),
                ChatMessage(role: .assistant, content: "Nice to meet you, Anthony.", model: backend.id),
                ChatMessage(role: .user, content: "What is my name? Answer with just the name.")
            ],
            backend: backend, capability: capability, tools: []
        ) {
            if case .token(let t) = event { recall += t }
        }
        report("  multi-turn recall: \(recall.prefix(120).replacingOccurrences(of: "\n", with: " ⏎ "))")

        // Native tools: the session calls the tool itself and the record comes
        // back out of its transcript.
        var recorded: [ChatMessage] = []
        for try await event in ChatHarness.shared.executeLoop(
            messages: [ChatMessage(role: .user, content: "What is the weather in Bristol?")],
            backend: backend, capability: capability, tools: [weather]
        ) {
            if case .message(let m) = event { recorded.append(m) }
        }
        report("  native tools recorded roles: \(recorded.map { $0.role.rawValue })")
        for m in recorded {
            report("    \(m.role.rawValue): calls=\(m.toolCalls?.map { "\($0.name)\($0.arguments)" } ?? []) content=\(m.content.prefix(160).replacingOccurrences(of: "\n", with: " ⏎ "))")
        }
    }

    @Test func probeOpenAI() async throws {
        report("=== OpenAI-compatible ===")
        let servers = await OpenAICompatibleBackend.detectLocalServers()
        report("detected: \(servers.map(\.name))")
        guard let server = servers.first else { report("  none running — skipped"); return }

        // Ask the server what it has.
        let listURL = server.baseURL.appending(path: "v1/models")
        guard let (data, _) = try? await URLSession.shared.data(from: listURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (json["data"] as? [[String: Any]])?.first?["id"] as? String else {
            report("  could not list models")
            return
        }
        report("  model: \(first)")

        let backend = OpenAICompatibleBackend(id: first, baseURL: server.baseURL)
        var text = ""
        for try await event in ChatHarness.shared.executeLoop(
            messages: [ChatMessage(role: .user, content: "Name three colours. One short sentence.")],
            backend: backend,
            capability: ModelCapability(vision: false, tools: false, maxContext: 4096, backendType: .openAI),
            tools: []
        ) {
            if case .token(let t) = event { text += t }
        }
        report("  \(text.prefix(200).replacingOccurrences(of: "\n", with: " ⏎ "))")
    }
}
