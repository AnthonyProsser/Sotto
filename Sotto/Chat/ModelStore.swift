import Foundation
import os

/// A model that is already on disk, with everything the runtime needs to load,
/// size, and describe it.
nonisolated struct LocalModel: Sendable, Equatable, Identifiable {
    /// The directory name. Also the `model_id` §7.2's registry is keyed on and
    /// the per-turn attribution written into `chat.md` (§9.1).
    let id: String
    let directory: URL
    /// Sum of the `.safetensors` files — the `weights` term in §2.3's estimate.
    let weightsBytes: Int64
    let capability: ModelCapability
    let geometry: ModelGeometry?

    /// §2.3's estimate at a given context length. Advisory, never a gate.
    func memoryEstimate(contextLength: Int) -> MemoryEstimate {
        guard let geometry else {
            return MemoryEstimator.estimate(weightsBytes: weightsBytes, kvCacheBytes: 0)
        }
        return MemoryEstimator.estimate(
            weightsBytes: weightsBytes,
            geometry: geometry,
            contextLength: contextLength
        )
    }
}

/// Finds models already on disk.
///
/// This is §7.4's first rung and nothing beyond it. Acquisition — the curated
/// browser, downloads, progress, resume, the Hugging Face and `ollama pull`
/// rungs — is slice 8's, and none of it is here. What slice 7 needs is the
/// answer to "what can I load right now," because without it `MLXBackend` has
/// no model to run and no weights to size.
nonisolated enum ModelStore {
    private static let log = Logger(subsystem: "com.anthonyprosser.Sotto", category: "model-store")

    /// `~/Library/Application Support/Sotto/models`.
    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support")
        return base.appending(path: "Sotto/models", directoryHint: .isDirectory)
    }

    /// Every loadable model under `root`, sorted by id. Missing directory is empty, not an error.
    static func discover(in root: URL = ModelStore.root) -> [LocalModel] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return contents
            .compactMap { url -> LocalModel? in
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return nil }
                do {
                    return try model(at: url)
                } catch {
                    log.notice("Skipping \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    return nil
                }
            }
            .sorted { $0.id < $1.id }
    }

    /// Reads one model directory. Throws if it has no `config.json` or no weights.
    static func model(at directory: URL) throws -> LocalModel {
        let configURL = directory.appending(path: "config.json")
        guard let configData = try? Data(contentsOf: configURL) else {
            throw ChatBackendError.modelLoadFailed("No config.json in \(directory.lastPathComponent)")
        }

        let weights = weightsBytes(in: directory)
        guard weights > 0 else {
            throw ChatBackendError.modelLoadFailed("No .safetensors weights in \(directory.lastPathComponent)")
        }

        let (capability, geometry) = try CapabilityRegistry.parseMLXConfig(
            data: configData,
            chatTemplate: chatTemplate(in: directory)
        )

        return LocalModel(
            id: directory.lastPathComponent,
            directory: directory,
            weightsBytes: weights,
            capability: capability,
            geometry: geometry
        )
    }

    /// Discovers every local model and registers its capability, so the harness
    /// picks the right tool path for whichever one a turn runs on.
    @discardableResult
    static func registerAll(in root: URL = ModelStore.root) -> [LocalModel] {
        let models = discover(in: root)
        for model in models {
            CapabilityRegistry.shared.register(modelId: model.id, capability: model.capability)
        }
        return models
    }

    // MARK: - Directory reading

    private static func weightsBytes(in directory: URL) -> Int64 {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return contents
            .filter { $0.pathExtension == "safetensors" }
            .reduce(into: Int64(0)) { total, url in
                total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
    }

    /// The model's Jinja chat template, from wherever the conversion put it.
    ///
    /// Newer exports write a sibling `chat_template.jinja` and leave the key out
    /// of `tokenizer_config.json` entirely — G9v3-3B does, which is what made
    /// reading only the one place look like "this model has no template."
    static func chatTemplate(in directory: URL) -> String? {
        if let data = try? Data(contentsOf: directory.appending(path: "tokenizer_config.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let template = json["chat_template"] as? String {
                return template
            }
            // The multi-template form: [{"name": ..., "template": ...}, …]
            if let variants = json["chat_template"] as? [[String: Any]] {
                let templates = variants.compactMap { $0["template"] as? String }
                if !templates.isEmpty { return templates.joined(separator: "\n") }
            }
        }

        return try? String(contentsOf: directory.appending(path: "chat_template.jinja"), encoding: .utf8)
    }
}
