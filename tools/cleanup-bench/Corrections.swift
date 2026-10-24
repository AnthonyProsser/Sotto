//
//  Corrections.swift — cleanup-bench helper (corrections direction)
//
//  (a) `resolve`: deterministic token-level resolver for "X, no wait, Y" /
//      "X, actually Y" / "X, I mean Y" / "X, sorry, Y" / "X, scratch that, Y" /
//      "X, or rather Y" and the Spanish "no, perdón" / "digo" / "espera" /
//      "mejor dicho" forms. Replaces the X tail (as many words as Y) with Y.
//  (b) `wording`: the base instructions with the self-correction paragraph rewritten.
//  (c) `withExamples`: the base instructions plus two English correction pairs.
//

import Foundation

enum Corrections {
    static let markWords: Set<String> = ["no", "wait", "actually", "sorry", "perdón", "perdon", "digo", "espera", "mejor", "dicho"]
    static let distinct: Set<String> = ["wait", "sorry", "perdón", "perdon", "digo", "espera", "dicho", "actually", "scratch", "mean", "rather"]
    static let maxY = 4

    static func tokenize(_ s: String) -> [String] {
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
        let nxt = m + 1 < toks.count ? norm(toks[m + 1]) : ""
        let prv = m > 0 ? norm(toks[m - 1]) : ""
        switch w {
        case "i": return nxt == "mean"
        case "mean": return prv == "i"
        case "or": return nxt == "rather"
        case "rather": return prv == "or"
        case "scratch": return nxt == "that"
        case "that": return prv == "scratch"
        default: return markWords.contains(w)
        }
    }

    static func resolveOnce(_ s: String) -> String? {
        let toks = tokenize(s)
        let n = toks.count
        for j in 1..<max(n, 1) where !isPause(toks[j]) && isMark(toks, j) {
            let first = norm(toks[j])
            let prev = toks[..<j].last { !isPause($0) } ?? ""
            guard endsClause(prev) || ["no", "or", "i", "scratch"].contains(first) else { continue }
            var m = j
            while m < n, !isPause(toks[m]), isMark(toks, m), !(m > j && endsSentence(toks[m - 1])) { m += 1 }
            let run = toks[j..<m].map(norm)
            guard !Set(run).isDisjoint(with: distinct), run != ["no"] else { continue }
            // Y: following words up to a clause end (inclusive) or a pause.
            var y: [String] = []
            var k = m
            while k < n, !isPause(toks[k]), y.count < maxY {
                y.append(toks[k]); k += 1
                if endsClause(toks[k - 1]) { break }
            }
            if y.isEmpty || (y.count == maxY && !endsClause(y[y.count - 1])) { continue }
            if y.dropLast().contains(where: endsSentence) { continue }
            // X: the last len(Y) words before the marker, not crossing a sentence end or pause.
            var xs: [Int] = []
            var p = j - 1
            while p >= 0 && xs.count < y.count {
                if isPause(toks[p]) { p -= 1; continue }
                if endsSentence(toks[p]) { break }
                xs.append(p); p -= 1
            }
            guard xs.count == y.count, let start = xs.min() else { continue }
            var ynew = y
            if toks[start].first?.isUppercase == true, ynew[0].first?.isLowercase == true {
                ynew[0] = ynew[0].prefix(1).uppercased() + ynew[0].dropFirst()
            }
            return (Array(toks[..<start]) + ynew + Array(toks[k...])).joined(separator: " ")
        }
        return nil
    }

    /// Applies the resolver until nothing more changes (at most five corrections).
    static func resolve(_ text: String) -> String {
        var s = text
        for _ in 0..<5 {
            guard let r = resolveOnce(s), r != s else { break }
            s = r
        }
        return s
    }

    static let correctionParagraph = """
        SELF-CORRECTIONS are the most important rule. A speaker who revises what they said \
        marks it with words such as "no wait", "actually", "I mean", "sorry", "scratch that", \
        "or rather", or in Spanish "no, perdón", "digo", "espera", "mejor dicho". When that \
        happens, DELETE everything the speaker abandoned, DELETE the marker word or words \
        themselves, and KEEP only the revised version that follows. The output must contain \
        neither the abandoned words nor any marker: "send it Tuesday, no wait, Wednesday" \
        becomes "Send it Wednesday." and "let's meet at three, actually four" becomes "Let's \
        meet at four." The word "actually" used as emphasis ("I actually like it", "it doesn't \
        actually work") is not a correction and stays.

        """

    /// The base prompt with the self-correction paragraph rewritten.
    static func wording(for profile: DictationProfile) -> String {
        let base = Cleanup.instructions(for: profile)
        guard let start = base.range(of: "When the speaker corrects themselves"),
              let end = base.range(of: "Add punctuation and capitalisation.")
        else { return base }
        return base.replacingCharacters(in: start.lowerBound..<end.lowerBound, with: correctionParagraph)
    }

    static func withExamples(for profile: DictationProfile) -> String {
        Cleanup.instructions(for: profile) + """

        Transcript: <transcript>send it Tuesday, no wait, Wednesday</transcript>
        Output: Send it Wednesday.
        Transcript: <transcript>let's meet at three, actually four [pause 900ms]</transcript>
        Output: Let's meet at four.
        """
    }
}
