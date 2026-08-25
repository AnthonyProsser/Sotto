import Foundation

/// Supported model execution backends in Sotto.
nonisolated enum BackendType: String, Sendable, Codable, Equatable, CaseIterable {
    case appleFoundation = "apple_foundation"
    case mlx = "mlx"
    case openAI = "openai"
}

/// Declared capabilities for a specific model ID (§7.2).
///
/// `vision` is the only gate in Sotto — it gates on the model, never the machine.
/// `tools` selects between the harness's two tool paths, so a wrong answer here
/// is a silent no-op rather than an error: see `toolsSupported(chatTemplate:)`.
nonisolated struct ModelCapability: Sendable, Codable, Equatable {
    let vision: Bool
    let tools: Bool
    let maxContext: Int
    let backendType: BackendType

    init(vision: Bool, tools: Bool, maxContext: Int, backendType: BackendType) {
        self.vision = vision
        self.tools = tools
        self.maxContext = maxContext
        self.backendType = backendType
    }
}

/// Thread-safe registry mapping `model_id -> ModelCapability(vision, tools, max_ctx, backendType)`.
nonisolated final class CapabilityRegistry: @unchecked Sendable {
    static let shared = CapabilityRegistry()

    private let lock = NSLock()
    private var registry: [String: ModelCapability] = [:]

    /// Apple's on-device model. 4096 total — prompt *and* output — confirmed at
    /// runtime, and `vision` is permanently false: it is a text-only model
    /// (`rules/models-and-network.md` §1.1). Tools are native.
    static let appleFoundationDefault = ModelCapability(
        vision: false,
        tools: true,
        maxContext: 4096,
        backendType: .appleFoundation
    )

    init() {
        self.registry["apple-foundation"] = Self.appleFoundationDefault
        self.registry["system"] = Self.appleFoundationDefault
    }

    /// Register or override capabilities for a given model ID.
    func register(modelId: String, capability: ModelCapability) {
        lock.lock()
        defer { lock.unlock() }
        registry[modelId] = capability
    }

    /// Retrieve capability for a model ID.
    func capability(for modelId: String) -> ModelCapability? {
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
    func unregister(modelId: String) {
        lock.lock()
        defer { lock.unlock() }
        registry.removeValue(forKey: modelId)
    }

    /// Clear all registered models except built-ins.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        registry.removeAll()
        registry["apple-foundation"] = Self.appleFoundationDefault
        registry["system"] = Self.appleFoundationDefault
    }

    // MARK: - Parsers

    /// Whether a model's chat template can render tool definitions.
    ///
    /// A template that never mentions tools drops them on the floor, so declaring
    /// `tools: true` for one means the harness sends native definitions the model
    /// never sees and the prompt-and-parse fallback never runs — the call is
    /// silently impossible. **Unknown therefore answers `false`**: the fallback
    /// works on any model, so guessing low degrades to a slower path while
    /// guessing high removes the capability outright.
    static func toolsSupported(chatTemplate: String?) -> Bool {
        guard let chatTemplate else { return false }
        return chatTemplate.contains("tools") || chatTemplate.contains("tool_calls")
    }

    /// Parse Hugging Face / MLX `config.json` for capability detection and model geometry.
    ///
    /// `chatTemplate` is the model's Jinja template, which may live in
    /// `tokenizer_config.json` or in a sibling `chat_template.jinja`;
    /// `ModelStore` resolves that and passes whichever it found.
    static func parseMLXConfig(
        data: Data,
        chatTemplate: String? = nil,
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
            tools: toolsSupported(chatTemplate: chatTemplate),
            maxContext: maxContext,
            backendType: defaultBackend
        )

        return (capability, geometry)
    }

    /// Parse Ollama `/api/show` response data.
    static func parseOllamaShow(
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

        // Older Ollama builds predate `capabilities` and answer only with the
        // template, which is the same evidence the MLX path reads.
        if !tools, let template = json["template"] as? String {
            tools = toolsSupported(chatTemplate: template)
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
