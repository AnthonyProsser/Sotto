//
//  FastPath.swift — cleanup-bench (fastpath candidate)
//
//  Deterministic cleanup with no model call. Mirrors fastref.py in the scratch
//  folder line for line; the Python is the reference and this must agree on every
//  corpus entry.
//

import Foundation

enum FastPath {
    struct Word {
        var lead: String
        var core: String
        var trail: String
        var pause = 0

        var terminal: Bool { trail.contains { ".?!".contains($0) } }
        var comma: Bool { trail.hasSuffix(",") }
    }

    static let pauseMs = 600
    static let fillers: Set<String> = ["um", "uh", "uhm", "umm", "erm", "er", "eh", "hmm", "mm", "em"]
    /// Words before a "like" that make it a verb or a comparison, so it stays.
    static let likeKeepPrev: Set<String> = [
        "look", "looks", "looked", "looking", "things", "stuff", "i", "you",
        "don't", "do", "we", "they", "i'd", "you'd", "they're", "maybe",
        "feel", "feels", "felt", "seem", "seems", "sounds",
        "would", "more", "something", "anything", "nothing", "be", "being", "been",
    ]

    /// "just like" and "of like" are comparisons only before one of these: "just like the old ones".
    static let likeCompare: Set<String> = ["of", "just"]
    static let likeObject: Set<String> = [
        "the", "a", "an", "those", "these", "that", "this", "my", "your", "his", "her", "their",
        "our", "it", "him", "them", "me", "us",
    ]
    /// A sentence does not end on these, so a long pause after one is a hesitation, not a period.
    static let noEnd: Set<String> = [
        "a", "an", "the", "of", "to", "for", "with", "in", "on", "at", "from", "by", "and", "or",
        "but", "so", "then", "that", "if", "because", "as", "my", "your", "our", "their", "this",
        "these", "those", "is", "are", "was", "were", "i", "we", "you", "they", "be", "very",
        "el", "la", "los", "las", "un", "una", "de", "y", "o", "que", "en", "con", "por", "para",
    ]

    static func clean(_ raw: String) -> String {
        var words = parse(raw)

        // 1. Fillers, and Spanish "Este," opening a sentence.
        var i = 0
        while i < words.count {
            let c = words[i].core.lowercased()
            if fillers.contains(c) || (c == "este" && words[i].comma && (i == 0 || words[i - 1].terminal)) {
                remove(&words, i)
                continue
            }
            i += 1
        }

        // 2. Adjacent repeats ("I, I", "the the"). The earlier copy goes, unless it ended a sentence.
        i = 1
        while i < words.count {
            let a = words[i - 1], b = words[i]
            if !a.core.isEmpty && a.core.lowercased() == b.core.lowercased() && !a.terminal {
                remove(&words, i - 1)
                continue
            }
            i += 1
        }

        // 3. "you know" as a hedge, only where punctuation sets it off.
        i = 0
        while i < words.count - 1 {
            let a = words[i], b = words[i + 1]
            if a.core.lowercased() == "you" && b.core.lowercased() == "know"
                && (a.comma || b.comma || i == 0 || words[i - 1].comma || words[i - 1].terminal) {
                remove(&words, i)
                remove(&words, i)
                continue
            }
            i += 1
        }

        // 4. "like": kept as a verb, a comparison, or "like that"; dropped as a hedge.
        i = 0
        while i < words.count {
            if words[i].core.lowercased() == "like" {
                let prev = i > 0 ? words[i - 1] : nil
                let next = i + 1 < words.count ? words[i + 1] : nil
                let compares = prev.map { likeCompare.contains($0.core.lowercased()) && !$0.comma } ?? false
                    && !words[i].comma && (next.map { likeObject.contains($0.core.lowercased()) } ?? false)
                let keep = compares || (prev.map { likeKeepPrev.contains($0.core.lowercased()) } ?? false)
                    || (next.map { $0.core.lowercased() == "that" } ?? false)
                    || (prev.map { $0.comma && !words[i].comma } ?? false)
                // "like it is", "like they were": a comparison clause.
                let clause = i + 2 < words.count && !words[i].comma && !words[i + 1].comma
                    && ["is", "was", "are", "were", "does", "did", "do"].contains(words[i + 2].core.lowercased())
                if !keep && !clause {
                    remove(&words, i)
                    continue
                }
            }
            i += 1
        }

        // 5. A long pause with no punctuation ends a sentence. Capitals follow sentence ends.
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
                if !words[i - 1].terminal {
                    let end = w.trail.first { ".?!".contains($0) }!
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
}
