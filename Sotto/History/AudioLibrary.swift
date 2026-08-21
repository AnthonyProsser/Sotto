//
//  AudioLibrary.swift
//  Sotto
//
//  Slice 6. What the Audio workspace reads — §10.2's recording list, over the
//  folders slice 5 writes.
//

import AVFoundation
import Foundation
import Observation

/// The Audio mode's model: slice 5's folders, loaded, sorted, filtered, and
/// annotated with the two things the sidebar row needs that the sidecar does not
/// store.
///
/// **Nothing here is a second store.** `AudioHistory` owns the on-disk shape and
/// every write still goes through it; this type reads, caches for the window's
/// lifetime, and reloads on `.audioHistoryDidChange`. Two sources of truth for
/// what is on disk is the failure mode, and the ring evicting a recording behind
/// the window's back is exactly when it would show.
@MainActor
@Observable
final class AudioLibrary {
    static let shared = AudioLibrary()

    /// One entry plus what the pane needs and the sidecar does not carry.
    struct Recording: Identifiable, Equatable, Sendable {
        var entry: AudioEntry
        var folder: URL

        /// **Derived, never stored.** The build order asks the sidebar row for a
        /// duration and `AudioEntry` has no field for one — slice 5 froze that
        /// schema deliberately, and a fourth slot would have to be written into
        /// every existing entry to be trustworthy. The CAF header carries it
        /// exactly, and reading it costs a file open rather than a decode.
        var duration: TimeInterval

        var id: String { entry.id }
        var created: Date { entry.created }
        var pinned: Bool { entry.pinned }
        var languages: [String] { entry.languages }
        var words: [Transcription.Draft.Word] { entry.words }
        var audio: URL { folder.appendingPathComponent("audio.caf") }

        /// What the pane reads. The pause markers come off here (§4.6).
        var raw: String { AudioHistory.unmark(entry.raw) }

        /// `nil` until slice 11 runs a cleanup pass. The toggle in the pane is
        /// disabled while it is, per §14.7 — a control the user can see, with the
        /// reason in its tooltip.
        var cleaned: String? { entry.cleaned }

        /// **The transcript is the title**, truncated by the row rather than by a
        /// word count chosen here. There is no title field and inventing one would
        /// mean picking a length; `lineLimit(1)` is the system doing it against the
        /// actual sidebar width, in every language.
        var title: String {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? String(localized: "Recording") : trimmed
        }

        var durationLabel: String { AudioLibrary.clock(duration) }

        func matches(_ query: String) -> Bool {
            guard !query.isEmpty else { return true }
            if raw.localizedStandardContains(query) { return true }
            return cleaned?.localizedStandardContains(query) ?? false
        }
    }

    private(set) var recordings: [Recording] = []
    private(set) var isLoaded = false

    var selection: Recording.ID?
    var search = ""

    /// **Slice 14's slot, designed here and produced by nothing yet** (§14.3, and
    /// the build order's last design item for this slice). A file transcription
    /// that fails has no HUD to fail into — the import is started from this window
    /// and the message waits in this pane whether or not it is frontmost.
    var failure: String?

    private init() {
        NotificationCenter.default.addObserver(
            forName: .audioHistoryDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// mm:ss, and h:mm:ss once an import is long enough to need it.
    /// `Duration.formatted` is the system's formatter, so the separator and the
    /// digits localise on their own. **One definition** — the row, the header, the
    /// transport, and the seek hint all read it, and four private copies of this
    /// is exactly what `CLAUDE.md` §0.3 names.
    nonisolated static func clock(_ seconds: TimeInterval) -> String {
        let value = max(0, seconds)
        return Duration.seconds(value).formatted(
            .time(pattern: value >= 3600 ? .hourMinuteSecond : .minuteSecond)
        )
    }

    // MARK: - Reading

    /// **Pinned first, then newest first.** §10.2 states the order for the chat
    /// list and says only "recording list" here; the two sidebars are the same
    /// control in two modes, so they order the same way. Pinning already means
    /// "do not evict this" (§9.2) — floating it is the same claim spatially.
    var visible: [Recording] { Self.ordered(recordings, matching: search) }

    /// The rule itself, separated from the singleton's state so it can be checked
    /// against a fixture rather than against whatever is on disk.
    nonisolated static func ordered(_ recordings: [Recording], matching query: String) -> [Recording] {
        recordings
            .filter { $0.matches(query) }
            .sorted {
                $0.pinned == $1.pinned ? $0.created > $1.created : $0.pinned
            }
    }

    var selected: Recording? {
        selection.flatMap { id in recordings.first { $0.id == id } }
    }

    func refresh() {
        let root = AudioHistory.root
        Task.detached(priority: .userInitiated) {
            let loaded = Self.read(root)
            await MainActor.run { self.apply(loaded) }
        }
    }

    private func apply(_ loaded: [Recording]) {
        recordings = loaded
        isLoaded = true
        // The ring can evict what was selected while the window was closed.
        if let selection, !loaded.contains(where: { $0.id == selection }) {
            self.selection = nil
        }
    }

    // MARK: - Writing

    func togglePin(_ recording: Recording) {
        try? AudioHistory.setPinned(!recording.pinned, id: recording.id, in: AudioHistory.root)
        refresh()
    }

    /// **Manual delete extends §9.2**, which gives retention and a pin flag and no
    /// way to remove one recording by hand (Anthony, 2026-08-20, `DECISIONS.md`).
    /// The folder goes, audio and sidecar together — a sidecar with no audio would
    /// render as a playable recording that cannot play.
    func delete(_ recording: Recording) {
        if AudioPlayback.shared.id == recording.id { AudioPlayback.shared.stop() }
        try? FileManager.default.removeItem(at: recording.folder)
        if selection == recording.id { selection = nil }
        refresh()
    }

    // MARK: -

    nonisolated private static func read(_ root: URL) -> [Recording] {
        guard let entries = try? AudioHistory.entries(in: root) else { return [] }
        return entries.map { entry in
            let folder = root.appendingPathComponent(entry.id, isDirectory: true)
            return Recording(
                entry: entry,
                folder: folder,
                duration: duration(of: folder.appendingPathComponent("audio.caf"))
            )
        }
    }

    /// Header read, not a decode. `AVAudioFile` reports the Opus stream's frame
    /// count and rate without touching the packets.
    nonisolated private static func duration(of url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }
}
