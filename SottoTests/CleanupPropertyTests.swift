//
//  CleanupPropertyTests.swift
//  SottoTests
//
//  Feature 8: cleanup removes disfluencies and adds punctuation, and never
//  rewrites. The model is sampled at temperature 0 but not bit-stable across
//  runs, so each live case runs N times and asserts a pass rate; the rate is
//  printed as `PASSRATE <case> k/N` for the record.
//

import AVFoundation
import Foundation
import Testing
@testable import Sotto

@MainActor
struct CleanupPropertyTests {

    static let runs = 5
    /// 4 of 5: one stray sample is tolerated, a systematic miss is not.
    static let threshold = 4

    private let profile = DictationProfile(name: "Test", cleanupEnabled: true)

    // MARK: - Helpers

    /// Lowercased words with punctuation and pause markers stripped.
    nonisolated static func words(_ text: String) -> [String] {
        AudioHistory.unmark(text)
            .lowercased()
            .split { !($0.isLetter || $0.isNumber || $0 == "'") }
            .map(String.init)
    }

    /// True when every word of `part` appears in `whole`, in order.
    nonisolated static func isSubsequence(_ part: [String], of whole: [String]) -> Bool {
        var rest = whole[...]
        for word in part {
            guard let i = rest.firstIndex(of: word) else { return false }
            rest = rest[(i + 1)...]
        }
        return true
    }

