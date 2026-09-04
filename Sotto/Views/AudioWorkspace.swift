//
//  AudioWorkspace.swift
//  Sotto
//
//  Slice 6. The Audio half of §10.2 — recording list, playback, and the
//  clicked-word seek §9.3 is built around.
//

import AppKit
import SwiftUI

// MARK: - Sidebar

/// §10.2's recording list. The search field that filters it is `MainWindowView`'s
/// — `.searchable(placement: .sidebar)` renders at the top of the sidebar column
/// whatever depth it is written at, so applying it here made the field appear and
/// disappear with the mode and the Chat/Audio pill jumped underneath it. **Scoping
/// is the binding, not the presence**: one field, one text per mode, results that
/// never mix (§10.2).
struct AudioSidebar: View {
    @Bindable var library: AudioLibrary

    @State private var pendingDelete: AudioLibrary.Recording?

    var body: some View {
        VStack(spacing: 0) {
            transcribeFile
            list
        }
    }

    /// **The sidebar's action, not the detail pane's** (2026-08-23,
    /// `DECISIONS.md`). Spec §10.2 lists `Transcribe File…` among the Audio
    /// mode's *detail* controls, which put it beside the pin on whichever
    /// recording happened to be selected — an import starts a new entry rather
    /// than doing anything to that one. It takes the slot slice 10's New Chat
    /// will take on the other mode, which is the action it is the twin of.
    ///
    /// Slice 14 builds it; until then §14.7's first pattern, the system disabled
    /// state with the reason in the tooltip.
    private var transcribeFile: some View {
        Button {} label: {
            Label("Transcribe File…", systemImage: "waveform.badge.plus")
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(true)
        .help("File transcription arrives in a later build.")
        .padding(.horizontal)
        // Matches `ChatSidebar.newChat` — one control in two modes (§10.2).
        .padding(.bottom, 14)
    }

    private var list: some View {
        List(library.visible, selection: $library.selection) { recording in
            RecordingRow(recording: recording)
                .tag(recording.id)
                .contextMenu {
                    Button(recording.pinned ? "Unpin" : "Pin") {
                        library.togglePin(recording)
                    }
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([recording.folder])
                    }
                    Divider()
                    Button("Delete…", role: .destructive) {
                        pendingDelete = recording
                    }
                }
        }
        .listStyle(.sidebar)
        .overlay { emptyState }
        // The system's own destructive-action sheet. **This is the one modal in
        // Sotto and it is not the kind §2 rules out** — that rule is about a
        // failure interrupting work the user did not start; this is a question
        // asked because the user just pressed Delete, and the answer is
        // unrecoverable. Manual delete extends §9.2 (`DECISIONS.md`, 2026-08-20).
        .confirmationDialog(
            "Delete this recording?",
            isPresented: .init(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { recording in
            Button("Delete", role: .destructive) { library.delete(recording) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The audio and its transcript are removed from disk. This cannot be undone.")
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if library.visible.isEmpty {
            if !library.search.isEmpty {
                ContentUnavailableView.search(text: library.search)
            } else {
                ContentUnavailableView(
                    "No Recordings",
                    systemImage: "waveform",
                    description: Text("Dictations you record are kept here.")
                )
            }
        }
    }
}

/// Title, date, duration, language, pin — the build order's five, in the order it
/// names them. The title is the transcript itself, truncated by the row.
struct RecordingRow: View {
    let recording: AudioLibrary.Recording

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text(recording.title)
                    .lineLimit(1)
                if recording.pinned {
                    Image(systemName: "pin.fill")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Pinned")
                }
            }

            HStack {
                Text(recording.created.formatted(date: .abbreviated, time: .shortened))
                Text(recording.durationLabel)
                    .monospacedDigit()
                // **Nothing until slice 11 fills `languages`.** The badge is drawn
                // and rendered conditionally rather than shown empty: a chip
                // reading "—" would assert that the language is unknown, when in
                // fact nothing has looked yet.
                ForEach(recording.languages, id: \.self) { LanguageBadge(code: $0) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct LanguageBadge: View {
    let code: String

    var body: some View {
        Text(Locale(identifier: code).language.languageCode?.identifier.uppercased() ?? code)
            .font(.caption2)
            .padding(.horizontal, 4)
            .background(Capsule().fill(.quaternary))
    }
}

// MARK: - Detail

struct AudioDetail: View {
    @Bindable var library: AudioLibrary

    private var playback: AudioPlayback { .shared }

    /// Raw is the default because raw is the transcript that has timings —
    /// `words` indexes it, so it is the side where clicking a word seeks. Cleaned
    /// arrives in slice 11 and is text only.
    @State private var showingCleaned = false

    var body: some View {
        VStack(spacing: 0) {
            if let failure = library.failure {
                FailureBanner(message: failure) { library.failure = nil }
                Divider()
            }

            if let recording = library.selected {
                content(recording)
            } else {
                ContentUnavailableView {
                    Label("No Recording Selected", systemImage: "waveform")
                } description: {
                    Text("Choose a recording to play it and read its transcript.")
                }
            }
        }
        .navigationTitle(library.selected?.title ?? "Audio")
        .navigationSubtitle(subtitle)
        .toolbar {
            if let recording = library.selected {
                ToolbarItem(placement: .primaryAction) { pinButton(recording) }
            }
        }
        .onChange(of: library.selection, initial: true) {
            if let recording = library.selected {
                playback.load(recording)
                showingCleaned = false
            } else {
                playback.stop()
            }
        }
        .onDisappear { playback.stop() }
    }

    private func content(_ recording: AudioLibrary.Recording) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !recording.languages.isEmpty {
                // The detected-language badges lived under the in-content
                // title; the title moved to the window bar (Slice 10) and
                // `.navigationSubtitle` is text only, so the badges stay here
                // as a thin row above the transport.
                HStack(spacing: 4) {
                    ForEach(recording.languages, id: \.self) { LanguageBadge(code: $0) }
                }
                .padding([.horizontal, .top])
            }
            PlaybackBar(recording: recording)
                .padding([.horizontal, .top])
                .padding(.bottom)
            Divider()
            transcriptControls(recording)
            ScrollView {
                TranscriptBody(
                    words: recording.words,
                    text: shownText(recording),
                    seekable: !showingCleaned
                ) { playback.seek(to: $0) }
                .padding(.horizontal)
                .padding(.bottom)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// The recording's timestamp and length — the window title's second line
    /// (Slice 10). `.navigationSubtitle` is text only; the pin moved to the
    /// toolbar and the language badges to a row in `content`.
    private var subtitle: String {
        guard let recording = library.selected else { return "" }
        return "\(recording.created.formatted(date: .abbreviated, time: .shortened))  ·  \(recording.durationLabel)"
    }

    private func pinButton(_ recording: AudioLibrary.Recording) -> some View {
        Button {
            library.togglePin(recording)
        } label: {
            Image(systemName: recording.pinned ? "pin.fill" : "pin")
        }
        .foregroundStyle(recording.pinned ? AnyShapeStyle(Token.Accent.primary) : AnyShapeStyle(.secondary))
        .help(recording.pinned ? "Unpin — the ring may evict this" : "Pin — never evicted by the ring")
        .accessibilityLabel(recording.pinned ? "Unpin recording" : "Pin recording")
    }

    /// The system segmented control, unlike the Chat/Audio pill in the sidebar.
    /// That one went custom because AppKit will not keep a selected *icon-plus-label*
    /// segment light (`DECISIONS.md`, 2026-08-15); these are two plain words, which
    /// is the case the system control handles correctly.
    private func transcriptControls(_ recording: AudioLibrary.Recording) -> some View {
        HStack {
            Picker("", selection: $showingCleaned) {
                Text("Raw").tag(false)
                Text("Cleaned").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(recording.cleaned == nil)
            .help(
                recording.cleaned == nil
                    ? "This recording has no cleaned transcript. Cleanup arrives in a later build."
                    : "Raw carries the word timings, so clicking a word seeks only there."
            )

            Spacer()

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(shownText(recording), forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.plain)
            .help(showingCleaned ? "Copy cleaned transcript" : "Copy raw transcript")
            .accessibilityLabel("Copy transcript")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func shownText(_ recording: AudioLibrary.Recording) -> String {
        (showingCleaned ? recording.cleaned : nil) ?? recording.raw
    }
}

/// §14.3's file-transcription slot. **Nothing sets `library.failure` in slice 6** —
/// slice 14 does, and the build order asks for the surface now so it is not an
/// afterthought then. Inline and dismissible, never a notification or a modal:
/// the import was started from this window, so this window is where its failure
/// waits whether or not it is frontmost.
struct FailureBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
            Text(message)
                .font(.callout)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.quaternary)
    }
}

// MARK: - Transport

struct PlaybackBar: View {
    let recording: AudioLibrary.Recording

    private var playback: AudioPlayback { .shared }

    var body: some View {
        HStack {
            Button {
                playback.playPause()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(Token.Accent.primary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")

            PlaybackWaveform(peaks: playback.peaks, progress: playback.progress) {
                playback.seek(to: $0 * max(playback.duration, 0))
            }

            Text(AudioLibrary.clock(playback.time))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

/// The drawn envelope of a finished recording — Voice Memos' shape, which is what
/// macOS itself puts on this surface (`rules/design.md` §1 and §2.2: name the
/// system reference, then follow it).
///
/// **Bar count is not authored.** It falls out of the pane's width over the HUD
/// waveform's own bar pitch, so the envelope keeps its density when the window is
/// resized and the two waveforms stay the same drawing at two sizes.
struct PlaybackWaveform: View {
    let peaks: [CGFloat]
    let progress: Double
    let onSeek: (Double) -> Void

    @State private var width: CGFloat = 0

    private static let bar = Token.Authored.Waveform.self
    private static var pitch: CGFloat { bar.barWidth + bar.barGap }

    private var count: Int { max(1, Int(width / Self.pitch)) }

    var body: some View {
        HStack(spacing: Self.bar.barGap) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(fill(index))
                    .frame(width: Self.bar.barWidth, height: height(index))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.bar.playbackHeight)
        // Hit target covers the whole strip, including the gaps and the space
        // above and below the bars — a click that lands between two bars is a
        // seek, not a miss.
        .contentShape(.rect)
        // Not `GeometryReader`: this reads one number out of the layout without
        // taking over the view's own sizing (`rules/design.md` §14).
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
        // `minimumDistance: 0` makes one gesture serve both click and drag, which
        // is what every system scrubber does.
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard width > 0 else { return }
                    onSeek(min(1, max(0, value.location.x / width)))
                }
        )
        .accessibilityLabel("Playback position")
        .accessibilityValue(Text(progress.formatted(.percent.precision(.fractionLength(0)))))
    }

    private func fill(_ index: Int) -> AnyShapeStyle {
        let played = Double(index) / Double(count) < progress
        return played ? AnyShapeStyle(Token.Accent.primary) : AnyShapeStyle(.tertiary)
    }

    /// Resamples the decode's buckets down to the bars actually drawn, taking the
    /// **maximum** across each span rather than the mean: an averaged envelope
    /// loses exactly the transients that make one moment findable.
    private func height(_ index: Int) -> CGFloat {
        // A dot, not a gap — the same rule as the HUD's resting bar, so silence
        // reads as silence rather than as a hole in the control.
        let floor = Self.bar.barWidth
        guard !peaks.isEmpty else { return floor }

        let lower = peaks.count * index / count
        let upper = max(lower + 1, peaks.count * (index + 1) / count)
        let level = peaks[lower..<min(upper, peaks.count)].max() ?? 0
        return max(floor, Self.bar.playbackHeight * level)
    }
}

// MARK: - Transcript

/// §14.4's `transcript` role, and the build order's "whole interaction": every
/// word is a control, so hover and pressed states are what tell you the transcript
/// is an index into the audio rather than a block of text.
///
/// **Known limit, and it belongs to slice 14 rather than here.** One view per word
/// is right for a dictation and will not be right for an imported hour at ~9,000
/// words. The flow layout cannot be lazy, so that slice needs a different
/// construction — not a premature one now.
struct TranscriptBody: View {
    let words: [Transcription.Draft.Word]
    let text: String
    let seekable: Bool
    let onSeek: (TimeInterval) -> Void

    /// The width of a space in the transcript's own font, used for the gap between
    /// words, the gap between lines, and the word chip's inset. One system metric
    /// rather than three authored numbers (`rules/design.md` §1, order 2).
    static var space: CGFloat {
        NSAttributedString(
            string: " ",
            attributes: [.font: NSFont.preferredFont(forTextStyle: .body)]
        ).size().width
    }

    var body: some View {
        if seekable, !words.isEmpty {
            FlowLayout(spacing: Self.space, lineSpacing: Self.space) {
                ForEach(Array(words.enumerated()), id: \.offset) { _, word in
                    Button(word.text) { onSeek(word.start) }
                        .buttonStyle(WordButtonStyle())
                        .accessibilityHint("Play from \(AudioLibrary.clock(word.start))")
                }
            }
        } else {
            Text(text)
                .font(Token.Text.transcript)
                .textSelection(.enabled)
        }
    }
}

/// Hover and pressed, both from hierarchical system styles so they follow
/// appearance, accent, and increased contrast without a branch.
struct WordButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Word(configuration: configuration)
    }

    private struct Word: View {
        let configuration: ButtonStyleConfiguration

        @State private var hovering = false

        private var inset: CGFloat { TranscriptBody.space / 2 }

        var body: some View {
            configuration.label
                .font(Token.Text.transcript)
                .foregroundStyle(.primary)
                .padding(.horizontal, inset)
                .padding(.vertical, inset)
                .background {
                    if configuration.isPressed {
                        // Concentric with nothing, so the radius is the inset
                        // doubled — the smallest curve that reads as a chip
                        // around a single word at body size.
                        Token.shape(radius: inset * 2).fill(.tertiary)
                    } else if hovering {
                        Token.shape(radius: inset * 2).fill(.quaternary)
                    }
                }
                .onHover { inside in
                    hovering = inside
                    if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
        }
    }
}

/// Words wrap like text, which no built-in SwiftUI container does — `HStack` will
/// not wrap and `Text` will not give per-word hit testing. Thirty lines of `Layout`
/// is the smaller of the two costs.
struct FlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let limit = proposal.width ?? .infinity
        var size = CGSize.zero
        walk(subviews, limit: limit) { _, frame in
            size.width = max(size.width, frame.maxX)
            size.height = max(size.height, frame.maxY)
        }
        return size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        walk(subviews, limit: bounds.width) { subview, frame in
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    /// One traversal, used by both passes so measurement and placement cannot
    /// disagree about where a line breaks.
    private func walk(
        _ subviews: Subviews,
        limit: CGFloat,
        body: (Subviews.Element, CGRect) -> Void
    ) {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > limit {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            body(subview, CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
