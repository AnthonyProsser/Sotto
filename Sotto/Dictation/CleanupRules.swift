//
//  CleanupRules.swift
//  Sotto
//
//  The deterministic half of cleanup: what a transcript that `SpeechTranscriber`
//  already punctuated still needs, done without the model (DECISIONS.md,
//  2026-10-24). Benchmarked against 177 real recordings and the adversarial
//  set; the model added nothing measurable on top of it.
//

import Foundation

extension Cleanup {
    /// Self-corrections resolved, then fillers, stutters, hedges and pause
    /// markers out. Only ever deletes words — never rewords, reorders or
    /// answers, so it needs no guard of its own.
    nonisolated static func tidy(_ marked: String) -> String {
        Rules.clean(Rules.resolve(marked))
    }
}

private enum Rules {
    struct Word {
        var lead: String
        var core: String
        var trail: String
        var pause = 0

        var terminal: Bool { trail.contains { ".?!".contains($0) } }
        var comma: Bool { trail.hasSuffix(",") }
    }

    /// A pause this long with no punctuation ends the sentence.
    static let pauseMs = 600
    static let fillers: Set<String> = ["um", "uh", "uhm", "umm", "erm", "er", "eh", "hmm", "mm", "em"]
    /// Doubled on purpose ("had had", "that that", "very very"), so never a stutter.
    static let keepRepeat: Set<String> = [
        "had", "that", "is", "no", "very", "really", "so", "bye", "yeah", "yes", "ok", "okay",
        "go", "far", "more", "much", "many", "too", "ha",
    ]
    /// A sentence does not end on these, so a long pause after one is a hesitation.
    static let noEnd: Set<String> = [
        "a", "an", "the", "of", "to", "for", "with", "in", "on", "at", "from", "by", "and", "or",
        "but", "so", "then", "that", "if", "because", "as", "my", "your", "our", "their", "this",
        "these", "those", "is", "are", "was", "were", "i", "we", "you", "they", "be", "very",
        "el", "la", "los", "las", "un", "una", "de", "y", "o", "que", "en", "con", "por", "para",
    ]

    static func clean(_ raw: String) -> String {
        var words = parse(raw)

        // Fillers, and Spanish "Este," opening a sentence.
        var i = 0
        while i < words.count {
            let c = words[i].core.lowercased()
            if fillers.contains(c) || (c == "este" && words[i].comma && (i == 0 || words[i - 1].terminal)) {
                remove(&words, i)
                continue
            }
            i += 1
        }

        // Adjacent repeats ("I, I", "the the"). The earlier copy goes, unless it ended a
        // sentence, is a number ("4 4 7 1"), or doubles on purpose.
        i = 1
        while i < words.count {
            let a = words[i - 1], b = words[i], c = a.core.lowercased()
            if !c.isEmpty && c == b.core.lowercased() && !a.terminal
                && !keepRepeat.contains(c) && !c.allSatisfy(\.isNumber) {
                remove(&words, i - 1)
                continue
            }
            i += 1
        }

        // "you know" and "like" as hedges only where commas set them off — ", you know,",
        // "Like, …". Unpunctuated, each is as often the verb or a comparison
        // ("as you know", "tastes like chicken"), and a word kept is cheaper than one lost.
        i = 0
        while i < words.count {
            let opens = i == 0 || words[i - 1].comma || words[i - 1].terminal
            let c = words[i].core.lowercased()
            if opens, c == "you", i + 1 < words.count, words[i + 1].core.lowercased() == "know", words[i + 1].comma {
                remove(&words, i)
                remove(&words, i)
                continue
            }
            if opens, c == "like", words[i].comma {
                remove(&words, i)
                continue
            }
            i += 1
        }

        // A long pause with no punctuation ends a sentence; capitals follow sentence ends.
        for i in words.indices {
            if words[i].pause >= pauseMs && !words[i].terminal && !noEnd.contains(words[i].core.lowercased()) {
                words[i].trail = stripComma(words[i].trail) + "."
            }
            var core = words[i].core
            let starts = i == 0 || words[i - 1].terminal
            if core == "i" || core.hasPrefix("i'") {
                core = "I" + String(core.dropFirst())
            } else if starts, let f = core.first, f.isLowercase, !core.dropFirst().contains(where: \.isUppercase) {
                core = f.uppercased() + String(core.dropFirst())
            }
            words[i].core = core
        }

        var s = words.map { $0.lead + $0.core + $0.trail }.joined(separator: " ")
        if s.hasSuffix(",") { s = String(s.dropLast()) + "." }
        return s
    }

