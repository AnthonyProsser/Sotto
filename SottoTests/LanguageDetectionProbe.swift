//
//  LanguageDetectionProbe.swift — THROWAWAY spike, evidence only (DECISIONS.md, 2026-09-28).
//  Measures per-dictation English/Spanish detection on Apple Speech: two fresh
//  analyzers (en, es) fed the same buffers, winner by `transcriptionConfidence`.
//  Nothing here reaches the dictation path. `say` audio is a FLOOR, not a microphone.
//
//  Never goes through `Transcription.shared`: every run builds its own modules and
//  analyzers (one module per analyzer for its lifetime, rules/audio-and-transcription §1.0).
//  Never downloads: a locale that is not `.installed` after `reserve()` is reported and skipped.
//

import AVFoundation
import Darwin
import Foundation
import NaturalLanguage
import Speech
import Testing
import os
@testable import Sotto

private let outDir = "/private/tmp/claude-501/-Users-anthonyprosser-Code-Sotto/9905479f-50fa-4b0d-9436-b51d90048347/scratchpad"

// MARK: - Measurement helpers

private func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}

private func cpuSeconds() -> Double {
    var u = rusage()
    getrusage(RUSAGE_SELF, &u)
    func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
    return s(u.ru_utime) + s(u.ru_stime)
}

/// RSS (MB) summed over processes whose name mentions speech, plus their names.
private func speechHelperRSS() -> (mb: Double, names: Set<String>) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-axo", "rss=,comm="]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return (-1, []) }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    var total = 0.0
    var names = Set<String>()
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
        let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
        guard parts.count == 2, let kb = Double(parts[0]) else { continue }
        let name = (String(parts[1]) as NSString).lastPathComponent
        let lower = name.lowercased()
        if lower.contains("speech") || lower.contains("corespeech") || lower.contains("assistantd") {
            total += kb / 1024
            names.insert(name)
        }
    }
    return (total, names)
}

