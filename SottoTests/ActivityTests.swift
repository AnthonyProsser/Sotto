//
//  ActivityTests.swift
//  SottoTests
//
//  §14.8's idle / not-idle signal: the observable, not the drawn icon. `Activity.shared`
//  is process-wide and the test host is the running app, so the suite is serialised and
//  each test starts from an empty contributor set and puts the app's own back.
//

import Testing
@testable import Sotto

extension SharedState {
@Suite @MainActor
struct ActivityTests {

    private func isolated(_ body: () async throws -> Void) async rethrows {
        let activity = Activity.shared
        let saved = activity.active
        for contributor in Activity.Contributor.allCases { activity.set(contributor, false) }
        defer { for contributor in saved { activity.set(contributor, true) } }
        try await body()
    }

    @Test(arguments: Activity.Contributor.allCases)
    func anyOneContributorMakesSottoNotIdle(_ contributor: Activity.Contributor) async {
        await isolated {
            let activity = Activity.shared
            #expect(activity.isIdle)
            activity.set(contributor, true)
            #expect(!activity.isIdle)
            #expect(activity.active == [contributor])
            activity.set(contributor, false)
            #expect(activity.isIdle)
        }
    }

    @Test func idleOnlyOnceEveryContributorHasCleared() async {
        await isolated {
            let activity = Activity.shared
            for contributor in Activity.Contributor.allCases { activity.set(contributor, true) }
            for contributor in Activity.Contributor.allCases {
                #expect(!activity.isIdle)
                activity.set(contributor, false)
            }
            #expect(activity.isIdle)
        }
    }

    @Test func settingTwiceOrClearingAnUnsetContributorChangesNothing() async {
        await isolated {
            let activity = Activity.shared
            activity.set(.recording, true)
            activity.set(.recording, true)
            activity.set(.cleanup, false)
            #expect(activity.active == [.recording])
            activity.set(.recording, false)
            #expect(activity.isIdle)
        }
    }

    /// §3.1: a speculative warm-up is not the user's work, so the icon must not light for it.
    /// Gated on the live model — unavailable, `prewarm` returns before doing anything and this
    /// would pass without testing the path that matters.
    @Test(.enabled(if: liveCleanupAvailable()))
    func prewarmNeverSetsTheCleanupContributor() async throws {
        try await isolated {
            Cleanup.shared.prewarm()
            #expect(Activity.shared.isIdle)
            try await Task.sleep(for: .milliseconds(500))
            #expect(!Activity.shared.active.contains(.cleanup))
        }
    }
}
}
