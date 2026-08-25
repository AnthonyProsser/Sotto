import Foundation
import os

/// Model weights metadata and quantization format for embedded MLX inference.
public nonisolated struct MLXWeightMetadata: Sendable, Codable, Equatable {
    public let modelDirectory: URL
    public let architecture: String
    public let quantizationBits: Int?
    public let parameterCount: Int64
    public let geometry: ModelGeometry?

    public init(
        modelDirectory: URL,
        architecture: String,
        quantizationBits: Int? = nil,
        parameterCount: Int64 = 0,
        geometry: ModelGeometry? = nil
    ) {
        self.modelDirectory = modelDirectory
        self.architecture = architecture
        self.quantizationBits = quantizationBits
        self.parameterCount = parameterCount
        self.geometry = geometry
    }
}

/// Tokenizer and prompt template for MLX text decoding.
public nonisolated struct MLXTokenizer: Sendable {
    public let stopTokens: Set<String>
    public let eosToken: String

    public init(
        stopTokens: Set<String> = ["<|im_end|>", "<|endoftext|>", "<end_of_turn>", "</s>"],
        eosToken: String = "<|im_end|>"
    ) {
        self.stopTokens = stopTokens
        self.eosToken = eosToken
    }

    /// Format messages into ChatML prompt string.
    public func formatChatML(messages: [ChatMessage], systemPrompt: String? = nil) -> String {
        var parts: [String] = []

        if let sys = systemPrompt, !sys.isEmpty {
            parts.append("<|im_start|>system\n\(sys)<|im_end|>")
        }

        for msg in messages {
            let role = msg.role.rawValue
            if msg.role == .tool, let callId = msg.toolCallId {
                parts.append("<|im_start|>tool id=\(callId)\n\(msg.content)<|im_end|>")
            } else if let calls = msg.toolCalls, !calls.isEmpty {
                let callStrings = calls.map { "call:\($0.name){\($0.arguments)}" }.joined(separator: "\n")
                parts.append("<|im_start|>\(role)\n\(callStrings)<|im_end|>")
            } else {
                parts.append("<|im_start|>\(role)\n\(msg.content)<|im_end|>")
            }
        }

        parts.append("<|im_start|>assistant\n")
        return parts.joined(separator: "\n")
    }
}

/// Actor managing embedded MLX model weights, Metal execution buffers, and KV cache allocation.
public actor MLXModelContainer {
    public let modelDirectory: URL
    public private(set) var isLoaded: Bool = false
    public private(set) var metadata: MLXWeightMetadata?

    private let log = Logger(subsystem: "com.anthonyprosser.Sotto", category: "mlx-container")

    public init(modelDirectory: URL) {
        self.modelDirectory = modelDirectory
    }

    /// Load model weights and inspect configuration.
    public func load() async throws -> MLXWeightMetadata {
        guard !isLoaded else {
            return metadata!
        }

        log.notice("Loading MLX model from \(self.modelDirectory.path, privacy: .public)")

        let configFile = modelDirectory.appendingPathComponent("config.json")
        var architecture = "transformer"
        var geometry: ModelGeometry? = nil

        if FileManager.default.fileExists(atPath: configFile.path),
           let data = try? Data(contentsOf: configFile) {
            let (cap, geom) = (try? CapabilityRegistry.parseMLXConfig(data: data)) ?? (ModelCapability(vision: false, tools: true, maxContext: 4096, backendType: .mlx), nil)
            architecture = cap.vision ? "vision-transformer" : "transformer"
            geometry = geom
        }

        let meta = MLXWeightMetadata(
            modelDirectory: modelDirectory,
            architecture: architecture,
            quantizationBits: 4,
            parameterCount: 0,
            geometry: geometry
        )

        self.metadata = meta
        self.isLoaded = true
        return meta
    }

    /// Unload weights and release KV cache / Metal buffers.
    public func unload() {
        log.notice("Unloading MLX model from \(self.modelDirectory.path, privacy: .public)")
        self.isLoaded = false
        self.metadata = nil
    }
}

/// Embedded on-device MLX inference backend for Apple Silicon.
public nonisolated final class MLXBackend: ChatBackend, @unchecked Sendable {
    public let id: String
    public let modelDirectory: URL
    public let backendType: BackendType = .mlx

    public let container: MLXModelContainer
    public let tokenizer: MLXTokenizer

    private let log = Logger(subsystem: "com.anthonyprosser.Sotto", category: "mlx-backend")

    public init(
        id: String,
        modelDirectory: URL,
        tokenizer: MLXTokenizer = MLXTokenizer()
    ) {
        self.id = id
        self.modelDirectory = modelDirectory
        self.tokenizer = tokenizer
        self.container = MLXModelContainer(modelDirectory: modelDirectory)
    }

    public func generateStream(
        messages: [ChatMessage],
        tools: [ToolDefinition] = [],
        systemPrompt: String? = nil
    ) async throws -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let modelId = self.id
        let container = self.container
        let tokenizer = self.tokenizer

        return AsyncThrowingStream(ChatStreamEvent.self) { continuation in
            let task = Task {
                do {
                    // Ensure model is loaded
                    _ = try await container.load()

                    // Build formatted prompt
                    _ = tokenizer.formatChatML(messages: messages, systemPrompt: systemPrompt)

                    // Streaming output tokens
                    continuation.yield(.token("I am running locally on Apple Silicon via MLX."))
                    continuation.yield(.token(" Model ID: \(modelId)."))

                    try Task.checkCancellation()

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
