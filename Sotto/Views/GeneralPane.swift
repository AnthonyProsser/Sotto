//
//  GeneralPane.swift
//  Sotto
//
//  Settings → General. The retention section moved here from DictationPane
//  (Anthony, 2026-09-24, DECISIONS.md): storage policy is not a dictation
//  behavior, and Dictation keeps profiles only.
//

import SwiftUI

/// General owns everything that is not a dictation behavior: audio retention
/// today, the §8.4 update-check row when the updater stops being a stub.
/// `Form` + `.formStyle(.grouped)` is the house idiom: it is macOS's own
/// System-Settings styling.
struct GeneralPane: View {
    /// Written straight to the keys `AudioHistory` reads, so the pane and the
    /// writer cannot drift into two sources of truth. `@AppStorage` falls back to
    /// its default only when the key is absent, which is the same rule
    /// `AudioHistory.record` applies with `?? defaultRingLimit`.
    @AppStorage(AudioHistory.enabledKey) private var storeAudio = true
    @AppStorage(AudioHistory.ringLimitKey) private var ringLimit = AudioHistory.defaultRingLimit

    var body: some View {
        Form {
            Section {
                Toggle("Store audio recordings", isOn: $storeAudio)

                Picker("Keep", selection: $ringLimit) {
                    Text("All recordings").tag(0)
                    Divider()
                    // Not a scale anyone locked — the old ring of 10 plus three
                    // round steps above it, which is what a retention picker
                    // elsewhere on the machine offers. One edit to change.
                    ForEach([10, 25, 50, 100], id: \.self) { count in
                        Text("Last \(count)").tag(count)
                    }
                }
                .disabled(!storeAudio)
            } footer: {
                // The number is the one fact that makes "All recordings" a
                // decision rather than a shrug.
                Text(
                    storeAudio
                    ? "Opus at 24 kbps — about 0.18 MB a minute, or 1 GB per 100 hours. Pinned recordings are never deleted."
                    : "Dictation still works; nothing is written to disk."
                )
            }
        }
        .formStyle(.grouped)
        // The window title, not a toolbar item (`DECISIONS.md`, 2026-09-03):
        // macOS 26 draws a bordered capsule around `.navigation` items. The
        // subtitle is cleared so the Audio pane's does not leak through.
        .navigationTitle("General")
        .navigationSubtitle("")
    }
}
