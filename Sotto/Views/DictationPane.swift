//
//  DictationPane.swift
//  Sotto
//
//  Settings → Dictation. Storage only; slice 11 fills in the rest of §8.1.
//

import SwiftUI

/// **The storage half of §8.1, and nothing else yet.**
///
/// `AudioHistoryEnabled` and `AudioHistoryRingLimit` have been live
/// `UserDefaults` keys since slice 5 with no control anywhere — the pane that was
/// meant to hold them is slice 11's, and until 2026-09-18 this section was a
/// `ContentUnavailableView` stub. Retention stopped being a value nobody could
/// see the moment its default became "never delete" (`DECISIONS.md`), so it gets
/// a surface now rather than waiting for the slice.
///
/// Everything else §8.1 lists — cleanup on/off, cleanup instructions, the VAD
/// threshold, custom vocabulary, profiles — is still slice 11's, and one of them
/// (cleanup reasoning) is still an open question. Do not fill them in passing.
///
/// `Form` + `.formStyle(.grouped)` is the house idiom, not a choice made here:
/// it is macOS's own System-Settings styling, and `ModelsPane` and
/// `AppearancePane` both wore it before they were deleted.
struct DictationPane: View {
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
        .navigationTitle("Dictation")
        .navigationSubtitle("")
    }
}
