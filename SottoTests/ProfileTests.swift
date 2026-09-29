//
//  ProfileTests.swift
//  SottoTests
//
//  ProfileStore on an isolated UserDefaults suite (never the real profiles), and
//  the vocabulary reaching the cleanup prompt.
//

import Foundation
import Testing
@testable import Sotto

@MainActor
struct ProfileTests {
    private func makeDefaults() -> UserDefaults {
        let name = "SottoTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test
    func freshStoreSeedsOneDefaultProfile() {
        let store = ProfileStore(defaults: makeDefaults())
        #expect(store.profiles.map(\.name) == ["Default"])
        #expect(store.activeID == store.profiles[0].id)
    }

    @Test
    func addAndDuplicateGetUniqueNamesAndBecomeActive() {
        let store = ProfileStore(defaults: makeDefaults())
        store.add(); store.add()
        #expect(store.profiles.map(\.name) == ["Default", "Untitled", "Untitled 2"])
        #expect(store.active.name == "Untitled 2")
        var source = store.profiles[0]
        source.vocabulary = ["Quenthara"]
        store.update(source)
        store.duplicate(source); store.duplicate(source)
        #expect(store.profiles.suffix(2).map(\.name) == ["Default 2", "Default 3"])
        #expect(store.active.vocabulary == ["Quenthara"])
        #expect(store.active.id != source.id)
        #expect(Set(store.profiles.map(\.id)).count == store.profiles.count)
    }

    @Test
    func lastProfileCannotBeDeleted() {
        let store = ProfileStore(defaults: makeDefaults())
        store.delete(store.profiles[0])
        #expect(store.profiles.count == 1)
    }

    @Test
    func deletingTheActiveProfileFallsBackToAValidOne() {
        let store = ProfileStore(defaults: makeDefaults())
        store.add()
        let doomed = store.active
        store.delete(doomed)
        #expect(store.profiles.count == 1)
        #expect(store.activeID == store.profiles[0].id)
        #expect(store.active.id != doomed.id)
    }

    @Test
    func deletingAnInactiveProfileKeepsTheActiveOne() {
        let store = ProfileStore(defaults: makeDefaults())
        store.add()
        let first = store.profiles[0], active = store.active
        store.delete(first)
        #expect(store.activeID == active.id)
    }

    @Test
    func profilesAndActiveSurviveARelaunch() {
        let defaults = makeDefaults()
        let store = ProfileStore(defaults: defaults)
        store.add()
        var p = store.active
        p.language = .spanish; p.vocabulary = ["Zorbelix"]; p.cleanupEnabled = false
        store.update(p)
        let reloaded = ProfileStore(defaults: defaults)
        #expect(reloaded.profiles == store.profiles)
        #expect(reloaded.activeID == p.id)
        #expect(reloaded.active.vocabulary == ["Zorbelix"])
    }

    @Test
    func staleActiveIDFallsBackToFirstProfile() {
        let defaults = makeDefaults()
        _ = ProfileStore(defaults: defaults)
        defaults.set("gone", forKey: ProfileStore.activeKey)
        let store = ProfileStore(defaults: defaults)
        #expect(store.activeID == store.profiles[0].id)
    }

    @Test
    func profileSavedBeforeLanguageExistedDecodesAsDetect() throws {
        let old = #"{"id":"a","name":"Old","cleanupEnabled":true,"cleanupInstructions":"","vocabulary":["x"]}"#
        let p = try JSONDecoder().decode(DictationProfile.self, from: Data(old.utf8))
        #expect(p.language == .detect)
        #expect(p.vocabulary == ["x"])
        let round = try JSONDecoder().decode(DictationProfile.self, from: JSONEncoder().encode(p))
        #expect(round == p)
    }

    @Test
    func vocabularyReachesTheCleanupPrompt() {
        let p = DictationProfile(name: "T", vocabulary: ["Quenthara", "Zorbelix"])
        let text = Cleanup.instructions(for: p)
        #expect(text.contains("Quenthara, Zorbelix"))
        #expect(!Cleanup.instructions(for: DictationProfile(name: "E")).contains("Prefer these spellings"))
    }
}