/// Peak in-process footprint and speech-helper RSS while a run is live.
private final class MemorySampler: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (peak: 0.0, helperPeak: 0.0, names: Set<String>()))
    private var task: Task<Void, Never>?
    func start() {
        task = Task.detached { [state] in
            var tick = 0
            while !Task.isCancelled {
                let f = footprintMB()
                state.withLock { $0.peak = max($0.peak, f) }
                if tick % 25 == 0 {   // ps is a process spawn; every ~250 ms
                    let h = speechHelperRSS()
                    state.withLock { $0.helperPeak = max($0.helperPeak, h.mb); $0.names.formUnion(h.names) }
                }
                tick += 1
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
    }
    func stop() -> (peak: Double, helperPeak: Double, names: Set<String>) {
        task?.cancel()
        return state.withLock { ($0.peak, $0.helperPeak, $0.names) }
    }
}

private func median(_ xs: [Double]) -> Double? { percentile(xs, 0.5) }
private func percentile(_ xs: [Double], _ p: Double) -> Double? {
    guard !xs.isEmpty else { return nil }
    let s = xs.sorted()
    return s[min(s.count - 1, max(0, Int((p * Double(s.count)).rounded(.up)) - 1))]
}
private func f(_ x: Double?, _ d: Int = 2) -> String { x.map { String(format: "%.\(d)f", $0) } ?? "-" }

// MARK: - Run machinery

private struct Ev {
    let locale: String
    let wall: Double        // seconds since run start
    let audioEnd: Double    // end of the result's audio range, seconds
    let conf: Double?       // chars-weighted mean of run confidences in this result
    let chars: Int
    let text: String
}

private struct Report {
    var fixture = "", config = "", rate = "", rep = 0
    var audioSeconds = 0.0
    var totalWall = 0.0      // start -> text
    var eoiToText = 0.0      // finalize call -> text (the latency the user feels)
    var feedEndWall = 0.0
    var events: [Ev] = []
    var texts: [String: String] = [:]
    var conf: [String: Double] = [:]
    var winner: String?
    var decision: (audio: Double, wall: Double, reason: String)?
    var memBefore = 0.0, memPeak = 0.0, memAfter = 0.0, helperPeak = 0.0
    var cpu = 0.0
    var graceExpired = false
}

private final class Lane: @unchecked Sendable {
    let id: String
    let module: SpeechTranscriber
    var analyzer: SpeechAnalyzer
    var cont: AsyncStream<AnalyzerInput>.Continuation
    var collector: Task<Void, Never>?
    var cancelled = false
    init(id: String, module: SpeechTranscriber, analyzer: SpeechAnalyzer, cont: AsyncStream<AnalyzerInput>.Continuation) {
        self.id = id; self.module = module; self.analyzer = analyzer; self.cont = cont
    }
}

private actor Trace {
    var events: [Ev] = []
    func add(_ e: Ev) { events.append(e) }
    func snapshot() -> [Ev] { events }
}

/// Mean confidence per locale, chars-weighted across finalized results.
private func weighted(_ events: [Ev], _ id: String) -> Double? {
    var s = 0.0, w = 0
    for e in events where e.locale == id { if let c = e.conf { s += c * Double(e.chars); w += e.chars } }
    return w > 0 ? s / Double(w) : nil
}

private struct EarlyRule {
    var minResults = 1
    var gap = 0.10
    var forceAtAudio = 3.0
}

private func makeModule(_ locale: Locale) -> SpeechTranscriber {
    SpeechTranscriber(
        locale: locale, transcriptionOptions: [], reportingOptions: [],
        attributeOptions: [.audioTimeRange, .transcriptionConfidence]
    )
}

private func collect(_ m: SpeechTranscriber, id: String, t0: ContinuousClock.Instant, trace: Trace) -> Task<Void, Never> {
    Task {
        do {
            for try await r in m.results where r.isFinal {
                var cs = 0.0, w = 0, chars = 0
                for run in r.text.runs {
                    let s = String(r.text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !s.isEmpty else { continue }
                    chars += s.count
                    if let c = run.transcriptionConfidence { cs += c * Double(s.count); w += s.count }
                }
                let wall = (ContinuousClock.now - t0).seconds
                await trace.add(Ev(
                    locale: id, wall: wall, audioEnd: r.range.end.seconds,
                    conf: w > 0 ? cs / Double(w) : nil, chars: chars,
                    text: String(r.text.characters)
                ))
            }
        } catch {}
    }
}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

/// One transcription of `buffers` through `locales`. `shared` puts every module on
/// ONE analyzer (variant c); otherwise each locale gets its own analyzer and its own
/// copy of the buffer stream (the fan-out).
private func runOnce(
    fixture: String, config: String, locales: [(id: String, locale: Locale)],
    buffers: [AVAudioPCMBuffer], realtime: Bool, early: EarlyRule? = nil, shared: Bool = false
) async throws -> Report {
    var rep = Report()
    rep.fixture = fixture; rep.config = config; rep.rate = realtime ? "rt" : "file"
    rep.audioSeconds = Double(buffers.reduce(0) { $0 + Int($1.frameLength) }) / buffers[0].format.sampleRate
    rep.memBefore = footprintMB()
    let cpu0 = cpuSeconds()
    let sampler = MemorySampler(); sampler.start()
    let clock = ContinuousClock()
    let t0 = clock.now
    let trace = Trace()

    var lanes: [Lane] = []
    if shared {
        let modules = locales.map { makeModule($0.locale) }
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: modules)
        for (i, l) in locales.enumerated() {
            let lane = Lane(id: l.id, module: modules[i], analyzer: analyzer, cont: cont)
            lane.collector = collect(modules[i], id: l.id, t0: t0, trace: trace)
            lanes.append(lane)
        }
        try await analyzer.start(inputSequence: stream)
    } else {
        for l in locales {
            let module = makeModule(l.locale)
            let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
            let analyzer = SpeechAnalyzer(modules: [module])
            let lane = Lane(id: l.id, module: module, analyzer: analyzer, cont: cont)
            lane.collector = collect(module, id: l.id, t0: t0, trace: trace)
            lanes.append(lane)
            try await analyzer.start(inputSequence: stream)
        }
    }

    // Feed. Deadline pacing at real time so sleep drift does not accumulate.
    let feedStart = clock.now
    var audioT = 0.0
    var decided = false
    for (i, b) in buffers.enumerated() {
        if realtime {
            let due = feedStart + .milliseconds(Int(Double(i) * 100))
            if due > clock.now { try await Task.sleep(until: due, clock: clock) }
        }
        for lane in lanes where !lane.cancelled { lane.cont.yield(AnalyzerInput(buffer: b)) }
        audioT += Double(b.frameLength) / b.format.sampleRate

        if let rule = early, realtime, !decided, lanes.count == 2, !shared {
            let ev = await trace.snapshot()
            let a = lanes[0].id, c = lanes[1].id
            let na = ev.filter { $0.locale == a }.count, nc = ev.filter { $0.locale == c }.count
            let ca = weighted(ev, a), cc = weighted(ev, c)
            var reason: String?
            if na >= rule.minResults, nc >= rule.minResults, let ca, let cc, abs(ca - cc) >= rule.gap {
                reason = "gap \(f(abs(ca - cc)))>=\(rule.gap) with >=\(rule.minResults) results each"
            } else if audioT >= rule.forceAtAudio, ca != nil || cc != nil {
                reason = "forced at \(rule.forceAtAudio)s audio"
            }
            if let reason {
                decided = true
                let loserIdx = (ca ?? -1) >= (cc ?? -1) ? 1 : 0
                let loser = lanes[loserIdx]
                loser.cancelled = true
                loser.cont.finish()
                let an = loser.analyzer
                Task { await an.cancelAndFinishNow() }
                loser.collector?.cancel()
                rep.decision = (audioT, (clock.now - t0).seconds, "\(reason); survivor=\(lanes[1 - loserIdx].id)")
            }
        }
    }
    rep.feedEndWall = (clock.now - t0).seconds
    let eoi = clock.now
    let finished = Set(lanes.filter { !$0.cancelled }.map { ObjectIdentifier($0.analyzer) })
    for lane in lanes where !lane.cancelled { lane.cont.finish() }
    var analyzers: [SpeechAnalyzer] = []
    var seen = Set<ObjectIdentifier>()
    for lane in lanes where !lane.cancelled && finished.contains(ObjectIdentifier(lane.analyzer)) {
        if seen.insert(ObjectIdentifier(lane.analyzer)).inserted { analyzers.append(lane.analyzer) }
    }
    await withTaskGroup(of: Void.self) { g in
        for a in analyzers { g.addTask { try? await a.finalizeAndFinishThroughEndOfInput() } }
    }
    // Bounded wait on the result sequences (Transcription.resultGrace), then cancel.
    let graceFlag = OSAllocatedUnfairLock(initialState: false)
    let collectors = lanes.filter { !$0.cancelled }.compactMap(\.collector)
    let timeout = Task {
        try? await Task.sleep(for: .seconds(2))
        if !Task.isCancelled { graceFlag.withLock { $0 = true }; collectors.forEach { $0.cancel() } }
    }
    for c in collectors { await c.value }
    timeout.cancel()
    let tText = clock.now
    rep.eoiToText = (tText - eoi).seconds
    rep.totalWall = (tText - t0).seconds
    rep.graceExpired = graceFlag.withLock { $0 }
    rep.cpu = cpuSeconds() - cpu0

    let (peak, helper, _) = sampler.stop()
    rep.memPeak = peak; rep.helperPeak = helper
    rep.memAfter = footprintMB()
    rep.events = await trace.snapshot()
    for l in locales {
        let evs = rep.events.filter { $0.locale == l.id }.sorted { $0.audioEnd < $1.audioEnd }
        rep.texts[l.id] = evs.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        if let c = weighted(rep.events, l.id) { rep.conf[l.id] = c }
    }
    if locales.count > 1 {
        if let d = rep.decision, let survivor = d.reason.split(separator: "=").last { rep.winner = String(survivor) }
        else {
            let alive = locales.map(\.id).filter { !(rep.texts[$0] ?? "").isEmpty }
            rep.winner = alive.max { (rep.conf[$0] ?? 0) < (rep.conf[$1] ?? 0) } ?? locales[0].id
        }
    }
    for lane in lanes where !lane.cancelled { lane.collector?.cancel() }
    return rep
}

// MARK: - Fixtures

private func loadBuffers(_ url: URL, target: AVAudioFormat) throws -> [AVAudioPCMBuffer] {
    let file = try AVAudioFile(forReading: url)
    let src = file.processingFormat
    let chunk = AVAudioFrameCount(target.sampleRate / 10)   // 100 ms, like capture
    let converter = (src.sampleRate == target.sampleRate && src.commonFormat == target.commonFormat
                     && src.channelCount == target.channelCount) ? nil : AVAudioConverter(from: src, to: target)
    var out: [AVAudioPCMBuffer] = []
    file.framePosition = 0
    while file.framePosition < file.length {
        guard let input = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: chunk) else { break }
        try file.read(into: input, frameCount: chunk)
        guard input.frameLength > 0 else { break }
        guard let converter else { out.append(input); continue }
        guard let conv = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: chunk + 64) else { break }
        var used = false
        var err: NSError?
        converter.convert(to: conv, error: &err) { _, status in
            if used { status.pointee = .noDataNow; return nil }
            used = true; status.pointee = .haveData; return input
        }
        if conv.frameLength > 0 { out.append(conv) }
    }
    return out
}

