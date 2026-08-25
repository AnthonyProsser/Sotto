import Foundation
import os

/// Discovered or configured local server endpoint.
nonisolated struct LocalServerEndpoint: Sendable, Codable, Equatable {
    let name: String
    let baseURL: URL
    let defaultPort: Int

    init(name: String, baseURL: URL, defaultPort: Int) {
        self.name = name
        self.baseURL = baseURL
        self.defaultPort = defaultPort
    }

    static let ollama = LocalServerEndpoint(
        name: "Ollama",
        baseURL: URL(string: "http://localhost:11434")!,
        defaultPort: 11434
    )

    static let llamaServer = LocalServerEndpoint(
        name: "llama-server",
        baseURL: URL(string: "http://localhost:8080")!,
        defaultPort: 8080
    )

    static let lmStudio = LocalServerEndpoint(
        name: "LM Studio",
        baseURL: URL(string: "http://localhost:1234")!,
        defaultPort: 1234
    )
}

/// Turns an OpenAI-compatible SSE body into stream events, one line at a time.
///
/// Separate from the backend because it is the part that is actually easy to get
/// wrong — chunked tool-call arguments, `[DONE]`, `finish_reason` arriving in its
/// own frame — and the part a test can drive without a server.
nonisolated struct OpenAIStreamDecoder {
    enum Event: Sendable, Equatable {
        case token(String)
        case toolCall(ToolCall)
        case finished(reason: String?)
    }

    /// Arguments arrive as string fragments across frames and are only valid concatenated.
    private struct Partial {
        var id: String
        var name: String
        var arguments: String
    }

    private var partials: [Int: Partial] = [:]
    private var isFinished = false

    /// Events produced by one line of the response body.
    mutating func decode(line: String) -> [Event] {
        guard !isFinished else { return [] }

        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else { return [] }

        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" {
            return finish(reason: "stop")
        }

        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (json["choices"] as? [[String: Any]])?.first else {
            return []
        }

        var events: [Event] = []

        if let delta = choice["delta"] as? [String: Any] {
            if let content = delta["content"] as? String, !content.isEmpty {
                events.append(.token(content))
            }

            for fragment in delta["tool_calls"] as? [[String: Any]] ?? [] {
                let index = fragment["index"] as? Int ?? 0
                let function = fragment["function"] as? [String: Any]
                var partial = partials[index] ?? Partial(id: UUID().uuidString, name: "", arguments: "")
                if let id = fragment["id"] as? String, !id.isEmpty { partial.id = id }
                if let name = function?["name"] as? String, !name.isEmpty { partial.name = name }
                partial.arguments += function?["arguments"] as? String ?? ""
                partials[index] = partial
            }
        }

        if let reason = choice["finish_reason"] as? String, !reason.isEmpty {
            return events + finish(reason: reason)
        }

        return events
    }

    /// Flushes at end of body, for a server that closes without `[DONE]`.
    mutating func finish(reason: String? = "stop") -> [Event] {
        guard !isFinished else { return [] }
        isFinished = true

        // Sorted by index: a dictionary's order is not the order the model asked
        // for the calls in, and multi-call turns are dispatched in this order.
        let calls = partials.keys.sorted().compactMap { index -> Event? in
            guard let partial = partials[index], !partial.name.isEmpty else { return nil }
            return .toolCall(ToolCall(
                id: partial.id,
                name: partial.name,
                arguments: partial.arguments.isEmpty ? "{}" : partial.arguments
            ))
        }
        partials.removeAll()
        return calls + [.finished(reason: reason)]
    }
}