    /// Runs `check` on `runs` fresh cleanups of `input`; prints and asserts the rate.
    private func measure(
        _ name: String,
        _ inputs: [String],
        check: (_ input: String, _ output: String) -> Bool
    ) async throws {
        var passed = 0
        var failures: [String] = []
        for _ in 0..<Self.runs {
            var ok = true
            for input in inputs {
                let out = try await Cleanup.shared.clean(input, profile: profile)
                if !check(input, out) {
                    ok = false
                    failures.append("\(input) -> \(out)")
                }
            }
            if ok { passed += 1 }
        }
        let line = "PASSRATE \(name) \(passed)/\(Self.runs)\n"
        print(line, terminator: "")
        let path = "/private/tmp/claude-501/-Users-anthonyprosser-Code-Sotto/9905479f-50fa-4b0d-9436-b51d90048347/scratchpad/cleanup-passrates.txt"
        if let h = FileHandle(forWritingAtPath: path) ?? (FileManager.default.createFile(atPath: path, contents: nil) ? FileHandle(forWritingAtPath: path) : nil) {
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data(line.utf8))
            try? h.close()
        }
        #expect(passed >= Self.threshold, "\(name): \(passed)/\(Self.runs); e.g. \(failures.first ?? "")")
    }

    // MARK: - Deterministic (no model)

    @Test func wordHelpersIgnoreCaseAndPunctuation() {
        #expect(Self.words("Hello, there! [pause 300ms] It's me.") == ["hello", "there", "it's", "me"])
        #expect(Self.isSubsequence(["a", "c"], of: ["a", "b", "c"]))
        #expect(!Self.isSubsequence(["c", "a"], of: ["a", "b", "c"]))
    }

    @Test func promptForbidsRewritingAndTranslating() {
        // Overflow silently costs cleanup (4097 > 4096 seen at runtime), so the
        // prompt stays short: ~4 chars/token puts 1,400 chars near 350 tokens.
        #expect(Cleanup.instructions(for: DictationProfile(name: "Default")).count < 1400)
        let prompt = Cleanup.instructions(for: DictationProfile(name: "Default"))
        #expect(prompt.contains("NEVER translate"))
        #expect(prompt.contains("Add punctuation and capitalisation"))
        #expect(prompt.contains("Wednesday"))
    }

    /// Cleanup off, unavailable, or failed all save with `cleaned == nil`; a real
    /// pass saves both, and raw is the marked transcript in either case.
    @Test func historyKeepsRawAndWritesCleanedOnlyWhenGiven() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleanup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_000))
        buffer.frameLength = 32_000
        let draft = Transcription.Draft(
            text: "um hello there",
            words: [.init(text: "um", start: 0.1), .init(text: "hello", start: 0.4), .init(text: "there", start: 1.4)],
            pauses: [.init(start: 0.7, duration: 0.5)]
        )
        for cleaned in [nil, "Hello there."] {
            let url = try #require(try AudioHistory.save(
                draft: draft, buffers: [buffer], format: format, to: root,
                now: Date(timeIntervalSinceNow: cleaned == nil ? 0 : 5), cleaned: cleaned
            ))
            let entry = try AudioHistory.load(from: url)
            #expect(entry.raw.contains("um hello"))
            #expect(entry.raw.contains("[pause 500ms]"))
            #expect(entry.cleaned == cleaned)
        }
    }

    // MARK: - Live (on-device model)

    @Test(.enabled(if: liveCleanupAvailable()))
    func fillersRemoved() async throws {
        let fillers: Set<String> = ["um", "uh", "er", "eh"]
        try await measure("fillersRemoved", [
            "so um i was uh thinking that we should uh go early [pause 900ms]",
            "er the the report is um almost ready [pause 900ms]",
        ]) { input, out in
            let w = Self.words(out)
            return fillers.isDisjoint(with: w) && Self.isSubsequence(w, of: Self.words(input))
        }
    }

    @Test(.enabled(if: liveCleanupAvailable()))
    func stuttersCollapsed() async throws {
        try await measure("stuttersCollapsed", [
            "i i want to to go to the the market [pause 900ms]",
        ]) { _, out in
            Self.words(out) == ["i", "want", "to", "go", "to", "the", "market"]
        }
    }

    @Test(.enabled(if: liveCleanupAvailable()))
    func selfCorrectionResolved() async throws {
        try await measure("selfCorrectionResolved", [
            "let's meet at three [pause 200ms] no wait actually four [pause 900ms]",
            "go to the store [pause 200ms] no wait actually the pharmacy [pause 900ms]",
        ]) { input, out in
            let w = Self.words(out)
            if input.contains("three") {
                return w.contains("four") && !w.contains("three") && !w.contains("wait")
            }
            return w.contains("pharmacy") && !w.contains("store") && !w.contains("wait")
        }
    }

    /// Content words survive in order: nothing swapped, reordered, added, or
    /// summarised. With no fillers or corrections in the input the word
    /// sequence must be identical.
    @Test(.enabled(if: liveCleanupAvailable()))
    func noRewrite() async throws {
        try await measure("noRewrite", [
            "the quarterly report shows that revenue grew slightly [pause 500ms] but costs rose faster than expected [pause 900ms]",
            "please send the contract to legal before friday afternoon [pause 900ms]",
            "she said the results were surprisingly good considering everything [pause 900ms]",
        ]) { input, out in
            Self.words(out) == Self.words(input)
        }
    }

    @Test(.enabled(if: liveCleanupAvailable()))
    func punctuationFromPauses() async throws {
        try await measure("punctuationFromPauses", [
            "the report is finished [pause 900ms] i will send it tomorrow [pause 900ms]",
        ]) { _, out in
            let t = out.trimmingCharacters(in: .whitespacesAndNewlines)
            return !out.contains("[pause")
                && (t.last.map { ".?!".contains($0) } ?? false)
                && (t.first?.isUppercase ?? false)
                && t.dropLast().contains { ".,;!?".contains($0) }
        }
    }

    @Test(.enabled(if: liveCleanupAvailable()))
    func spanishStaysSpanish() async throws {
        let english: Set<String> = ["we", "should", "leave", "early", "the", "and", "is"]
        try await measure("spanishStaysSpanish", [
            "eh bueno este creo que deberíamos salir temprano [pause 900ms]",
        ]) { input, out in
            let w = Self.words(out)
            return !w.contains("eh") && !w.contains("este")
                && w.contains("deberíamos") && w.contains("salir") && w.contains("temprano")
                && english.isDisjoint(with: w)
                && Self.isSubsequence(w, of: Self.words(input))
        }
    }

    /// Profanity and medical terms are content to transform, not to refuse.
    @Test(.enabled(if: liveCleanupAvailable()))
    func sensitiveContentNotRefused() async throws {
        try await measure("sensitiveContentNotRefused", [
            "this damn printer is broken again [pause 900ms]",
            "the patient presented with acute myocardial infarction and needs a transfusion [pause 900ms]",
        ]) { input, out in
            Self.words(out) == Self.words(input)
        }
    }

    @Test(.enabled(if: liveCleanupAvailable()))
    func alreadyCleanUnchanged() async throws {
        try await measure("alreadyCleanUnchanged", [
            "The meeting starts at nine in the conference room. [pause 900ms]",
            "Thanks for the update, I will review it tonight. [pause 900ms]",
        ]) { input, out in
            Self.words(out) == Self.words(input)
        }
    }
}