    /// Splits the transcript into words. A pause marker attaches to the word before it.
    static func parse(_ raw: String) -> [Word] {
        var words: [Word] = []
        for m in raw.matches(of: /\[pause (\d+)ms\]|[^\s\[]+|\S/) {
            if let ms = m.output.1 {
                if !words.isEmpty { words[words.count - 1].pause = max(words[words.count - 1].pause, Int(ms) ?? 0) }
                continue
            }
            let (lead, core, trail) = split(String(m.output.0))
            if core.isEmpty {
                // Bare punctuation (a dash, say) belongs to the word before it.
                if words.isEmpty { words.append(Word(lead: lead + trail, core: "", trail: "")) }
                else { words[words.count - 1].trail += lead + trail }
                continue
            }
            words.append(Word(lead: lead, core: core, trail: trail))
        }
        return words
    }

    /// Removes one word and repairs what the deletion breaks: a sentence end moves to the
    /// previous word, a comma sandwiched around the deleted word goes, and a pause carries over.
    static func remove(_ words: inout [Word], _ i: Int) {
        let w = words[i]
        if i > 0 {
            if w.terminal {
                if !words[i - 1].terminal, let end = w.trail.first(where: { ".?!".contains($0) }) {
                    words[i - 1].trail = stripComma(words[i - 1].trail) + String(end)
                }
            } else if w.comma && words[i - 1].comma {
                words[i - 1].trail.removeLast()
            }
            words[i - 1].pause = max(words[i - 1].pause, w.pause)
        }
        words.remove(at: i)
    }

    static func split(_ token: String) -> (String, String, String) {
        let chars = Array(token)
        func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
        var i = 0
        while i < chars.count && !isWordChar(chars[i]) { i += 1 }
        var j = chars.count
        while j > i && !isWordChar(chars[j - 1]) { j -= 1 }
        return (String(chars[..<i]), String(chars[i..<j]), String(chars[j...]))
    }

    static func stripComma(_ s: String) -> String {
        s.hasSuffix(",") ? String(s.dropLast()) : s
    }

    // MARK: - Self-corrections

    /// "X, no wait, Y" → Y, replacing as many words of X as Y has. Spanish "no,
    /// perdón", "no, digo", "mejor dicho" too. The marker must be set off on both
    /// sides — a clause end before it, and a comma or pause after it or a single
    /// word closing the clause — and must be one only a correction uses: a lone
    /// "sorry", "actually", "wait" or "I mean" is as often an apology or a hedge.
    static let markWords: Set<String> = ["no", "wait", "actually", "sorry", "perdón", "perdon", "digo", "espera", "mejor", "dicho"]
    /// What turns a "no" into a correction: "no wait", "no, sorry", "no, I mean".
    static let afterNo: Set<String> = ["wait", "sorry", "actually", "perdón", "perdon", "espera", "digo", "i"]
    static let pairs: Set<String> = ["scratch that", "or rather", "mejor dicho"]
    static let maxY = 4

    static func resolve(_ text: String) -> String {
        var s = text
        for _ in 0..<5 {
            guard let r = resolveOnce(s), r != s else { break }
            s = r
        }
        return s
    }

    static func tokens(_ s: String) -> [String] {
        s.matches(of: /\[pause \d+ms\]|\S+/).map { String($0.output) }
    }

    static func norm(_ t: String) -> String {
        String(t.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" })
    }

    static func isPause(_ t: String) -> Bool { t.hasPrefix("[pause") }
    static func endsClause(_ t: String) -> Bool { t.last.map { ",.!?".contains($0) } ?? false }
    static func endsSentence(_ t: String) -> Bool { t.last.map { ".!?".contains($0) } ?? false }

    /// A token that can sit inside a correction marker. Two-word markers need both words.
    static func isMark(_ toks: [String], _ m: Int) -> Bool {
        let w = norm(toks[m])
        let next = m + 1 < toks.count ? norm(toks[m + 1]) : ""
        let prev = m > 0 ? norm(toks[m - 1]) : ""
        switch w {
        case "i": return next == "mean"
        case "mean": return prev == "i"
        case "or": return next == "rather"
        case "rather": return prev == "or"
        case "scratch": return next == "that"
        case "that": return prev == "scratch"
        default: return markWords.contains(w)
        }
    }

    static func resolveOnce(_ s: String) -> String? {
        let toks = tokens(s)
        let n = toks.count
        for j in 1..<max(n, 1) where !isPause(toks[j]) && isMark(toks, j) {
            let prev = toks[..<j].last { !isPause($0) } ?? ""
            guard endsClause(prev) else { continue }
            var m = j
            while m < n, !isPause(toks[m]), isMark(toks, m), !(m > j && endsSentence(toks[m - 1])) { m += 1 }
            let run = toks[j..<m].map(norm)
            let correction = run.count > 1 && run[0] == "no" && afterNo.contains(run[1])
                || zip(run, run.dropFirst()).contains { pairs.contains("\($0) \($1)") }
            // A marker that ends a sentence has no Y in it: the next sentence is not a replacement.
            guard correction, !endsSentence(toks[m - 1]) else { continue }
            // Y: the words after the marker, up to a clause end (inclusive) or a pause.
            var y: [String] = []
            var k = m
            while k < n, isPause(toks[k]) { k += 1 }
            let setOff = toks[m - 1].hasSuffix(",") || k > m
            while k < n, !isPause(toks[k]), y.count < maxY {
                y.append(toks[k])
                k += 1
                if endsClause(toks[k - 1]) { break }
            }
            if y.isEmpty || (y.count == maxY && !endsClause(y[y.count - 1])) { continue }
            if y.dropLast().contains(where: endsSentence) { continue }
            guard setOff || (y.count == 1 && endsClause(y[0])) else { continue }
            // X: the last len(Y) words before the marker, not crossing a sentence end.
            var xs: [Int] = []
            var p = j - 1
            while p >= 0 && xs.count < y.count {
                if isPause(toks[p]) { p -= 1; continue }
                if endsSentence(toks[p]) { break }
                xs.append(p)
                p -= 1
            }
            guard xs.count == y.count, let start = xs.min() else { continue }
            if toks[start].first?.isUppercase == true, y[0].first?.isLowercase == true {
                y[0] = y[0].prefix(1).uppercased() + y[0].dropFirst()
            }
            return (Array(toks[..<start]) + y + Array(toks[k...])).joined(separator: " ")
        }
        return nil
    }
}