private struct Fixture { let name: String; let truth: String?; let note: String }

private let fixtures: [Fixture] = [
    .init(name: "en-short2", truth: "en", note: "3 words"),
    .init(name: "en-short1", truth: "en", note: "3 words"),
    .init(name: "en-q3", truth: "en", note: ""),
    .init(name: "en-q1", truth: "en", note: ""),
    .init(name: "en-q2", truth: "en", note: ""),
    .init(name: "en-long", truth: "en", note: "~10 s"),
    .init(name: "en-fillers", truth: "en", note: "fillers, 1.2 s pause"),
    .init(name: "en-vocab", truth: "en", note: "invented nouns"),
    .init(name: "es-short2", truth: "es", note: "2 words"),
    .init(name: "es-short1", truth: "es", note: "3 words"),
    .init(name: "es-q3", truth: "es", note: ""),
    .init(name: "es-q1", truth: "es", note: ""),
    .init(name: "es-q2", truth: "es", note: ""),
    .init(name: "es-long", truth: "es", note: "~8 s"),
    .init(name: "es-basic", truth: "es", note: "1.2 s pause"),
    .init(name: "en-codeswitch", truth: nil, note: "EN then ES, mixed"),
]

// MARK: - The probe

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SOTTO_PROBES"] != nil,
                             "manual probe; set TEST_RUNNER_SOTTO_PROBES=1"))
struct LanguageDetectionProbe {
    private static let en = (id: "en", locale: Locale(identifier: "en_US"))
    private static let es = (id: "es", locale: Locale(identifier: "es_ES"))