/// OpenAI-compatible streaming HTTP adapter for Ollama, llama-server, LM Studio,
/// or a custom endpoint (§2.2).
///
/// Outbound, and allowed to be: the user configured this server. Principle 1 is a
/// consent rule, and a backend the user pointed at a port passes it.
nonisolated final class OpenAICompatibleBackend: ChatBackend, @unchecked Sendable {
    let id: String
    let baseURL: URL
    let backendType: BackendType = .openAI

    private let log = Logger(subsystem: "com.anthonyprosser.Sotto", category: "openai-backend")
    private let urlSession: URLSession

    init(
        id: String,
        baseURL: URL = URL(string: "http://localhost:11434")!,
        urlSession: URLSession = .shared
    ) {
        self.id = id
        self.baseURL = baseURL
        self.urlSession = urlSession
    }

    /// The completions endpoint for a base URL the user may have typed either way.
    /// LM Studio's own UI shows `http://localhost:1234/v1`, so appending `v1`
    /// unconditionally produces `/v1/v1/chat/completions` and a 404 that reads as
    /// "the server is down."
    static func completionsURL(base: URL) -> URL {
        let path = base.path.hasSuffix("/") ? String(base.path.dropLast()) : base.path
        return base.appending(path: path.hasSuffix("/v1") ? "chat/completions" : "v1/chat/completions")
    }

    /// Autodetect active local servers by checking standard health/version endpoints.
    static func detectLocalServers(session: URLSession = .shared) async -> [LocalServerEndpoint] {
        let candidates: [(LocalServerEndpoint, String)] = [
            (.ollama, "http://localhost:11434/api/tags"),
            (.llamaServer, "http://localhost:8080/health"),
            (.lmStudio, "http://localhost:1234/v1/models")
        ]

        var active: [LocalServerEndpoint] = []
        for (endpoint, probeURLString) in candidates {
            guard let url = URL(string: probeURLString) else { continue }
            var req = URLRequest(url: url)
            req.timeoutInterval = 0.5
            req.httpMethod = "GET"
            do {
                let (_, response) = try await session.data(for: req)
                if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                    active.append(endpoint)
                }
            } catch {
                // Server not reachable
            }
        }
        return active
    }

    /// The request body, built separately so a test can read it without a server.
    static func requestBody(
        model: String,
        messages: [ChatMessage],
        tools: [ChatTool],
        systemPrompt: String?
    ) -> [String: Any] {
        var formatted: [[String: Any]] = []
        if let systemPrompt, !systemPrompt.isEmpty {
            formatted.append(["role": "system", "content": systemPrompt])
        }

        for message in messages {
            var entry: [String: Any] = [
                "role": message.role.rawValue,
                "content": message.content
            ]
            if let calls = message.toolCalls, !calls.isEmpty {
                entry["tool_calls"] = calls.map { call in
                    [
                        "id": call.id,
                        "type": "function",
                        "function": ["name": call.name, "arguments": call.arguments]
                    ] as [String: Any]
                }
            }
            if let callId = message.toolCallId {
                entry["tool_call_id"] = callId
            }
            if let toolName = message.toolName {
                entry["name"] = toolName
            }
            formatted.append(entry)
        }

        var body: [String: Any] = [
            "model": model,
            "messages": formatted,
            "stream": true
        ]

        if !tools.isEmpty {
            body["tools"] = tools.map { tool in
                let schema = (try? JSONSerialization.jsonObject(with: Data(tool.definition.parametersJSONSchema.utf8))) ?? [:]
                return [
                    "type": "function",
                    "function": [
                        "name": tool.definition.name,
                        "description": tool.definition.description,
                        "parameters": schema
                    ]
                ] as [String: Any]
            }
        }

        return body
    }

    func generateStream(
        messages: [ChatMessage],
        tools: [ChatTool],
        systemPrompt: String?
    ) async throws -> AsyncThrowingStream<ChatStreamEvent, Error> {
        var request = URLRequest(url: Self.completionsURL(base: baseURL))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: Self.requestBody(
                model: id,
                messages: messages,
                tools: tools,
                systemPrompt: systemPrompt
            )
        )

        let modelId = self.id
        let session = self.urlSession

        return AsyncThrowingStream(ChatStreamEvent.self) { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)

                    guard let http = response as? HTTPURLResponse else {
                        throw ChatBackendError.invalidResponse("Missing HTTPURLResponse")
                    }
                    guard (200...299).contains(http.statusCode) else {
                        throw ChatBackendError.connectionFailed("Server returned HTTP \(http.statusCode)")
                    }

                    var decoder = OpenAIStreamDecoder()

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        if Self.emit(decoder.decode(line: line), model: modelId, to: continuation) {
                            continuation.finish()
                            return
                        }
                    }

                    _ = Self.emit(decoder.finish(), model: modelId, to: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: ChatBackendError.cancelled)
                } catch let error as ChatBackendError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: ChatBackendError.connectionFailed(error.localizedDescription))
                }
            }

            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// Returns true when the turn ended.
    private static func emit(
        _ events: [OpenAIStreamDecoder.Event],
        model: String,
        to continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation
    ) -> Bool {
        var ended = false
        for event in events {
            switch event {
            case .token(let text):
                continuation.yield(.token(text))
            case .toolCall(let call):
                continuation.yield(.toolCall(call))
            case .finished(let reason):
                continuation.yield(.turnCompleted(model: model, finishReason: reason))
                ended = true
            }
        }
        return ended
    }
}
