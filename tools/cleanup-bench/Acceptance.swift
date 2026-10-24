//
//  Acceptance.swift — cleanup-bench, the `guard` candidate
//
//  Replaces Cleanup.sanitize. A model output is accepted only when it is the
//  transcript with fillers, stutters, abandoned words and self-corrections
//  removed, punctuation added, and contractions re-contracted; any other
//  change (insertion, rewrite, answer, unexplained deletion, sentence break
//  with no pause in the speech) is refused and a deterministic clean of the
//  transcript is inserted instead. Ported 1:1 from analysis/guard2.py.
//

import Foundation

/// Set by `Acceptance.postprocess`: true when the output was refused and the fallback inserted.
nonisolated(unsafe) var guardRefused = false

struct Tok {
    var w: String
    var end = false      // sentence-ending punctuation follows
    var pause = false    // a pause marker follows
    var comma = false    // a comma follows
}

enum Acceptance {
    static let fillers: Set<String> = ["um", "uh", "uhm", "er", "erm", "eh", "hmm", "mm", "ah"]
    static let corrMark: Set<String> = ["wait", "perdón", "espera", "digo", "dicho"]
    static let contractions: [(String, String)] = [
        ("don't", "do not"), ("doesn't", "does not"), ("didn't", "did not"), ("isn't", "is not"),
        ("aren't", "are not"), ("wasn't", "was not"), ("weren't", "were not"), ("can't", "cannot"),
        ("won't", "will not"), ("wouldn't", "would not"), ("shouldn't", "should not"),
        ("couldn't", "could not"), ("haven't", "have not"), ("hasn't", "has not"), ("hadn't", "had not"),
        ("it's", "it is"), ("that's", "that is"), ("there's", "there is"), ("here's", "here is"),
        ("what's", "what is"), ("who's", "who is"), ("let's", "let us"), ("i'm", "i am"),
        ("i've", "i have"), ("i'll", "i will"), ("i'd", "i would"), ("we're", "we are"),
        ("they're", "they are"), ("you're", "you are"), ("we've", "we have"), ("they've", "they have"),
        ("you've", "you have"), ("we'll", "we will"), ("they'll", "they will"), ("you'll", "you will"),
        ("he's", "he is"), ("she's", "she is"), ("we'd", "we would"), ("you'd", "you would"),
        ("they'd", "they would"), ("gonna", "going to"), ("wanna", "want to"),
    ]

    static func postprocess(_ output: String, _ input: String) throws -> String {
        if let text = check(output, input) { guardRefused = false; return text }
        guardRefused = true
        return fallback(input)
    }

    /// The model's text, repaired, if it passes; nil if refused.
    static func check(_ output: String, _ inp: String) -> String? {
        let text = repairContractions(sanitizePre(output), inp)
        let t = tokens(inp), o = tokens(text)
        let matched = lcs(t.map { $0.w }, o.map { $0.w })
        if matched.count != o.count { return nil }                       // insertion or rewrite
        for (i, j) in matched where o[j].end && !(t[i].end || t[i].pause) { return nil }
        let marks = correctionMarkers(t)
        let kept = Set(matched.map { $0.0 })
        for i in t.indices where !kept.contains(i) && !deletable(t, i, marks) { return nil }
        return text
    }

