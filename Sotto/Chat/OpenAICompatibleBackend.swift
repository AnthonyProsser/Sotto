import Foundation
import os

/// Discovered or configured local server endpoint.
public nonisolated struct LocalServerEndpoint: Sendable, Codable, Equatable {
    public let name: String
    public let baseURL: URL
    public let defaultPort: Int

    public init(name: String, baseURL: URL, defaultPort: Int) {
        self.name = name
        self.baseURL = baseURL
        self.defaultPort = defaultPort
    }

    public static let ollama = LocalServerEndpoint(
        name: "Ollama",
        baseURL: URL(string: "http://localhost:11434")!,
        defaultPort: 11434
    )

    public static let llamaServer = LocalServerEndpoint(
        name: "llama-server",
        baseURL: URL(string: "http://localhost:8080")!,
        defaultPort: 8080
    )

    public static let lmStudio = LocalServerEndpoint(
        name: "LM Studio",
        baseURL: URL(string: "http://localhost:1234")!,
        defaultPort: 1234
    )
}

/// OpenAI-compatible streaming HTTP adapter for Ollama, llama-server, LM Studio, or custom endpoints.
public nonisolated final class OpenAICompatibleBackend: ChatBackend, @unchecked Sendable {
    public let id: String
    public let baseURL: URL
    public let backendType: BackendType = .openAI

    private let log = Logger(subsystem: "com.anthonyprosser.Sotto", category: "openai-backend")
    private let urlSession: URLSession

    public init(
        id: String,
        baseURL: URL = URL(string: "http://localhost:11434")!,
        urlSession: URLSession = .shared
    ) {
        self.id = id
        self.baseURL = baseURL
        self.urlSession = urlSession
    }

    /// Autodetect active local servers by checking standard health/version endpoints.
    public static func detectLocalServers(session: URLSession = .shared) async -> [LocalServerEndpoint] {
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

    public func generateStream(
        messages: [ChatMessage],
        tools: [ToolDefinition] = [],
        systemPrompt: String? = nil
    ) async throws -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let endpointURL = baseURL.appendingPathComponent("v1/chat/completions")
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        // Build messages payload
        var formattedMessages: [[String: Any]] = []
        if let sys = systemPrompt, !sys.isEmpty {
            formattedMessages.append(["role": "system", "content": sys])
        }

        for msg in messages {
            var m: [String: Any] = [
                "role": msg.role.rawValue,
                "content": msg.content
            ]
            if let calls = msg.toolCalls, !calls.isEmpty {
                m["tool_calls"] = calls.map { call in
                    [
                        "id": call.id,
                        "type": "function",
                        "function": [
                            "name": call.name,
                            "arguments": call.arguments
                        ]
                    ]
                }
            }
            if let callId = msg.toolCallId {
                m["tool_call_id"] = callId
            }
            formattedMessages.append(m)
        }

        var body: [String: Any] = [
            "model": self.id,
            "messages": formattedMessages,
            "stream": true
        ]

        if !tools.isEmpty {
            body["tools"] = tools.map { tool in
                let schemaObj = (try? JSONSerialization.jsonObject(with: Data(tool.parametersJSONSchema.utf8))) ?? [:]
                return [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": schemaObj
                    ]
                ]
            }
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let modelId = self.id
        let session = self.urlSession

        return AsyncThrowingStream(ChatStreamEvent.self) { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw ChatBackendError.invalidResponse("Missing HTTPURLResponse")
                    }

                    guard (200...299).contains(httpResponse.statusCode) else {
                        throw ChatBackendError.connectionFailed("Server returned HTTP \(httpResponse.statusCode)")
                    }

                    var accumulatedToolCalls: [Int: (id: String, name: String, args: String)] = [:]

                    for try await line in bytes.lines {
                        try Task.checkCancellation()

                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { continue }
                        guard trimmed.hasPrefix("data:") else { continue }

                        let dataContent = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if dataContent == "[DONE]" {
                            // Flush any tool calls
                            for (_, call) in accumulatedToolCalls {
                                continuation.yield(.toolCall(ToolCall(id: call.id, name: call.name, arguments: call.args)))
                            }
                            accumulatedToolCalls.removeAll()

                            continuation.yield(.turnCompleted(model: modelId, finishReason: "stop"))
                            continuation.finish()
                            return
                        }

                        guard let data = dataContent.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = json["choices"] as? [[String: Any]],
                              let firstChoice = choices.first else {
                            continue
                        }

                        if let delta = firstChoice["delta"] as? [String: Any] {
                            if let content = delta["content"] as? String, !content.isEmpty {
                                continuation.yield(.token(content))
                            }

                            if let rawToolCalls = delta["tool_calls"] as? [[String: Any]] {
                                for tc in rawToolCalls {
                                    let index = tc["index"] as? Int ?? 0
                                    let id = tc["id"] as? String
                                    let fn = tc["function"] as? [String: Any]
                                    let name = fn?["name"] as? String
                                    let args = fn?["arguments"] as? String ?? ""

                                    var current = accumulatedToolCalls[index] ?? (id: id ?? UUID().uuidString, name: name ?? "", args: "")
                                    if let newId = id { current.id = newId }
                                    if let newName = name { current.name = newName }
                                    current.args += args
                                    accumulatedToolCalls[index] = current
                                }
                            }
                        }

                        if let finishReason = firstChoice["finish_reason"] as? String, !finishReason.isEmpty {
                            for (_, call) in accumulatedToolCalls {
                                continuation.yield(.toolCall(ToolCall(id: call.id, name: call.name, arguments: call.args)))
                            }
                            accumulatedToolCalls.removeAll()

                            continuation.yield(.turnCompleted(model: modelId, finishReason: finishReason))
                            continuation.finish()
                            return
                        }
                    }

                    // End of stream
                    for (_, call) in accumulatedToolCalls {
                        continuation.yield(.toolCall(ToolCall(id: call.id, name: call.name, arguments: call.args)))
                    }
                    continuation.yield(.turnCompleted(model: modelId, finishReason: "stop"))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: ChatBackendError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}
