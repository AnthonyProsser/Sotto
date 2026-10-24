//
//  Shims.swift — cleanup-bench
//
//  The three app types `Cleanup.swift` reaches for, cut down to what it calls,
//  so the bench compiles the shipping file rather than a copy of it.
//

import Foundation

@MainActor
final class Activity {
    static let shared = Activity()
    enum Contributor { case cleanup }
    func set(_ contributor: Contributor, _ isActive: Bool) {}
}

enum AudioHistory {
    static func unmark(_ text: String) -> String {
        text.replacing(/\s*\[pause [0-9]+ms\]/, with: "")
    }
}

enum Transcription {
    struct Draft {
        struct Word { let text: String; let start: TimeInterval }
        struct Pause { let start: TimeInterval; let duration: TimeInterval }
    }
}
