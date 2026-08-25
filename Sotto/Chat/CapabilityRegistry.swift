import Foundation

/// Supported model execution backends in Sotto.
public nonisolated enum BackendType: String, Sendable, Codable, Equatable, CaseIterable {
    case appleFoundation = "apple_foundation"
    case mlx = "mlx"
    case openAI = "openai"
}

/// Declared capabilities for a specific model ID.
public nonisolated struct ModelCapability: Sendable, Codable, Equatable {
    public let vision: Bool
    public let tools: Bool
    public let maxContext: Int
    public let backendType: BackendType

    public init(vision: Bool, tools: Bool, maxContext: Int, backendType: BackendType) {
        self.vision = vision
        self.tools = tools
        self.maxContext = maxContext
        self.backendType = backendType
    }
}

/// Thread-safe registry mapping `model_id -> ModelCapability(vision, tools, max_ctx, backendType)`.
public nonisolated final class CapabilityRegistry: @unchecked Sendable {
    public static let shared = CapabilityRegistry()

    private let lock = NSLock()
    private var registry: [String: ModelCapability] = [:]

    /// Default capability for Apple Foundation Models (SystemLanguageModel).
    /// Fixed at 4096 tokens total, tools supported, vision false per §7.2 / models-and-network.md §1.1.
    public static let appleFoundationDefault = ModelCapability(
        vision: false,
        tools: true,
        maxContext: 4096,
        backendType: .appleFoundation
    )

    public init() {
        self.registry["apple-foundation"] = Self.appleFoundationDefault
        self.registry["system"] = Self.appleFoundationDefault
    }

    /// Register or override capabilities for a given model ID.
    public func register(modelId: String, capability: ModelCapability) {
        lock.lock()
        defer { lock.unlock() }
        registry[modelId] = capability
    }

    /// Retrieve capability for a model ID, falling back to Apple Foundation default if matching standard system tags.
    public func capability(for modelId: String) -> ModelCapability? {
        lock.lock()
        defer { lock.unlock() }
        if let cap = registry[modelId] {
            return cap
        }
        if modelId == "apple-foundation" || modelId == "system" {
            return Self.appleFoundationDefault
        }
        return nil
    }

    /// Remove a registered model.
    public func unregister(modelId: String) {
        lock.lock()
        defer { lock.unlock() }
        registry.removeValue(forKey: modelId)
    }

    /// Clear all registered models except built-ins.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        registry.removeAll()
        registry["apple-foundation"] = Self.appleFoundationDefault
        registry["system"] = Self.appleFoundationDefault
    }

    // MARK: - Parsers

    /// Parse Hugging Face / MLX `config.json` data for capability detection and model geometry.
    public static func parseMLXConfig(
        data: Data,
        defaultBackend: BackendType = .mlx
    ) throws -> (capability: ModelCapability, geometry: ModelGeometry?) {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: [], debugDescription: "Invalid JSON in config.json")
            )
        }

        // Vision detection: vision_config, vision_tower, or model_type contains vl/vision
        let hasVisionConfig = json["vision_config"] != nil
        let hasVisionTower = json["vision_tower"] != nil || json["image_token_index"] != nil
        let modelType = (json["model_type"] as? String)?.lowercased() ?? ""
        let isVisionModelType = modelType.contains("vl") || modelType.contains("vision") || modelType.contains("mllama")

        var isVisionArchitecture = false
        if let architectures = json["architectures"] as? [String] {
            isVisionArchitecture = architectures.contains { arch in
                let lower = arch.lowercased()
                return lower.contains("vl") || lower.contains("vision") || lower.contains("mllama")
            }
        }

        let vision = hasVisionConfig || hasVisionTower || isVisionModelType || isVisionArchitecture

        // Context length
        let maxContext = (json["max_position_embeddings"] as? Int)
            ?? (json["max_sequence_length"] as? Int)
            ?? (json["context_length"] as? Int)
            ?? (json["sliding_window"] as? Int)
            ?? 4096

        // Tools capability heuristic (e.g. gemma, qwen, llama, mistral)
        let tools = true

        // Geometry extraction
        let layers = (json["num_hidden_layers"] as? Int)
            ?? (json["n_layer"] as? Int)
            ?? (json["num_layers"] as? Int)

        let numAttnHeads = (json["num_attention_heads"] as? Int)
            ?? (json["n_head"] as? Int)

        let kvHeads = (json["num_key_value_heads"] as? Int)
            ?? (json["n_head_kv"] as? Int)
            ?? numAttnHeads

        let hiddenSize = (json["hidden_size"] as? Int) ?? (json["n_embd"] as? Int)

        var headDim = json["head_dim"] as? Int
        if headDim == nil, let hidden = hiddenSize, let heads = numAttnHeads, heads > 0 {
            headDim = hidden / heads
        }

        var geometry: ModelGeometry? = nil
        if let l = layers, let kv = kvHeads, let hd = headDim {
            geometry = ModelGeometry(layerCount: l, kvHeadCount: kv, headDimension: hd)
        }

        let capability = ModelCapability(
            vision: vision,
            tools: tools,
            maxContext: maxContext,
            backendType: defaultBackend
        )

        return (capability, geometry)
    }

    /// Parse Ollama `/api/show` response data.
    public static func parseOllamaShow(
        data: Data,
        defaultBackend: BackendType = .openAI
    ) throws -> (capability: ModelCapability, geometry: ModelGeometry?) {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: [], debugDescription: "Invalid JSON in /api/show response")
            )
        }

        var vision = false
        var tools = false

        if let capabilities = json["capabilities"] as? [String] {
            let lowerCaps = capabilities.map { $0.lowercased() }
            tools = lowerCaps.contains("tools")
            vision = lowerCaps.contains("vision") || lowerCaps.contains("clip")
        }

        if !vision, let details = json["details"] as? [String: Any] {
            if let families = details["families"] as? [String] {
                let lowerFamilies = families.map { $0.lowercased() }
                vision = lowerFamilies.contains("clip") || lowerFamilies.contains("mllama") || lowerFamilies.contains("vision")
            }
        }

        var maxContext = 4096
        var geometry: ModelGeometry? = nil

        if let modelInfo = json["model_info"] as? [String: Any] {
            // Context length: find key ending in context_length
            for (k, v) in modelInfo {
                if k.hasSuffix(".context_length"), let ctx = v as? Int {
                    maxContext = ctx
                    break
                }
            }

            var layers: Int?
            var kvHeads: Int?
            var headCount: Int?
            var keyLength: Int?

            for (k, v) in modelInfo {
                if (k.hasSuffix(".block_count") || k.hasSuffix(".layer_count")), let val = v as? Int {
                    layers = val
                } else if k.hasSuffix(".attention.head_count_kv"), let val = v as? Int {
                    kvHeads = val
                } else if k.hasSuffix(".attention.head_count"), let val = v as? Int {
                    headCount = val
                } else if (k.hasSuffix(".attention.key_length") || k.hasSuffix(".head_dim")), let val = v as? Int {
                    keyLength = val
                }
            }

            let effectiveKV = kvHeads ?? headCount
            if let l = layers, let kv = effectiveKV, let hd = keyLength {
                geometry = ModelGeometry(layerCount: l, kvHeadCount: kv, headDimension: hd)
            }
        }

        let capability = ModelCapability(
            vision: vision,
            tools: tools,
            maxContext: maxContext,
            backendType: defaultBackend
        )

        return (capability, geometry)
    }
}
