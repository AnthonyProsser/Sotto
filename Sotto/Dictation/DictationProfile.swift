//
//  DictationProfile.swift
//  Sotto
//
//  Slice 11. All dictation settings live in profiles — sotto-spec.md §8.1, as
//  trimmed by DECISIONS.md: no STT picker (Apple Speech only), no cleanup model
//  picker (SystemLanguageModel or off), no context slider (the Apple model has no
//  weights or KV for an estimate), no language picker (the locale resolves from
//  the system). What remains: cleanup on/off, reasoning, instructions, vocabulary.
//

import Foundation
import Observation

/// One named bundle of dictation behavior. Codable so the store is JSON in
/// UserDefaults; Sendable so the dictation path can read the active one.
struct DictationProfile: Codable, Sendable, Identifiable, Equatable {
    var id: String
    var name: String

    /// §8.1 "Cleanup enabled". Off is the Verbatim behavior: raw text in, raw
    /// text out, no model pass. The fallback transcriber's locales (§5) have no
    /// native punctuation, so off means unpunctuated there — said in the pane,
    /// not discovered as a bug.
    var cleanupEnabled: Bool

    /// §8.1 "Cleanup instructions". Appended after the base cleanup prompt.
    var cleanupInstructions: String

    /// §4.8's term list. There is no decoder to inject it into on the Apple
    /// path, so it rides the cleanup prompt as preferred spellings
    /// (DECISIONS.md) — which is also why it does nothing when cleanup is off.
    var vocabulary: [String]

    init(
        id: String = UUID().uuidString,
        name: String,
        cleanupEnabled: Bool = true,
        cleanupInstructions: String = "",
        vocabulary: [String] = []
    ) {
        self.id = id
        self.name = name
        self.cleanupEnabled = cleanupEnabled
        self.cleanupInstructions = cleanupInstructions
        self.vocabulary = vocabulary
    }
}

/// The list and the active id. One store, read by the gesture path, the menu
/// switcher, and the pane — the same "no second source of truth" rule the
/// retention keys follow in GeneralPane.
@MainActor
@Observable
final class ProfileStore {
    static let shared = ProfileStore()

    private static let profilesKey = "DictationProfiles.v1"
    private static let activeKey = "ActiveDictationProfileID"

    var profiles: [DictationProfile] {
        didSet { save() }
    }

    var activeID: String {
        didSet { UserDefaults.standard.set(activeID, forKey: Self.activeKey) }
    }

    /// The profile the gesture path, the import sheet, and the switcher read.
    /// Falls back to the first profile rather than trapping when the stored id
    /// names a deleted profile.
    var active: DictationProfile {
        profiles.first { $0.id == activeID } ?? profiles[0]
    }

    private init() {
        let loaded: [DictationProfile]
        if let data = UserDefaults.standard.data(forKey: Self.profilesKey),
           let decoded = try? JSONDecoder().decode([DictationProfile].self, from: data),
           !decoded.isEmpty
        {
            loaded = decoded
        } else {
            // One seed, not presets: Anthony chose full-custom over shipped
            // profiles, so a fresh install starts with a blank Default and the
            // Add/Duplicate controls do the rest.
            loaded = [DictationProfile(name: "Default")]
        }
        profiles = loaded
        let stored = UserDefaults.standard.string(forKey: Self.activeKey)
        activeID = loaded.contains { $0.id == stored } ? stored! : loaded[0].id
    }

    func update(_ profile: DictationProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index] = profile
    }

    func add() {
        let profile = DictationProfile(name: unusedName(basedOn: "Untitled"))
        profiles.append(profile)
        activeID = profile.id
    }

    func duplicate(_ profile: DictationProfile) {
        var copy = profile
        copy.id = UUID().uuidString
        copy.name = unusedName(basedOn: profile.name)
        profiles.append(copy)
        activeID = copy.id
    }

    /// The last profile cannot go: the gesture path reads `active`
    /// unconditionally, and zero profiles is a state with no behavior.
    func delete(_ profile: DictationProfile) {
        guard profiles.count > 1 else { return }
        profiles.removeAll { $0.id == profile.id }
        if activeID == profile.id { activeID = profiles[0].id }
    }

    private func unusedName(basedOn root: String) -> String {
        let taken = Set(profiles.map(\.name))
        if !taken.contains(root) { return root }
        var n = 2
        while taken.contains("\(root) \(n)") { n += 1 }
        return "\(root) \(n)"
    }

    private func save() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: Self.profilesKey)
        }
        if !profiles.contains(where: { $0.id == activeID }), let first = profiles.first {
            activeID = first.id
        }
    }
}