    /// Deterministic clean of the transcript; what is inserted when the model is refused.
    static func fallback(_ inp: String) -> String {
        var s = unmark(inp)
        s = sub(s, #"\s*,?\s*\b(?:um|uh|uhm|er|erm|eh|hmm|mm|ah)\b\s*,?"#, " ")
        s = sub(s, #"\s*,\s*like\s*,"#, " ")
        s = sub(s, #"\s*,\s*like\b"#, "")
        s = sub(s, #"\blike\s*,\s*"#, " ")
        s = sub(s, #"\b(\w+),?\s+\1\b"#, "$1")
        s = sub(s, #"\s+"#, " ").trimmingCharacters(in: .whitespacesAndNewlines)
        s = sub(s, #"\s+([,.?!])"#, "$1")
        s = sub(s, #"^[,\s]+"#, "")
        return capitalise(s)
    }

    // MARK: - Model output, before comparison

    static func sanitizePre(_ output: String) -> String {
        var text = sub(output, #"</?transcript>|^\s*Output:"#, "", .anchorsMatchLines)
        text = sub(text, #"\s*\[?\s*pause\s*\d*\s*ms\s*\]?"#, "")
        text = sub(text, #"\s*\b\d{2,5}\s*ms\b"#, "")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let m = regex(#"^(?:um|uh|er|eh)\b[,.]?\s+"#, .caseInsensitive).firstMatch(in: text, range: nsRange(text)) {
            let rest = (text as NSString).substring(from: m.range.location + m.range.length)
            text = String(rest.prefix(1)).uppercased() + String(rest.dropFirst())
        }
        return text
    }

    /// Re-contracts an expansion when the input spoke the contraction and never the expansion.
    static func repairContractions(_ text: String, _ inp: String) -> String {
        let plain = unmark(inp)
        let inWords = Set(words(plain))
        let inText = plain.lowercased()
        var text = text
        for (con, exp) in contractions where inWords.contains(con) {
            let re = phraseRE(exp)
            if matches(re, inText) { continue }
            text = replaceEach(text, re) { match in
                match.first?.isUppercase == true ? String(con.prefix(1)).uppercased() + String(con.dropFirst()) : con
            }
        }
        return text
    }

    // MARK: - Tokens and alignment

    static let tokenRE = regex(#"\[pause\s*\d+\s*ms\]|[\w']+|[.?!,;:]"#, .caseInsensitive)

    /// Words lowercased, with sentence-end, pause and comma flags on the word they follow.
    static func tokens(_ marked: String) -> [Tok] {
        var out: [Tok] = []
        let ns = marked as NSString
        for m in tokenRE.matches(in: marked, range: NSRange(location: 0, length: ns.length)) {
            let s = ns.substring(with: m.range)
            if s.hasPrefix("[") {
                if !out.isEmpty { out[out.count - 1].pause = true }
            } else if s.count == 1 && ".?!,;:".contains(s) {
                guard !out.isEmpty else { continue }
                if ".?!".contains(s) { out[out.count - 1].end = true }
                if s == "," { out[out.count - 1].comma = true }
            } else {
                out.append(Tok(w: s.lowercased()))
            }
        }
        return out
    }

    /// Longest-common-subsequence alignment as (index in a, index in b) pairs.
    static func lcs(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        let n = a.count, m = b.count
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var i = 0, j = 0
        var pairs: [(Int, Int)] = []
        while i < n && j < m {
            if a[i] == b[j] { pairs.append((i, j)); i += 1; j += 1 }
            else if dp[i + 1][j] >= dp[i][j + 1] { i += 1 }
            else { j += 1 }
        }
        return pairs
    }

    /// Words a pass may remove from the transcript: fillers, stutters, abandoned words near a correction.
    static func deletable(_ t: [Tok], _ i: Int, _ marks: [Int]) -> Bool {
        let w = t[i].w
        let prev = i > 0 ? t[i - 1].w : ""
        let next = i + 1 < t.count ? t[i + 1].w : ""
        if fillers.contains(w) { return true }
        if w == "like" && (t[i].comma || (i > 0 && t[i - 1].comma)) { return true }
        if w == "know" && prev == "you" { return true }
        if w == "you" && next == "know" { return true }
        if w == "mean" && prev == "i" { return true }
        if w == "este" && t[i].comma { return true }
        if prev == w { return true }                                     // I, I
        for k in (i + 1)..<max(i + 1, min(t.count, i + 4)) {             // uh I, I
            if t[k].w == w { return true }
            if !fillers.contains(t[k].w) { break }
        }
        return marks.contains { abs(i - $0) <= 4 }                       // within 4 words of a correction
    }

    static func correctionMarkers(_ t: [Tok]) -> [Int] {
        var idx: [Int] = []
        for k in t.indices {
            let w = t[k].w
            let next = k + 1 < t.count ? t[k + 1].w : ""
            let prev = k > 0 ? t[k - 1].w : ""
            if corrMark.contains(w)
                || (w == "actually" && (next == "no" || t[k].comma || (k > 0 && t[k - 1].comma)))
                || (w == "mean" && prev == "i") || (w == "rather" && prev == "or")
                || (w == "no" && (corrMark.contains(next) || next == "actually")) {
                idx.append(k)
            }
        }
        return idx
    }

    // MARK: - Strings

    static func unmark(_ t: String) -> String {
        sub(t, #"\s*\[pause [0-9]+ms\]"#, "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let wordRE = regex(#"[\w']+"#)

    static func words(_ t: String) -> [String] {
        let s = unmark(t).lowercased()
        let ns = s as NSString
        return wordRE.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    static func phraseRE(_ p: String) -> NSRegularExpression {
        let body = p.components(separatedBy: " ").map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: #"\s+"#)
        return regex(#"(?<![\w'])"# + body + #"(?![\w'])"#, .caseInsensitive)
    }

    /// Capitalises the first word, and each word after . ? ! and whitespace.
    static func capitalise(_ s: String) -> String {
        var out = ""
        var state = 2   // 2: a word character here starts a sentence; 1: after . ? ! with no space yet; 0: neither
        for ch in s {
            if ch.isWhitespace {
                out.append(ch)
                if state == 1 { state = 2 }
                continue
            }
            if state == 2 && (ch.isLetter || ch.isNumber) { out += ch.uppercased() } else { out.append(ch) }
            state = ".?!".contains(ch) ? 1 : 0
        }
        return out
    }

    static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    static func nsRange(_ s: String) -> NSRange { NSRange(location: 0, length: (s as NSString).length) }

    static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: nsRange(s)) != nil
    }

    /// Case-insensitive regex substitution; `template` uses $1 for groups.
    static func sub(_ s: String, _ pattern: String, _ template: String, _ extra: NSRegularExpression.Options = []) -> String {
        regex(pattern, extra.union(.caseInsensitive)).stringByReplacingMatches(in: s, range: nsRange(s), withTemplate: template)
    }

    /// Replaces each match with `f(match)`.
    static func replaceEach(_ s: String, _ re: NSRegularExpression, _ f: (String) -> String) -> String {
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: s, range: nsRange(s)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += f(ns.substring(with: m.range))
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }
}
