import Testing
import Foundation
@testable import Sotto

struct MemoryEstimatorTests {

    @Test func kvCacheCalculationMatchesFormula() {
        // Test formula: 2 * layers * kv_heads * head_dim * ctx_len * bytes_per_element
        // e.g. 26 layers, 4 kv heads, 128 head dim, 4096 ctx, 2 bytes/element
        // 2 * 26 * 4 * 128 * 4096 * 2 = 218,103,808 bytes (~208 MB)
        let kv = MemoryEstimator.kvCacheBytes(
            layers: 26,
            kvHeads: 4,
            headDim: 128,
            contextLength: 4096,
            bytesPerElement: 2
        )
        #expect(kv == 218_103_808)
    }

    @Test func memoryEstimateIncludesOverheadAndChecksAmberThreshold() {
        let weightsBytes: Int64 = 2_500_000_000 // 2.5 GB
        let kvBytes: Int64 = 200_000_000        // 0.2 GB
        let physicalRAM: UInt64 = 8_000_000_000  // 8 GB

        let estimate = MemoryEstimator.estimate(
            weightsBytes: weightsBytes,
            kvCacheBytes: kvBytes,
            overheadFraction: 0.15,
            physicalRAM: physicalRAM
        )

        // Sum = 2.7 GB. Overhead (15%) = 405,000,000 bytes. Total = 3,105,000,000 bytes
        #expect(estimate.weightsBytes == 2_500_000_000)
        #expect(estimate.kvCacheBytes == 200_000_000)
        #expect(estimate.runtimeOverheadBytes == 405_000_000)
        #expect(estimate.totalBytes == 3_105_000_000)
        #expect(estimate.physicalRAMBytes == 8_000_000_000)

        // 3.105 / 8 = ~38.8% -> Not amber (< 60%)
        #expect(estimate.percentageOfRAM < 0.60)
        #expect(!estimate.isAmber)

        // Large model on 8 GB RAM: weights 4.5 GB, KV 500 MB -> Sum 5 GB + 15% (750 MB) = 5.75 GB
        // 5.75 / 8 = 71.875% -> Amber (>= 60%)
        let largeEstimate = MemoryEstimator.estimate(
            weightsBytes: 4_500_000_000,
            kvCacheBytes: 500_000_000,
            overheadFraction: 0.15,
            physicalRAM: physicalRAM
        )
        #expect(largeEstimate.totalBytes == 5_750_000_000)
        #expect(largeEstimate.isAmber)
    }

    @Test func capabilityRegistryRegistersAndRetrievesBuiltInAndCustomModels() {
        let registry = CapabilityRegistry()

        // Apple Foundation default
        let appleCap = registry.capability(for: "apple-foundation")
        #expect(appleCap != nil)
        #expect(appleCap?.vision == false)
        #expect(appleCap?.tools == true)
        #expect(appleCap?.maxContext == 4096)
        #expect(appleCap?.backendType == .appleFoundation)

        // Custom registration
        let customCap = ModelCapability(
            vision: true,
            tools: true,
            maxContext: 8192,
            backendType: .mlx
        )
        registry.register(modelId: "qwen2.5-vl-7b", capability: customCap)

        let retrieved = registry.capability(for: "qwen2.5-vl-7b")
        #expect(retrieved == customCap)
    }

    @Test func mlxConfigParsingExtractsVisionAndGeometry() throws {
        let jsonString = """
        {
            "model_type": "qwen2_vl",
            "vision_config": {
                "depth": 32
            },
            "num_hidden_layers": 28,
            "num_attention_heads": 16,
            "num_key_value_heads": 2,
            "hidden_size": 2048,
            "max_position_embeddings": 32768
        }
        """
        let data = jsonString.data(using: .utf8)!
        let (capability, geometry) = try CapabilityRegistry.parseMLXConfig(data: data)

        #expect(capability.vision == true)
        // `config.json` says nothing about tools; the chat template does, and
        // none was supplied. This asserted `true` while it was hardcoded.
        #expect(capability.tools == false)
        #expect(capability.maxContext == 32768)
        #expect(capability.backendType == .mlx)

        #expect(geometry != nil)
        #expect(geometry?.layerCount == 28)
        #expect(geometry?.kvHeadCount == 2)
        #expect(geometry?.headDimension == 128) // 2048 / 16
    }

    @Test func ollamaShowParsingExtractsCapabilitiesAndModelInfo() throws {
        let jsonString = """
        {
            "capabilities": ["tools", "vision"],
            "model_info": {
                "llama.context_length": 8192,
                "llama.block_count": 32,
                "llama.attention.head_count_kv": 8,
                "llama.attention.key_length": 128
            },
            "details": {
                "families": ["llama", "clip"]
            }
        }
        """
        let data = jsonString.data(using: .utf8)!
        let (capability, geometry) = try CapabilityRegistry.parseOllamaShow(data: data)

        #expect(capability.vision == true)
        #expect(capability.tools == true)
        #expect(capability.maxContext == 8192)
        #expect(capability.backendType == .openAI)

        #expect(geometry != nil)
        #expect(geometry?.layerCount == 32)
        #expect(geometry?.kvHeadCount == 8)
        #expect(geometry?.headDimension == 128)
    }
}
