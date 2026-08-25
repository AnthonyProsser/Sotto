import Foundation
import os
import MLX
import MLXLLM
import MLXLMCommon

/// The one resident MLX model.
///
/// **One at a time, and the old one is released before the new one is read.**
/// A 3B 4-bit model is ~1.7 GB of weights; the reference machine has 8 GB, so
/// two resident models is most of it. Loading the second before dropping the
/// first would peak at the sum, which is the one moment the estimate in §2.3
/// cannot warn about because it describes a single model. Switching therefore
/// unloads, clears MLX's buffer cache, and only then loads.
///
/// This is not a cache. A user switching back and forth pays the load each time,
/// which is the correct trade on a machine where the alternative is swapping.
actor MLXRuntime {
    static let shared = MLXRuntime()

    private var residentID: String?
    private var resident: ModelContainer?
    private let log = Logger(subsystem: "com.anthonyprosser.Sotto", category: "mlx-runtime")

    /// The container for `model`, loading it — and unloading whatever else was
    /// resident — if it is not already the one in memory.
    func container(for model: LocalModel) async throws -> ModelContainer {
        if residentID == model.id, let resident {
            return resident
        }

        unload()

        await MainActor.run { Activity.shared.set(.modelLoading, true) }
        defer { Task { @MainActor in Activity.shared.set(.modelLoading, false) } }

        // `.directory` short-circuits the Hub entirely (`Load.swift`), so this
        // call cannot reach the network. Principle 1 is satisfied structurally
        // here rather than by intention: there is no path from a chat turn to a
        // download, because acquisition is a separate act in a separate slice.
        let configuration = ModelConfiguration(directory: model.directory)

        let started = Date()
        let container: ModelContainer
        do {
            container = try await LLMModelFactory.shared.loadContainer(configuration: configuration)
        } catch {
            log.error("MLX load failed for \(model.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw ChatBackendError.modelLoadFailed("\(model.id): \(error.localizedDescription)")
        }

        residentID = model.id
        resident = container
        log.notice("Loaded \(model.id, privacy: .public) in \(Date().timeIntervalSince(started), format: .fixed(precision: 2))s")
        return container
    }

    /// Drops the resident model and returns its buffers to the system.
    ///
    /// `GPU.clearCache()` matters because MLX keeps freed Metal buffers pooled for
    /// reuse; without it the weights are unreferenced but the memory is still
    /// held, and the next model loads on top of a pool sized for the last one.
    func unload() {
        guard resident != nil else { return }
        log.notice("Unloading \(self.residentID ?? "?", privacy: .public)")
        resident = nil
        residentID = nil
        MLX.GPU.clearCache()
    }

    /// The model currently in memory, if any.
    var loadedModelID: String? { residentID }
}

/// Embedded on-device MLX inference for Apple silicon (§2.2).
///
/// One backend instance per model. Everything about residency is `MLXRuntime`'s,
/// so a second backend for a second model is cheap to make and does not imply a
/// second model in memory.
nonisolated final class MLXBackend: ChatBackend, @unchecked Sendable {
    let model: LocalModel
    let backendType: BackendType = .mlx
    let parameters: GenerateParameters

    var id: String { model.id }

    private let log = Logger(subsystem: "com.anthonyprosser.Sotto", category: "mlx-backend")

    init(model: LocalModel, parameters: GenerateParameters = GenerateParameters()) {
        self.model = model
        self.parameters = parameters
    }

    /// Convenience for a model directory that has not been read yet.
    convenience init(directory: URL, parameters: GenerateParameters = GenerateParameters()) throws {
        self.init(model: try ModelStore.model(at: directory), parameters: parameters)
    }

    func generateStream(
        messages: [ChatMessage],
        tools: [ChatTool],
        systemPrompt: String?
    ) async throws -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let model = self.model
        let modelId = self.id
        let parameters = self.parameters
        let chat = Self.chat(from: messages, systemPrompt: systemPrompt)
        let specs = tools.compactMap { Self.toolSpec(for: $0.definition) }

        return AsyncThrowingStream(ChatStreamEvent.self) { continuation in
            let task = Task {
                do {
                    let container = try await MLXRuntime.shared.container(for: model)

                    try await container.perform { context in
                        let input = try await context.processor.prepare(
                            input: UserInput(chat: chat, tools: specs.isEmpty ? nil : specs)
                        )

                        for await item in try MLXLMCommon.generate(
                            input: input,
                            parameters: parameters,
                            context: context
                        ) {
                            try Task.checkCancellation()
                            switch item {
                            case .chunk(let text):
                                continuation.yield(.token(text))
                            case .toolCall(let call):
                                continuation.yield(.toolCall(Self.toolCall(from: call)))
                            case .info:
                                break
                            }
                        }
                    }

                    try Task.checkCancellation()
                    continuation.yield(.turnCompleted(model: modelId, finishReason: "stop"))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: ChatBackendError.cancelled)
                } catch let error as ChatBackendError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: ChatBackendError.invalidResponse(error.localizedDescription))
                }
            }

            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    // MARK: - Translation

    /// Sotto's history in the form the model's own chat template renders.
    static func chat(from messages: [ChatMessage], systemPrompt: String?) -> [Chat.Message] {
        var chat: [Chat.Message] = []
        if let systemPrompt, !systemPrompt.isEmpty {
            chat.append(.system(systemPrompt))
        }

        for message in messages {
            switch message.role {
            case .system:
                chat.append(.system(message.content))
            case .user:
                chat.append(.user(message.content))
            case .tool:
                chat.append(.tool(message.content))
            case .assistant:
                // `Chat.Message` carries role and content only, so a past tool
                // call has to travel as text. `<tool_call>` is the form
                // `ToolCallProcessor` just parsed it *out* of, so putting it
                // back is replaying what the model itself emitted rather than
                // inventing a notation for it.
                var content = message.content
                for call in message.toolCalls ?? [] {
                    content += "<tool_call>{\"name\": \"\(call.name)\", \"arguments\": \(call.arguments)}</tool_call>"
                }
                chat.append(.assistant(content))
            }
        }
        return chat
    }

    /// A tool definition as the OpenAI function schema every chat template expects.
    /// Returns nil for a schema that is not a JSON object — a malformed tool is
    /// dropped rather than sent as something the template will render as garbage.
    static func toolSpec(for definition: ToolDefinition) -> [String: Any]? {
        guard let data = definition.parametersJSONSchema.data(using: .utf8),
              let parameters = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return [
            "type": "function",
            "function": [
                "name": definition.name,
                "description": definition.description,
                "parameters": parameters
            ] as [String: Any]
        ]
    }

    static func toolCall(from call: MLXLMCommon.ToolCall) -> ToolCall {
        let arguments = call.function.arguments.mapValues(\.anyValue)
        let data = (try? JSONSerialization.data(withJSONObject: arguments)) ?? Data("{}".utf8)
        return ToolCall(
            name: call.function.name,
            arguments: String(data: data, encoding: .utf8) ?? "{}"
        )
    }
}
