//
//  main.swift — cleanup-bench
//
//  Runs cleanup variants over a corpus of real recordings' marked transcripts
//  and writes one JSON line per pass: timing, model output, inserted text.
//  Scoring against references is `score.py`'s job.
//
//  bench --corpus corpus/dev.json --variant prod,baseline --out results/x.jsonl
//        [--gap 1.5] [--idle 0] [--limit N] [--repeat 1]
//
//  Timing is only honest when nothing else is using the on-device model: it
//  serialises every request on the machine, so two benches at once each
//  measure the other.
//

import Foundation
import FoundationModels

struct Entry: Codable { let id: String; let raw: String; let locale: String?; let words: Int }

struct Row: Codable {
    let id: String
    let variant: String
    let run: Int
    let ms: Double
    let firstMs: Double?
    let model: Bool
    let output: String?
    let inserted: String
    let accepted: Bool
    let error: String?
    /// Prompt and output tokens: a speed proxy that holds when several benches
    /// share the model and wall time does not.
    let inTokens: Int?
    let outTokens: Int?
}

var args: [String: String] = [:]
var it = CommandLine.arguments.dropFirst().makeIterator()
while let key = it.next() { args[String(key.drop { $0 == "-" })] = it.next() ?? "" }

let corpusPath = args["corpus"] ?? "corpus/dev.json"
let names = (args["variant"] ?? "prod").split(separator: ",").map(String.init)
let outPath = args["out"] ?? "results/run.jsonl"
let gap = Double(args["gap"] ?? "1.5")!
let idle = Double(args["idle"] ?? "0")!
let repeats = Int(args["repeat"] ?? "1")!
var corpus = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: URL(fileURLWithPath: corpusPath)))
if let limit = args["limit"].flatMap(Int.init) { corpus = Array(corpus.prefix(limit)) }

guard case .available = model.availability else {
    print("model unavailable: \(model.availability)")
    exit(1)
}

try FileManager.default.createDirectory(
    at: URL(fileURLWithPath: outPath).deletingLastPathComponent(), withIntermediateDirectories: true)
FileManager.default.createFile(atPath: outPath, contents: nil)
let out = try FileHandle(forWritingTo: URL(fileURLWithPath: outPath))
let encoder = JSONEncoder()
let clock = ContinuousClock()
let profile = DictationProfile(name: "Bench", cleanupEnabled: true)

func ms(_ d: Duration) -> Double {
    Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
}

/// Mirrors `Cleanup.clean` for a non-prod variant: the session staged and
/// prewarmed before the pass, as the shipping prewarm leaves it.
@MainActor
final class Runner {
    var staged: LanguageModelSession?
    let variant: Variant
    init(_ variant: Variant) { self.variant = variant }

    func stage() {
        guard !variant.isProd else { Cleanup.shared.prewarm(); return }
        let session = LanguageModelSession(model: model, instructions: variant.instructions(profile))
        session.prewarm(promptPrefix: variant.prewarmPrefix.map { Prompt($0) })
        staged = session
    }

    func run(_ raw: String) async -> (ms: Double, first: Double?, model: Bool, output: String?, inserted: String, accepted: Bool, error: String?) {
        let start = clock.now
        if variant.isProd {
            do {
                let text = try await Cleanup.shared.clean(raw, profile: profile)
                return (ms(clock.now - start), nil, true, nil, text, true, nil)
            } catch {
                return (ms(clock.now - start), nil, true, nil, AudioHistory.unmark(raw), false, "\(error)")
            }
        }
        if let fast = variant.fastPath(raw) {
            return (ms(clock.now - start), nil, false, nil, fast, true, nil)
        }
        let input = variant.preprocess(raw)
        let session = staged ?? LanguageModelSession(model: model, instructions: variant.instructions(profile))
        staged = nil
        var first: Double?
        var output = ""
        do {
            if variant.stream {
                let stream = session.streamResponse(to: variant.prompt(input), options: variant.options(input))
                for try await snapshot in stream {
                    if first == nil { first = ms(clock.now - start) }
                    output = snapshot.content
                }
            } else {
                output = try await session.respond(to: variant.prompt(input), options: variant.options(input)).content
            }
            let text = try variant.postprocess(output, input)
            return (ms(clock.now - start), first, true, output, text, true, nil)
        } catch {
            return (ms(clock.now - start), first, true, output, AudioHistory.unmark(raw), false, "\(error)")
        }
    }
}

for name in names {
    guard let variant = variants[name] else { print("unknown variant \(name)"); exit(1) }
    let runner = Runner(variant)
    var times: [Double] = []
    var rejected = 0
    for run in 0..<repeats {
        // One pass off the clock so the first row is not the launch-cold one.
        if run == 0 {
            runner.stage()
            try await Task.sleep(for: .seconds(gap))
            _ = await runner.run("hello [pause 300ms] this is a warm up")
        }
        for entry in corpus {
            runner.stage()
            try await Task.sleep(for: .seconds(gap + idle))
            let r = await runner.run(entry.raw)
            times.append(r.ms)
            if !r.accepted { rejected += 1 }
            let inTokens = r.model ? try? await model.tokenCount(for: variant.prompt(variant.preprocess(entry.raw))) : 0
            let outTokens = r.model ? try? await model.tokenCount(for: r.output ?? r.inserted) : 0
            let row = Row(id: entry.id, variant: name, run: run, ms: r.ms, firstMs: r.first, model: r.model,
                          output: r.output, inserted: r.inserted, accepted: r.accepted, error: r.error,
                          inTokens: inTokens, outTokens: outTokens)
            try out.write(contentsOf: encoder.encode(row) + Data("\n".utf8))
        }
    }
    let sorted = times.sorted()
    let median = sorted[sorted.count / 2]
    let p90 = sorted[min(sorted.count - 1, sorted.count * 9 / 10)]
    print("\(name): n=\(times.count) median=\(Int(median))ms p90=\(Int(p90))ms rejected=\(rejected)")
}
