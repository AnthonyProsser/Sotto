import Foundation

/// Architectural geometry parameters for calculating model KV cache size.
public nonisolated struct ModelGeometry: Sendable, Codable, Equatable {
    public let layerCount: Int
    public let kvHeadCount: Int
    public let headDimension: Int

    public init(layerCount: Int, kvHeadCount: Int, headDimension: Int) {
        self.layerCount = layerCount
        self.kvHeadCount = kvHeadCount
        self.headDimension = headDimension
    }
}

/// Exact memory breakdown and advisory threshold evaluation.
public nonisolated struct MemoryEstimate: Sendable, Codable, Equatable {
    public let weightsBytes: Int64
    public let kvCacheBytes: Int64
    public let runtimeOverheadBytes: Int64
    public let totalBytes: Int64
    public let physicalRAMBytes: UInt64
    public let percentageOfRAM: Double

    /// Advisory amber state triggering when total estimate exceeds ~60% of physical RAM.
    public var isAmber: Bool {
        percentageOfRAM >= 0.60
    }

    public init(
        weightsBytes: Int64,
        kvCacheBytes: Int64,
        runtimeOverheadBytes: Int64,
        totalBytes: Int64,
        physicalRAMBytes: UInt64,
        percentageOfRAM: Double
    ) {
        self.weightsBytes = weightsBytes
        self.kvCacheBytes = kvCacheBytes
        self.runtimeOverheadBytes = runtimeOverheadBytes
        self.totalBytes = totalBytes
        self.physicalRAMBytes = physicalRAMBytes
        self.percentageOfRAM = percentageOfRAM
    }
}

/// Standalone memory estimation implementing §2.3:
/// `estimate = weights + KV + ~15% runtime overhead`
/// `KV bytes = 2 * n_layers * n_kv_heads * head_dim * ctx_len * bytes_per_element`
public nonisolated enum MemoryEstimator {
    /// Calculate exact KV cache bytes according to §2.3.
    public static func kvCacheBytes(
        layers: Int,
        kvHeads: Int,
        headDim: Int,
        contextLength: Int,
        bytesPerElement: Int = 2
    ) -> Int64 {
        guard layers > 0, kvHeads > 0, headDim > 0, contextLength > 0, bytesPerElement > 0 else {
            return 0
        }
        return Int64(2) * Int64(layers) * Int64(kvHeads) * Int64(headDim) * Int64(contextLength) * Int64(bytesPerElement)
    }

    /// Compute total memory estimate given weights and KV cache bytes.
    public static func estimate(
        weightsBytes: Int64,
        kvCacheBytes: Int64,
        overheadFraction: Double = 0.15,
        physicalRAM: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> MemoryEstimate {
        let baseSum = max(0, weightsBytes) + max(0, kvCacheBytes)
        let overhead = Int64(Double(baseSum) * overheadFraction)
        let total = baseSum + overhead
        let percentage = physicalRAM > 0 ? (Double(total) / Double(physicalRAM)) : 0.0

        return MemoryEstimate(
            weightsBytes: weightsBytes,
            kvCacheBytes: kvCacheBytes,
            runtimeOverheadBytes: overhead,
            totalBytes: total,
            physicalRAMBytes: physicalRAM,
            percentageOfRAM: percentage
        )
    }

    /// Compute total memory estimate given weights and model geometry at a specific context length.
    public static func estimate(
        weightsBytes: Int64,
        geometry: ModelGeometry,
        contextLength: Int,
        bytesPerElement: Int = 2,
        overheadFraction: Double = 0.15,
        physicalRAM: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> MemoryEstimate {
        let kv = kvCacheBytes(
            layers: geometry.layerCount,
            kvHeads: geometry.kvHeadCount,
            headDim: geometry.headDimension,
            contextLength: contextLength,
            bytesPerElement: bytesPerElement
        )
        return estimate(
            weightsBytes: weightsBytes,
            kvCacheBytes: kv,
            overheadFraction: overheadFraction,
            physicalRAM: physicalRAM
        )
    }
}