    private static func assetHeader() async -> (text: String, ok: Bool) {
        var s = "== SDK / assets ==\n"
        var ok = true
        for l in [en, es] {
            let sup = await SpeechTranscriber.supportedLocale(equivalentTo: l.locale)
            let reserved = (try? await AssetInventory.reserve(locale: l.locale))
            let m = makeModule(l.locale)
            let st = await AssetInventory.status(forModules: [m])
            s += "\(l.locale.identifier): supportedLocale=\(sup?.identifier ?? "nil") reserve=\(String(describing: reserved)) status=\(st)\n"
            if st != .installed { ok = false }
        }
        let reservedNow = await AssetInventory.reservedLocales.map(\.identifier)
        s += "reservedLocales=\(reservedNow)\n"
        let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [makeModule(en.locale)])
        s += "best format en: \(String(describing: fmt))\n"
        let fmtEs = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [makeModule(es.locale)])
        s += "best format es: \(String(describing: fmtEs))\n"
        s += "baseline footprint MB=\(f(footprintMB(), 1)); helper RSS=\(f(speechHelperRSS().mb, 1)) MB \(speechHelperRSS().names.sorted())\n"
        return (s, ok)
    }

    @Test
    func probeLanguageDetection() async throws {
        var out = "LanguageDetectionProbe — \(Date())\n"
        out += "say audio is a floor, not a real-microphone figure.\n\n"
        let header = await Self.assetHeader()
        out += header.text
        func flush() {
            print(out)
            try? out.write(toFile: outDir + "/lang-probe-results.txt", atomically: true, encoding: .utf8)
        }
        guard header.ok else {
            out += "\nSTOP: a locale is not .installed after reserve(); consent rule forbids downloading. Nothing else measured.\n"
            flush(); return
        }
        guard let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [makeModule(Self.en.locale)]) else {
            out += "no audio format\n"; flush(); return
        }
        var bufs: [String: [AVAudioPCMBuffer]] = [:]
        for fx in fixtures { bufs[fx.name] = try loadBuffers(fixtureURL(fx.name + ".caf"), target: target) }
        let langs = [Self.en, Self.es]
        var all: [Report] = []

        // Cold: the first-ever transcription per locale in this process, then a throwaway dual.
        let cold1 = try await runOnce(fixture: "en-q1", config: "en", locales: [Self.en], buffers: bufs["en-q1"]!, realtime: false)
        let cold2 = try await runOnce(fixture: "es-q1", config: "es", locales: [Self.es], buffers: bufs["es-q1"]!, realtime: false)
        _ = try await runOnce(fixture: "en-q1", config: "dual", locales: langs, buffers: bufs["en-q1"]!, realtime: false)
        out += "\n== Cold (first use in process) ==\nen single wall \(f(cold1.totalWall))s, es single wall \(f(cold2.totalWall))s (later rows are warm)\n"

        // File rate: 3 reps of en, es, dual per fixture.
        for fx in fixtures {
            for rep in 0..<3 {
                for (cfg, ls) in [("en", [Self.en]), ("es", [Self.es]), ("dual", langs)] {
                    var r = try await runOnce(fixture: fx.name, config: cfg, locales: ls, buffers: bufs[fx.name]!, realtime: false)
                    r.rep = rep; all.append(r)
                }
            }
        }
        // Real-time rate on fixtures <= 6 s: 2 reps of en, es, dual + 1 live early-cancel.
        let rtSet = fixtures.filter { (bufs[$0.name]!.count) <= 60 }
        for fx in rtSet {
            for rep in 0..<2 {
                for (cfg, ls) in [("en", [Self.en]), ("es", [Self.es]), ("dual", langs)] {
                    var r = try await runOnce(fixture: fx.name, config: cfg, locales: ls, buffers: bufs[fx.name]!, realtime: true)
                    r.rep = rep; all.append(r)
                }
            }
            var e = try await runOnce(fixture: fx.name, config: "early", locales: langs, buffers: bufs[fx.name]!, realtime: true, early: EarlyRule())
            e.rep = 0; all.append(e)
        }

        func runs(_ fx: String, _ cfg: String, _ rate: String) -> [Report] {
            all.filter { $0.fixture == fx && $0.config == cfg && $0.rate == rate }
        }
        func mconf(_ fx: String, _ cfg: String, _ loc: String, _ rate: String = "file") -> Double? {
            let v = runs(fx, cfg, rate).compactMap { $0.conf[loc] }
            return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
        }
        func winnerOf(_ ce: Double?, _ cs: Double?) -> String { (ce ?? 0) >= (cs ?? 0) ? "en" : "es" }

        // ---- Accuracy table
        out += "\n== Accuracy (a: dual full run, file rate; confidences = mean over 3 reps, chars-weighted) ==\n"
        out += "fixture          truth  audio_s conf_en conf_es  (a)full  full_ok  (a)early@audio_s  early_ok  reason\n"
        var fullOK = 0, fullN = 0, earlyOK = 0, earlyN = 0
        for fx in fixtures {
            let dual = runs(fx.name, "dual", "file")
            let w = winnerOf(mconf(fx.name, "dual", "en"), mconf(fx.name, "dual", "es"))
            let ea = runs(fx.name, "early", "rt").first
            let audio = dual.first?.audioSeconds ?? 0
            var okS = "n/a"
            if let t = fx.truth { fullN += 1; if w == t { fullOK += 1 }; okS = w == t ? "ok" : "WRONG" }
            var eS = "-", eOK = "-", reason = ""
            if let ea, let win = ea.winner {
                eS = "\(win)@\(f(ea.decision?.audio))"
                reason = ea.decision?.reason ?? "no early decision (full run)"
                if let t = fx.truth { earlyN += 1; if win == t { earlyOK += 1 }; eOK = win == t ? "ok" : "WRONG" }
            }
            out += "\(fx.name.padding(toLength: 16, withPad: " ", startingAt: 0)) \((fx.truth ?? "mixed").padding(toLength: 5, withPad: " ", startingAt: 0)) \(f(audio, 1).padding(toLength: 7, withPad: " ", startingAt: 0)) \(f(mconf(fx.name, "dual", "en")).padding(toLength: 7, withPad: " ", startingAt: 0)) \(f(mconf(fx.name, "dual", "es")).padding(toLength: 7, withPad: " ", startingAt: 0))  \(w)       \(okS.padding(toLength: 7, withPad: " ", startingAt: 0)) \(eS.padding(toLength: 17, withPad: " ", startingAt: 0)) \(eOK.padding(toLength: 8, withPad: " ", startingAt: 0)) \(reason)\n"
        }
        out += "(a) full: \(fullOK)/\(fullN) correct.  (a) live early-cancel (rt, <=6 s fixtures): \(earlyOK)/\(earlyN) correct.\n"

        // ---- Texts
        out += "\n== Texts (first dual file-rate run, per-locale; and single baselines) ==\n"
        for fx in fixtures {
            guard let d = runs(fx.name, "dual", "file").first else { continue }
            out += "[\(fx.name)] en(\(f(d.conf["en"]))): \(d.texts["en"] ?? "")\n"
            out += "[\(fx.name)] es(\(f(d.conf["es"]))): \(d.texts["es"] ?? "")\n"
            if let t = fx.truth, let s = runs(fx.name, t, "file").first {
                out += "    single-\(t) text identical to dual-\(t): \(s.texts[t] == d.texts[t])\n"
            }
        }

        // ---- Post-hoc early-decision sweep on the traces of the first dual file-rate run (ordered by audio end)
        out += "\n== Early-decision sweep (post-hoc over dual traces, events ordered by audioEnd) ==\n"
        out += "K = results required per locale; gap = |conf_en - conf_es| required. Cells: winner@audio_s, '!' = wrong, '.' = never decided.\n"
        let sweeps: [(Int, Double)] = [(1, 0.05), (1, 0.10), (1, 0.20), (2, 0.05), (2, 0.10), (2, 0.20)]
        out += "fixture          " + sweeps.map { "K\($0.0)/g\(f($0.1))" }.joined(separator: "  ") + "\n"
        var sweepStats = Array(repeating: (ok: 0, wrong: 0, none: 0, audioSum: 0.0), count: sweeps.count)
        for fx in fixtures {
            guard let d = runs(fx.name, "dual", "file").first else { continue }
            let ev = d.events.sorted { ($0.audioEnd, $0.wall) < ($1.audioEnd, $1.wall) }
            var cells: [String] = []
            for (i, sw) in sweeps.enumerated() {
                var seen: [Ev] = []
                var cell = "."
                for e in ev {
                    seen.append(e)
                    let ne = seen.filter { $0.locale == "en" }.count, ns = seen.filter { $0.locale == "es" }.count
                    if ne >= sw.0, ns >= sw.0, let ce = weighted(seen, "en"), let cs = weighted(seen, "es"), abs(ce - cs) >= sw.1 {
                        let win = ce >= cs ? "en" : "es"
                        let bad = fx.truth != nil && win != fx.truth
                        cell = "\(win)@\(f(e.audioEnd, 1))" + (bad ? "!" : "")
                        if fx.truth != nil { if bad { sweepStats[i].wrong += 1 } else { sweepStats[i].ok += 1; sweepStats[i].audioSum += e.audioEnd } }
                        break
                    }
                }
                if cell == "." { sweepStats[i].none += 1 }
                cells.append(cell)
            }
            out += fx.name.padding(toLength: 16, withPad: " ", startingAt: 0) + " " + cells.map { $0.padding(toLength: 10, withPad: " ", startingAt: 0) }.joined(separator: " ") + "\n"
        }
        for (i, sw) in sweeps.enumerated() {
            let s = sweepStats[i]
            out += "K\(sw.0)/gap\(f(sw.1)): correct \(s.ok), wrong \(s.wrong), undecided(incl. mixed) \(s.none), mean decision audio \(f(s.ok > 0 ? s.audioSum / Double(s.ok) : nil, 2)) s\n"
        }

        // ---- Live early cancel
        out += "\n== Live early-cancel (rt, rule: >=1 result each and gap>=0.10, else forced at 3 s) ==\n"
        out += "fixture          audio_s decided_at_audio decided_at_wall winner full_winner match eoi->text_ms dual_eoi->text_ms\n"
        for fx in rtSet {
            guard let e = runs(fx.name, "early", "rt").first else { continue }
            let full = winnerOf(mconf(fx.name, "dual", "en"), mconf(fx.name, "dual", "es"))
            let dualRt = runs(fx.name, "dual", "rt").map { $0.eoiToText * 1000 }
            out += "\(fx.name.padding(toLength: 16, withPad: " ", startingAt: 0)) \(f(e.audioSeconds, 1).padding(toLength: 7, withPad: " ", startingAt: 0)) \(f(e.decision?.audio).padding(toLength: 16, withPad: " ", startingAt: 0)) \(f(e.decision?.wall).padding(toLength: 15, withPad: " ", startingAt: 0)) \((e.winner ?? "-").padding(toLength: 6, withPad: " ", startingAt: 0)) \(full.padding(toLength: 11, withPad: " ", startingAt: 0)) \(e.winner == full ? "yes" : "NO ")   \(f(e.eoiToText * 1000, 0).padding(toLength: 11, withPad: " ", startingAt: 0)) \(f(median(dualRt), 0))\n"
        }

        // ---- Approach (b)
        out += "\n== Approach (b): primary = last-used locale; re-run other only if primary conf < thr (post-hoc from single runs) ==\n"
        out += "Miss latency = primary eoi->text (rt) + other-locale single re-run at FILE rate (audio was buffered; production keeps the PCM).\n"
        let truthful = fixtures.filter { $0.truth != nil }
        for primary in ["en", "es"] {
            let other = primary == "en" ? "es" : "en"
            for thr in [0.5, 0.7, 0.8, 0.9] {
                var acceptedOK = 0, falseAccept = 0, rerun = 0, finalOK = 0
                var missLat: [Double] = []
                for fx in truthful {
                    let cp = mconf(fx.name, primary, primary), co = mconf(fx.name, other, other)
                    var win = primary
                    if (cp ?? 0) >= thr {
                        if fx.truth == primary { acceptedOK += 1 } else { falseAccept += 1 }
                    } else {
                        rerun += 1
                        win = winnerOf(primary == "en" ? cp : co, primary == "en" ? co : cp)
                        let p = median(runs(fx.name, primary, "rt").map { $0.eoiToText })
                            ?? median(runs(fx.name, primary, "file").map { $0.eoiToText }) ?? 0
                        let r = median(runs(fx.name, other, "file").map(\.totalWall)) ?? 0
                        missLat.append((p + r) * 1000)
                    }
                    if win == fx.truth { finalOK += 1 }
                }
                out += "primary=\(primary) thr=\(f(thr)): final correct \(finalOK)/\(truthful.count); accepted-correct \(acceptedOK), FALSE-ACCEPT (wrong lang kept) \(falseAccept), reruns \(rerun); rerun latency ms p50 \(f(median(missLat), 0)) p95 \(f(percentile(missLat, 0.95), 0))\n"
            }
        }
        out += "\nprimary-conf on the WRONG language (the false-accept risk), per fixture (single runs, file rate):\n"
        for fx in truthful {
            let wrong = fx.truth == "en" ? "es" : "en"
            out += "  \(fx.name): conf(\(wrong) on \(fx.truth!) audio)=\(f(mconf(fx.name, wrong, wrong))) text=\(runs(fx.name, wrong, "file").first?.texts[wrong] ?? "")\n"
        }

        // ---- Latency
        out += "\n== Latency: finalize call -> text (ms) ==\n"
        for rate in ["file", "rt"] {
            for cfg in ["en", "es", "dual", "early"] {
                let v = all.filter { $0.config == cfg && $0.rate == rate }.map { $0.eoiToText * 1000 }
                guard !v.isEmpty else { continue }
                out += "\(rate.padding(toLength: 4, withPad: " ", startingAt: 0)) \(cfg.padding(toLength: 6, withPad: " ", startingAt: 0)) n=\(v.count) p50 \(f(median(v), 0)) p95 \(f(percentile(v, 0.95), 0)) max \(f(v.max(), 0))\n"
            }
        }
        out += "\nPer fixture median eoi->text ms  (en / es / dual) file | rt:\n"
        for fx in fixtures {
            func m(_ c: String, _ r: String) -> String { f(median(runs(fx.name, c, r).map { $0.eoiToText * 1000 }), 0) }
            out += "  \(fx.name.padding(toLength: 16, withPad: " ", startingAt: 0)) file \(m("en", "file")) / \(m("es", "file")) / \(m("dual", "file"))   | rt \(m("en", "rt")) / \(m("es", "rt")) / \(m("dual", "rt"))\n"
        }
        let graces = all.filter(\.graceExpired).count
        out += "result-grace (2 s) expired in \(graces) of \(all.count) runs\n"

        // ---- Contention proxy
        out += "\n== Contention proxy (file rate): total wall, dual vs singles ==\n"
        out += "fixture          audio_s en_wall es_wall dual_wall  dual/max(en,es)  dual/(en+es)   [~1.0 / ~0.5 = parallel; ~2.0 / ~1.0 = serialised]\n"
        var ratiosMax: [Double] = [], ratiosSum: [Double] = []
        for fx in fixtures {
            let we = median(runs(fx.name, "en", "file").map(\.totalWall)), ws = median(runs(fx.name, "es", "file").map(\.totalWall))
            let wd = median(runs(fx.name, "dual", "file").map(\.totalWall))
            guard let we, let ws, let wd else { continue }
            ratiosMax.append(wd / max(we, ws)); ratiosSum.append(wd / (we + ws))
            out += "\(fx.name.padding(toLength: 16, withPad: " ", startingAt: 0)) \(f(runs(fx.name, "dual", "file").first?.audioSeconds, 1).padding(toLength: 7, withPad: " ", startingAt: 0)) \(f(we, 3).padding(toLength: 7, withPad: " ", startingAt: 0)) \(f(ws, 3).padding(toLength: 7, withPad: " ", startingAt: 0)) \(f(wd, 3).padding(toLength: 9, withPad: " ", startingAt: 0))  \(f(wd / max(we, ws)).padding(toLength: 15, withPad: " ", startingAt: 0)) \(f(wd / (we + ws)))\n"
        }
        out += "median dual/max = \(f(median(ratiosMax))), median dual/sum = \(f(median(ratiosSum))). No sudo: powermetrics unavailable, so ANE occupancy is NOT measured; this ratio is the only proxy and cannot distinguish ANE contention from CPU/model-load overhead.\n"
        let cpuRows = ["en", "es", "dual"].map { c -> String in
            let v = all.filter { $0.config == c && $0.rate == "file" }.map(\.cpu)
            let a = all.filter { $0.config == c && $0.rate == "file" }.map(\.audioSeconds)
            return "\(c): in-process CPU s per audio s = \(f(v.reduce(0, +) / max(a.reduce(0, +), 0.001), 3))"
        }
        out += "In-process CPU (host process only, excludes speech daemons): " + cpuRows.joined(separator: "; ") + "\n"

        // ---- Memory
        out += "\n== Memory (phys_footprint MB of the host process; helper = summed RSS of speech-named processes) ==\n"
        for rate in ["file", "rt"] {
            for cfg in ["en", "es", "dual"] {
                let rs = all.filter { $0.config == cfg && $0.rate == rate }
                guard !rs.isEmpty else { continue }
                out += "\(rate.padding(toLength: 4, withPad: " ", startingAt: 0)) \(cfg.padding(toLength: 5, withPad: " ", startingAt: 0)) before \(f(median(rs.map(\.memBefore)), 1)) peak \(f(median(rs.map(\.memPeak)), 1)) (max \(f(rs.map(\.memPeak).max(), 1))) after \(f(median(rs.map(\.memAfter)), 1)) | peak-before \(f(median(rs.map { $0.memPeak - $0.memBefore }), 1)) | helperRSS peak \(f(median(rs.map(\.helperPeak)), 1))\n"
            }
        }
        out += "helper process names seen: \(speechHelperRSS().names.sorted())\n"

        // ---- Code-switch
        out += "\n== Code-switched clip (EN sentence then ES sentence) ==\n"
        if let d = runs("en-codeswitch", "dual", "file").first {
            out += "(a) full winner: \(winnerOf(mconf("en-codeswitch", "dual", "en"), mconf("en-codeswitch", "dual", "es")))\n"
            out += "  en(\(f(mconf("en-codeswitch", "dual", "en")))): \(d.texts["en"] ?? "")\n  es(\(f(mconf("en-codeswitch", "dual", "es")))): \(d.texts["es"] ?? "")\n"
        }
        if let e = runs("en-codeswitch", "early", "rt").first {
            out += "(a) early: winner \(e.winner ?? "-") decision \(e.decision.map { "\($0.reason) at audio \(f($0.audio))s" } ?? "none"); survivor text: \(e.texts.values.first { !$0.isEmpty } ?? "")\n"
        }
        let cse = mconf("en-codeswitch", "en", "en"), css = mconf("en-codeswitch", "es", "es")
        out += "(b) primary en conf \(f(cse)) (es fallback conf \(f(css))): with thr 0.8, en primary \((cse ?? 0) >= 0.8 ? "accepts and keeps English text only" : "re-runs es and picks \(winnerOf(cse, css))")\n"

        flush()
        #expect(!all.isEmpty)
    }

    /// Variant (c): both modules on ONE analyzer, so no fan-out. Separate test and
    /// separate file: if the framework rejects it or traps, the main results are safe.
    @Test
    func probeTwoModulesOneAnalyzer() async throws {
        var out = "Two modules (en+es) on ONE SpeechAnalyzer — \(Date())\n"
        func flush() {
            print(out)
            try? out.write(toFile: outDir + "/lang-probe-onemanalyzer.txt", atomically: true, encoding: .utf8)
        }
        let header = await Self.assetHeader()
        guard header.ok, let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [makeModule(Self.en.locale)]) else {
            out += "assets not installed, skipped\n"; flush(); return
        }
        for name in ["en-q1", "es-q1", "en-short1", "es-short1"] {
            let b = try loadBuffers(fixtureURL(name + ".caf"), target: target)
            do {
                let r = try await runOnce(fixture: name, config: "shared", locales: [Self.en, Self.es], buffers: b, realtime: false, shared: true)
                out += "[\(name)] ok wall \(f(r.totalWall, 3))s eoi->text \(f(r.eoiToText * 1000, 0)) ms | en(\(f(r.conf["en"]))): \(r.texts["en"] ?? "") | es(\(f(r.conf["es"]))): \(r.texts["es"] ?? "") | winner \(r.winner ?? "-")\n"
            } catch {
                out += "[\(name)] ERROR \(error)\n"
            }
        }
        flush()
    }

    // MARK: - Text discriminator (post-hoc over dual traces)

    private struct Obs {
        let fixture: String, truth: String?, shape: String, rep: Int, words: Int
        let conf: [String: Double], text: [String: String]
        let nlEn: (en: Double, es: Double), nlEs: (en: Double, es: Double)
        /// Each locale's own language on its own transcript.
        var selfEn: Double { nlEn.en }
        var selfEs: Double { nlEs.es }
    }

    private static func nl(_ text: String) -> (en: Double, es: Double) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return (0, 0) }
        let r = NLLanguageRecognizer()
        r.languageConstraints = [.english, .spanish]
        r.processString(t)
        let h = r.languageHypotheses(withMaximum: 2)
        return (h[.english] ?? 0, h[.spanish] ?? 0)
    }

    /// Dual only, file rate, no memory/early/real-time. Both shapes: one analyzer with
    /// two modules (the shape to ship) and two analyzers (control), 3 reps each.
    @Test
    func probeLanguageDiscriminator() async throws {
        var out = "Text discriminator — \(Date())\nNLLanguageRecognizer constrained to [en, es]; say audio is a floor.\n"
        let header = await Self.assetHeader()
        out += header.text
        func flush() {
            print(out)
            try? out.write(toFile: outDir + "/lang-probe-discriminator.txt", atomically: true, encoding: .utf8)
        }
        guard header.ok, let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [makeModule(Self.en.locale)]) else {
            out += "assets not installed, stopped\n"; flush(); return
        }
        let langs = [Self.en, Self.es]
        var obs: [Obs] = []
        for fx in fixtures {
            let b = try loadBuffers(fixtureURL(fx.name + ".caf"), target: target)
            _ = try await runOnce(fixture: fx.name, config: "warm", locales: langs, buffers: b, realtime: false, shared: true)
            for shape in ["shared", "two"] {
                for rep in 0..<3 {
                    let r = try await runOnce(fixture: fx.name, config: shape, locales: langs, buffers: b, realtime: false, shared: shape == "shared")
                    let te = r.texts["en"] ?? "", ts = r.texts["es"] ?? ""
                    // Word count of the truthful-language transcript, else the longer one.
                    let words = (fx.truth == "es" ? ts : te).split(separator: " ").count
                    obs.append(Obs(fixture: fx.name, truth: fx.truth, shape: shape, rep: rep, words: words,
                                   conf: r.conf, text: r.texts, nlEn: Self.nl(te), nlEs: Self.nl(ts)))
                }
            }
        }

        typealias Rule = (Obs) -> String
        func c(_ o: Obs, _ l: String) -> Double { o.conf[l] ?? 0 }
        var rules: [(String, Rule)] = [
            ("R0 conf only", { c($0, "es") > c($0, "en") ? "es" : "en" }),
            ("R2 conf x nlSelf", { c($0, "es") * $0.selfEs > c($0, "en") * $0.selfEn ? "es" : "en" }),
            ("R4 nlSelf, tie->conf", { $0.selfEs == $0.selfEn ? (c($0, "es") > c($0, "en") ? "es" : "en") : ($0.selfEs > $0.selfEn ? "es" : "en") }),
        ]
        for t in [0.5, 0.7, 0.8, 0.9, 0.95, 0.99] {
            rules.append(("R1 es iff nlEs>=\(f(t))", { ($0.selfEs >= t && !($0.text["es"] ?? "").isEmpty) ? "es" : "en" }))
        }
        for t in [0.5, 0.8, 0.95] {
            rules.append(("R3 R1(\(f(t))) and R2", { ($0.selfEs >= t && c($0, "es") * $0.selfEs > c($0, "en") * $0.selfEn) ? "es" : "en" }))
        }

        out += "\n== Per-fixture means over 3 reps (shared analyzer): conf_en conf_es | NL(en text): p_en p_es | NL(es text): p_en p_es ==\n"
        for fx in fixtures {
            let os = obs.filter { $0.fixture == fx.name && $0.shape == "shared" }
            func m(_ k: (Obs) -> Double) -> String { f(os.map(k).reduce(0, +) / Double(max(os.count, 1))) }
            out += "\(fx.name.padding(toLength: 15, withPad: " ", startingAt: 0)) \((fx.truth ?? "mixed").padding(toLength: 5, withPad: " ", startingAt: 0)) \(m { c($0, "en") }) \(m { c($0, "es") }) | \(m { $0.nlEn.en }) \(m { $0.nlEn.es }) | \(m { $0.nlEs.en }) \(m { $0.nlEs.es })  words=\(os.first?.words ?? 0)\n"
        }

        out += "\n== Rules: correct / total runs (labelled fixtures only; 15 fixtures x 3 reps = 45 per shape) ==\n"
        out += "rule                         | shared: all  short(<=3w)  en-audio  es-audio | two: all  short  en-audio  es-audio\n"
        for (name, rule) in rules {
            var cells: [String] = []
            for shape in ["shared", "two"] {
                let lab = obs.filter { $0.shape == shape && $0.truth != nil }
                func score(_ xs: [Obs]) -> String { "\(xs.filter { rule($0) == $0.truth }.count)/\(xs.count)" }
                cells.append([score(lab), score(lab.filter { $0.words <= 3 }), score(lab.filter { $0.truth == "en" }), score(lab.filter { $0.truth == "es" })].map { $0.padding(toLength: 6, withPad: " ", startingAt: 0) }.joined(separator: " "))
            }
            out += "\(name.padding(toLength: 28, withPad: " ", startingAt: 0)) | \(cells[0]) | \(cells[1])\n"
        }
        out += "\n== Misses per rule (shared analyzer): fixture(rep)->chosen ==\n"
        for (name, rule) in rules {
            let misses = obs.filter { $0.shape == "shared" && $0.truth != nil && rule($0) != $0.truth }
            out += "\(name): " + (misses.isEmpty ? "none" : misses.map { "\($0.fixture)#\($0.rep)->\(rule($0))" }.joined(separator: " ")) + "\n"
        }
        out += "\n== Short clips (<=3 words), every run, shared analyzer ==\n"
        for o in obs where o.shape == "shared" && o.words <= 3 && o.truth != nil {
            out += "\(o.fixture)#\(o.rep) conf en/es \(f(c(o, "en")))/\(f(c(o, "es"))) nlSelf en/es \(f(o.selfEn))/\(f(o.selfEs)) | en:\"\(o.text["en"] ?? "")\" es:\"\(o.text["es"] ?? "")\"\n"
        }
        out += "\n== Code-switched clip, every run ==\n"
        for o in obs where o.fixture == "en-codeswitch" {
            out += "\(o.shape)#\(o.rep) conf en/es \(f(c(o, "en")))/\(f(c(o, "es"))) nlSelf en/es \(f(o.selfEn))/\(f(o.selfEs)) R0=\(rules[0].1(o)) R2=\(rules[1].1(o)) | en:\"\(o.text["en"] ?? "")\" es:\"\(o.text["es"] ?? "")\"\n"
        }
        out += "\n== Shared vs two-analyzer transcript quality (does sharing degrade text?) ==\n"
        for fx in fixtures {
            let a = obs.first { $0.fixture == fx.name && $0.shape == "shared" }, b = obs.first { $0.fixture == fx.name && $0.shape == "two" }
            guard let a, let b else { continue }
            out += "\(fx.name): conf shared en/es \(f(c(a, "en")))/\(f(c(a, "es"))) two \(f(c(b, "en")))/\(f(c(b, "es"))); text equal en:\(a.text["en"] == b.text["en"]) es:\(a.text["es"] == b.text["es"])\n"
        }
        flush()
        #expect(!obs.isEmpty)
    }
}
