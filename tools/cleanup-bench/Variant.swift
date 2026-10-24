//
//  Variant.swift — cleanup-bench
//
//  One way of running a cleanup pass. Every knob the pass has is a field, so a
//  candidate is a value, not a fork of `Cleanup.swift`. `prod` is the shipping
//  path called directly; `baseline` rebuilds it from fields and must match it.
//

import Foundation
import FoundationModels

struct Variant {
    /// The session's instructions.
    var instructions: (DictationProfile) -> String = { Cleanup.instructions(for: $0) }
    /// The per-pass prompt around the marked transcript.
    var prompt: (String) -> String = { "Transcript: <transcript>\($0)</transcript>\nOutput:" }
    /// Passed to `prewarm(promptPrefix:)`; nil prewarms the instructions alone.
    var prewarmPrefix: String? = nil
    var options: (String) -> GenerationOptions = {
        GenerationOptions(temperature: 0, maximumResponseTokens: $0.count / 2 + 64)
    }
    /// Runs on the marked transcript before the model sees it.
    var preprocess: (String) -> String = { $0 }
    /// Non-nil skips the model entirely and inserts this.
    var fastPath: (String) -> String? = { _ in nil }
    /// Output → inserted text. Throws to reject (raw inserted instead).
    var postprocess: (_ output: String, _ input: String) throws -> String = Cleanup.sanitize
    /// Streams to record time-to-first-token; off, the pass is `respond(to:)` like the shipping one.
    var stream = false
    /// Calls `Cleanup.shared.clean` instead of the fields above.
    var isProd = false
}

let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)

/// Add a candidate here. Keep `prod` and `baseline` untouched.
@MainActor let variants: [String: Variant] = [
    "prod": Variant(isProd: true),
    "baseline": Variant(),
    "fast": Variant(fastPath: { FastPath.clean($0) }),
    "resolve": Variant(fastPath: { raw in Combo.resolveFirst = true; return FastPath.clean(Combo.plan(raw).sentences.joined(separator: " ")) }),
    "rf": Variant(fastPath: { FastPath.clean(Corrections.resolve($0)) }),
    "combo": Variant(
        instructions: { _ in Combo.instructions },
        preprocess: { raw in
            let plan = Combo.plan(raw)
            Combo.pending = plan
            return plan.input
        },
        fastPath: { raw in Combo.plan(raw).groups.isEmpty ? FastPath.clean(raw) : nil },
        postprocess: { try Combo.finish($0, input: $1) }
    ),
    "combo-r": Variant(
        instructions: { _ in Combo.instructions },
        preprocess: { raw in
            Combo.resolveFirst = true
            let plan = Combo.plan(raw)
            Combo.pending = plan
            return plan.input
        },
        fastPath: { raw in Combo.resolveFirst = true; let p = Combo.plan(raw); return p.groups.isEmpty ? FastPath.clean(p.sentences.joined(separator: " ")) : nil },
        postprocess: { try Combo.finish($0, input: $1) }
    ),
]
