//
//  ModelsPane.swift
//  Sotto
//
//  Slice 8. Settings → Models (§7.4): the curated list, the paste field for an
//  arbitrary repo id, §2.3's memory estimate shown *before* a download, and
//  progress and failures in the surface that started them — never the HUD.
//

import SwiftUI

// MARK: - Catalog

/// One curated row. The baked size is first-paint only; the manifest's real
/// safetensors totals replace it once a download resolves.
nonisolated struct CuratedModel: Identifiable, Equatable {
    let repoID: String
    /// The lab a row groups and takes its badge colour from. The colour is
    /// derived from this string (`badge.labTint`, DECISIONS.md 2026-08-25) —
    /// never stored.
    let lab: String
    /// The badge's letters. Data, not design: only the colour is derived.
    let monogram: String
    let quantization: String
    let vision: Bool
    /// Known audio-capable (§2.2) — shown as a lit mic in the row.
    let dictation: Bool
    let blurb: String
    /// First-paint size before any resolution.
    let bakedBytes: Int64

    var id: String { repoID }

    var displayName: String {
        repoID.split(separator: "/").last.map(String.init) ?? repoID
    }
}

/// §7.4: the curated list ships in the binary and changes when the app does —
/// no fetching it, ever. Intentionally empty for now — one-click installs are
/// on hold until the default set is chosen deliberately. The Available section
/// therefore shows only pasted candidates (until the list is curated again);
/// Hugging Face repo ids and `ollama pull` remain the two acquisition paths.
enum CuratedCatalog {
    static let models: [CuratedModel] = []
}

/// What the machine already has, shown so the user knows it — no download, no
/// delete, nothing Sotto could remove even if asked (`rules/models-and-network.md`
/// §1.1: Apple's model is unversioned from Sotto's side and moves on OS updates).
nonisolated struct BuiltInModel: Identifiable, Equatable {
    let name: String
    let monogram: String
    let text: Bool
    let dictation: Bool
    let vision: Bool
    let note: String

    var id: String { name }
}

extension BuiltInModel {
    static let all: [BuiltInModel] = [
        BuiltInModel(
            name: "Apple Speech Framework",
            monogram: "AP",
            text: false,
            dictation: true,
            vision: false,
            note: "On-device dictation built into macOS"
        ),
        BuiltInModel(
            name: "Apple Foundation Models",
            monogram: "AP",
            text: true,
            dictation: false,
            vision: false,
            note: "On-device text model built into macOS"
        ),
    ]
}

// MARK: - State

/// Owns the pane's rows and the download tasks behind them. Shared rather than
/// view-owned, like `AudioLibrary`: a download outlives navigating away from
/// the Models section, and cancelling has to stay reachable when the user comes
/// back.
@MainActor
@Observable
final class ModelsState {
    static let shared = ModelsState()

    /// The context length every estimate in this pane is computed at —
    /// `ChatSession.contextSize`'s default and §2.3's worked example both use
    /// 4096. There is no system metric for a context length (`rules/design.md`
    /// §1), and §7.3's slider belongs to a later slice; when it lands, the
    /// slider's value replaces this constant as the input.
    static let previewContextLength = 4096

    /// One candidate row: a curated entry or a pasted repo id, in whatever
    /// phase of the ladder it currently sits. Rows leave this list on success —
    /// what the user then has is an on-disk model, which the Downloaded
    /// section owns. A candidate mid-download is displayed in Downloaded, the
    /// way the design draws a download in progress.
    nonisolated struct Candidate: Identifiable {
        enum Phase: Equatable {
            case resolving
            case ready
            case downloading(downloaded: Int64, total: Int64)
            case failed(String)
        }

        let repoID: String
        var lab: String
        var monogram: String
        var blurb: String?
        /// From the catalog entry until resolution, then from `config.json`.
        var vision: Bool
        var dictation: Bool
        var quantization: String?
        /// Manifest safetensors totals once resolved; the catalog's baked guess before.
        var weightsBytes: Int64?
        var estimate: MemoryEstimate?
        var phase: Phase = .resolving

        var id: String { repoID }

        var displayName: String {
            repoID.split(separator: "/").last.map(String.init) ?? repoID
        }

        var progress: Double {
            if case .downloading(let downloaded, let total) = phase, total > 0 {
                return Double(downloaded) / Double(total)
            }
            return 0
        }
    }

    private(set) var candidates: [Candidate] = []
    private(set) var onDisk: [LocalModel] = []
    var pasteText = ""

    private var tasks: [String: Task<Void, Never>] = [:]

    init() {
        reload()
    }

    /// Rung one, checked first and re-checked whenever the pane appears:
    /// hand-placed weights keep working (§7.4).
    func reload() {
        onDisk = ModelStore.registerAll()
    }

    /// The confirmed Delete. Removes the folder and drops the capability
    /// registration; the view asks before calling this.
    func remove(_ model: LocalModel) {
        try? ModelStore.remove(model)
        reload()
    }

    func addPasted() {
        let repoID = pasteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repoID.isEmpty, !candidates.contains(where: { $0.repoID == repoID }) else { return }
        pasteText = ""
        candidates.append(Candidate(
            repoID: repoID,
            lab: "Hugging Face",
            monogram: "HF",
            blurb: nil,
            vision: false,
            dictation: false,
            quantization: nil,
            weightsBytes: nil
        ))
        resolve(rowID: repoID)
    }

    /// A catalog entry's Download press. Its estimate is already on the row —
    /// §7.4's estimate-before-download is satisfied by the baked figure the
    /// user read when they decided — so the candidate goes straight to the
    /// ladder, which re-resolves real totals before the first byte moves.
    func start(_ entry: CuratedModel) {
        guard !candidates.contains(where: { $0.repoID == entry.repoID }) else { return }
        candidates.append(Candidate(
            repoID: entry.repoID,
            lab: entry.lab,
            monogram: entry.monogram,
            blurb: entry.blurb,
            vision: entry.vision,
            dictation: entry.dictation,
            quantization: entry.quantization,
            weightsBytes: entry.bakedBytes,
            estimate: MemoryEstimator.estimate(weightsBytes: entry.bakedBytes, kvCacheBytes: 0),
            phase: .ready
        ))
        download(entry.repoID)
    }

    // MARK: - Resolution — the estimate before the download

    /// Fetches the manifest and `config.json` — kilobytes against the gigabytes
    /// they commit the user to — and computes §2.3's estimate. Nothing larger
    /// moves until the user presses Download on a resolved row.
    private func resolve(rowID: String) {
        tasks[rowID]?.cancel()
        tasks[rowID] = Task {
            do {
                guard let index = rowIndex(rowID) else { return }
                let manifest = try await ModelDownload.manifest(for: rowID)

                var vision = false
                var geometry: ModelGeometry?
                if let config = try? await ModelDownload.configData(for: rowID),
                   let parsed = try? CapabilityRegistry.parseMLXConfig(data: config) {
                    vision = parsed.capability.vision
                    geometry = parsed.geometry
                }

                // Weights are the safetensors subset only — configs and
                // tokenizer data ride along but are not the `weights` term.
                let weights = manifest.files
                    .filter { $0.name.hasSuffix(".safetensors") }
                    .reduce(Int64(0)) { $0 + ($1.size ?? 0) }

                guard let i = rowIndex(rowID) else { return }
                candidates[i].vision = vision
                candidates[i].weightsBytes = weights > 0 ? weights : manifest.totalBytes
                candidates[i].estimate = estimate(weightsBytes: candidates[i].weightsBytes!, geometry: geometry)
                if case .resolving = candidates[i].phase { candidates[i].phase = .ready }
            } catch is CancellationError {
                removeCandidate(rowID)
            } catch {
                if let i = rowIndex(rowID) {
                    candidates[i].phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// §2.3 with no geometry known degrades the way `LocalModel.memoryEstimate`
    /// does: weights plus overhead, no KV term claimed.
    private func estimate(weightsBytes: Int64, geometry: ModelGeometry?) -> MemoryEstimate {
        guard let geometry else {
            return MemoryEstimator.estimate(weightsBytes: weightsBytes, kvCacheBytes: 0)
        }
        return MemoryEstimator.estimate(
            weightsBytes: weightsBytes,
            geometry: geometry,
            contextLength: Self.previewContextLength
        )
    }

    // MARK: - Acquisition

    func download(_ rowID: String) {
        guard let i = rowIndex(rowID) else { return }
        candidates[i].phase = .downloading(downloaded: 0, total: candidates[i].weightsBytes ?? 0)

        tasks[rowID]?.cancel()
        tasks[rowID] = Task {
            do {
                _ = try await ModelDownload.acquire(rowID, progress: { downloaded, total in
                    Task { @MainActor [weak self] in
                        self?.setProgress(rowID: rowID, downloaded: downloaded, total: total)
                    }
                })
                reload()
                removeCandidate(rowID)
            } catch is CancellationError {
                // Back to the resolved row, estimate intact — cancelling is not failing.
                if let i = rowIndex(rowID) { candidates[i].phase = .ready }
            } catch {
                if let i = rowIndex(rowID) {
                    candidates[i].phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    func cancel(_ rowID: String) {
        tasks[rowID]?.cancel()
        tasks[rowID] = nil
    }

    private func setProgress(rowID: String, downloaded: Int64, total: Int64) {
        guard let i = rowIndex(rowID) else { return }
        if case .downloading = candidates[i].phase {
            candidates[i].phase = .downloading(downloaded: downloaded, total: total)
        }
    }

    private func removeCandidate(_ rowID: String) {
        tasks[rowID] = nil
        candidates.removeAll { $0.id == rowID }
    }

    private func rowIndex(_ rowID: String) -> Array<Candidate>.Index? {
        candidates.firstIndex { $0.id == rowID }
    }
}

// MARK: - View

/// The design render of 2026-08-25: a header strip (search over this pane's
/// rows only — never the network — and the Lab/Size/Name sort), a Downloaded
/// section carrying built-ins, on-disk models, and anything mid-download, and
/// an Available section grouped by lab with the Add row at its foot.
struct ModelsPane: View {
    @Bindable private var models = ModelsState.shared

    /// The row whose Delete has been clicked and is awaiting its confirm.
    @State private var confirmingDelete: LocalModel.ID?
    @State private var sort: Sort = .lab
    @State private var search = ""
    @State private var showingPasteField = false

    enum Sort: String, CaseIterable, Identifiable {
        case lab, size, name

        var id: Self { self }

        var title: String { rawValue.capitalized }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                downloadedSection
                availableSection
            }
            .padding()
        }
        .task { models.reload() }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Text("Models")
                    .font(.title2.weight(.semibold))
            }
            ToolbarItem(placement: .principal) {
                searchField
            }
            ToolbarItem(placement: .primaryAction) {
                Picker("Sort", selection: $sort) {
                    ForEach(Sort.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    /// §7.4's list plus a filter over it (DECISIONS.md, 2026-08-25): local
    /// rows only, never a networked model search. In the title bar so the
    /// detail's scroll content starts at the toolbar's bottom edge with no
    /// empty titlebar band above it.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search models", text: $search)
                .textFieldStyle(.plain)
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary, in: .rect(cornerRadius: 8, style: .continuous))
        .frame(width: 240)
    }

    // MARK: Sections

    @ViewBuilder
    private var downloadedSection: some View {
        if !downloadedItems.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Downloaded").font(.headline)
                    Spacer()
                    summary
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
                container {
                    rows(downloadedItems) { item in
                        switch item {
                        case .builtIn(let model): builtInRow(model)
                        case .local(let model): localRow(model)
                        case .downloading(let candidate): downloadingRow(candidate)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var availableSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Available").font(.headline)
                Spacer()
                Text("Percentages are of this Mac's \(ramSummary) of memory")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            container {
                rows(availableItems) { item in
                    switch item {
                    case .header(let lab, let count): groupHeader(lab, count: count)
                    case .row(let row): availableRow(row)
                    }
                }
                if !availableItems.isEmpty { Divider().padding(.leading, 52) }
                addRow
            }
        }
    }

    private var summary: Text {
        let count = models.onDisk.count + BuiltInModel.all.count
        let bytes = models.onDisk.reduce(Int64(0)) { $0 + $1.diskBytes }
        return Text("\(count) models · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) on disk")
    }

    private var ramSummary: String {
        ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory)
    }

    /// One container, hairline-divided rows. The 52 pt inset walks the divider
    /// past the badge, the way an inset grouped list indents its separators.
    private func container(@ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 0, content: content)
            .background(.quaternary)
            .clipShape(.rect(cornerRadius: 10, style: .continuous))
    }

    private func rows<Item: Identifiable>(_ items: [Item], @ViewBuilder row: @escaping (Item) -> some View) -> some View {
        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            if index > 0 { Divider().padding(.leading, 52) }
            row(item)
        }
    }

    // MARK: Downloaded rows

    private enum DownloadedItem: Identifiable {
        case builtIn(BuiltInModel)
        case local(LocalModel)
        case downloading(ModelsState.Candidate)

        var id: String {
            switch self {
            case .builtIn(let model): "builtin-\(model.id)"
            case .local(let model): "local-\(model.id)"
            case .downloading(let candidate): "downloading-\(candidate.id)"
            }
        }
    }

    private var downloadedItems: [DownloadedItem] {
        var items: [DownloadedItem] = BuiltInModel.all
            .filter { matches($0.name, "Apple", $0.note) }
            .map { .builtIn($0) }
        for model in models.onDisk where matches(model.id, nil, catalogEntry(for: model)?.blurb) {
            items.append(.local(model))
        }
        for candidate in models.candidates
        where isDownloading(candidate) && matches(candidate.displayName, candidate.lab, candidate.blurb) {
            items.append(.downloading(candidate))
        }
        return items
    }

    /// Grayed out and button-less: the user already has it and Sotto could not
    /// remove it if they asked. The lock is a static indicator (2026-08-25).
    private func builtInRow(_ model: BuiltInModel) -> some View {
        HStack(spacing: 12) {
            badge(text: model.monogram, tint: .gray)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.name)
                Text(model.note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            capabilityIcons(text: model.text, dictation: model.dictation, vision: model.vision)
            includedBlock
            Image(systemName: "lock")
                .foregroundStyle(.tertiary)
                .help("Comes with your Mac — can't be removed")
                .frame(width: 28)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .foregroundStyle(.secondary)
        .help(model.note)
    }

    private func localRow(_ model: LocalModel) -> some View {
        let entry = catalogEntry(for: model)
        return HStack(spacing: 12) {
            badge(text: entry?.monogram ?? monogram(for: model.id), tint: labTint(entry?.lab ?? model.id))
            VStack(alignment: .leading, spacing: 1) {
                Text(model.id)
                if let blurb = entry?.blurb {
                    Text(blurb)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            capabilityIcons(text: true, dictation: entry?.dictation ?? false, vision: model.capability.vision)
            sizeBlock(bytes: model.diskBytes, approximate: false, estimate: model.memoryEstimate(contextLength: ModelsState.previewContextLength))
            deleteCell(model)
                .frame(width: 28)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// A download in progress lives in Downloaded, as the render draws it.
    private func downloadingRow(_ candidate: ModelsState.Candidate) -> some View {
        HStack(spacing: 12) {
            badge(text: candidate.monogram, tint: labTint(candidate.lab))
            VStack(alignment: .leading, spacing: 6) {
                Text(candidate.displayName)
                ProgressView(value: candidate.progress)
                    .progressViewStyle(.linear)
                    .frame(width: 220)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 1) {
                Text("Downloading · \(Int((candidate.progress * 100).rounded()))%")
                Text("\(ByteCountFormatter.string(fromByteCount: Int64(candidate.progress * Double(candidate.downloadTotal)), countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: candidate.downloadTotal, countStyle: .file))")
            }
            .font(.callout)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            Button {
                models.cancel(candidate.id)
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Cancel download")
            .frame(width: 28)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Click turns the cell into the confirm pair; nothing is removed until
    /// the second click.
    @ViewBuilder
    private func deleteCell(_ model: LocalModel) -> some View {
        if confirmingDelete == model.id {
            HStack(spacing: 6) {
                Button("Delete", role: .destructive) {
                    confirmingDelete = nil
                    models.remove(model)
                }
                Button("Cancel") { confirmingDelete = nil }
            }
            .controlSize(.small)
        } else {
            Button {
                confirmingDelete = model.id
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Delete \(model.id)")
        }
    }

    // MARK: Available rows

    private struct AvailableRow: Identifiable {
        enum Source {
            case curated(CuratedModel)
            case candidate(ModelsState.Candidate)
        }

        let id: String
        let name: String
        let lab: String
        let monogram: String
        let blurb: String?
        let bytes: Int64?
        let estimate: MemoryEstimate?
        let vision: Bool
        let dictation: Bool
        let approximate: Bool
        let source: Source
    }

    private enum AvailableItem: Identifiable {
        case header(lab: String, count: Int)
        case row(AvailableRow)

        var id: String {
            switch self {
            case .header(let lab, _): "header-\(lab)"
            case .row(let row): row.id
            }
        }
    }

    private var availableItems: [AvailableItem] {
        var all: [AvailableRow] = []

        let onDiskIDs = Set(models.onDisk.map(\.id))
        let activeIDs = Set(models.candidates.map(\.id))
        for entry in CuratedCatalog.models
        where !onDiskIDs.contains(entry.displayName) && !activeIDs.contains(entry.repoID)
            && matches(entry.displayName, entry.lab, entry.blurb) {
            all.append(AvailableRow(
                id: entry.repoID,
                name: entry.displayName,
                lab: entry.lab,
                monogram: entry.monogram,
                blurb: entry.blurb,
                bytes: entry.bakedBytes,
                estimate: MemoryEstimator.estimate(weightsBytes: entry.bakedBytes, kvCacheBytes: 0),
                vision: entry.vision,
                dictation: entry.dictation,
                approximate: true,
                source: .curated(entry)
            ))
        }
        for candidate in models.candidates
        where !isDownloading(candidate) && matches(candidate.displayName, candidate.lab, candidate.blurb) {
            all.append(AvailableRow(
                id: candidate.id,
                name: candidate.displayName,
                lab: candidate.lab,
                monogram: candidate.monogram,
                blurb: candidate.blurb,
                bytes: candidate.weightsBytes,
                estimate: candidate.estimate,
                vision: candidate.vision,
                dictation: candidate.dictation,
                approximate: false,
                source: .candidate(candidate)
            ))
        }

        switch sort {
        case .lab:
            var items: [AvailableItem] = []
            for lab in Set(all.map(\.lab)).sorted() {
                let group = all.filter { $0.lab == lab }.sorted(by: sizeOrder)
                items.append(.header(lab: lab, count: group.count))
                items.append(contentsOf: group.map { .row($0) })
            }
            return items
        case .size:
            return all.sorted(by: sizeOrder).map { .row($0) }
        case .name:
            return all.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map { .row($0) }
        }
    }

    private func sizeOrder(_ a: AvailableRow, _ b: AvailableRow) -> Bool {
        (a.bytes ?? .max) < (b.bytes ?? .max)
    }

    private func availableRow(_ row: AvailableRow) -> some View {
        HStack(spacing: 12) {
            badge(text: row.monogram, tint: labTint(row.lab))
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name)
                if let blurb = row.blurb {
                    Text(blurb)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if case .candidate(let candidate) = row.source, case .failed(let message) = candidate.phase {
                    // §14.3: failures surface here where the download was
                    // started, never the HUD.
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            Spacer(minLength: 12)
            capabilityIcons(text: true, dictation: row.dictation, vision: row.vision)
            sizeBlock(bytes: row.bytes, approximate: row.approximate, estimate: row.estimate)
            control(for: row)
                .frame(width: 28)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func groupHeader(_ lab: String, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(lab)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("\(count) model\(count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func control(for row: AvailableRow) -> some View {
        switch row.source {
        case .curated(let entry):
            Button {
                models.start(entry)
            } label: {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Download — \(entry.quantization), about \(ByteCountFormatter.string(fromByteCount: entry.bakedBytes, countStyle: .file))")
        case .candidate(let candidate):
            switch candidate.phase {
            case .resolving:
                ProgressView()
                    .controlSize(.small)
                    .help("Resolving \(candidate.repoID)")
            case .ready:
                Button {
                    models.download(candidate.id)
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Download")
            case .downloading:
                EmptyView()
            case .failed:
                Button("Retry") { models.download(candidate.id) }
                    .controlSize(.small)
            }
        }
    }

    /// §7.4's paste field, revealed by the Add row and sitting with the list
    /// rather than replacing it. Hugging Face repo ids only this build — the
    /// Ollama rung is consumed-ready in the backend but has no UI yet, and the
    /// render's "local GGUF file" option is dropped (DECISIONS.md, 2026-08-25).
    @ViewBuilder
    private var addRow: some View {
        if showingPasteField {
            HStack(spacing: 12) {
                Image(systemName: "plus.circle")
                    .foregroundStyle(.secondary)
                TextField(
                    "Hugging Face repo id — e.g. mlx-community/Llama-3.2-3B-Instruct-4bit",
                    text: $models.pasteText
                )
                .onSubmit(models.addPasted)
                Button("Add", action: models.addPasted)
                    .disabled(models.pasteText.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel") { showingPasteField = false }
                    .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        } else {
            HStack(spacing: 12) {
                Image(systemName: "plus.circle")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Add your own model")
                    Text("Hugging Face repo id")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button("Add…") { showingPasteField = true }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(.rect)
            .onTapGesture { showingPasteField = true }
        }
    }

    // MARK: Cells

    private var includedBlock: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text("Included")
            Text("0 GB · with macOS")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(width: 110, alignment: .trailing)
    }

    /// `~2.4 GB` unresolved; exact bytes once measured, with the % still from
    /// §2.3 fed the real weights. Amber past ~60 % of RAM, always selectable —
    /// predict, don't gate (`rules/models-and-network.md` §1). The render puts
    /// the amber on the percent line, not the size.
    private func sizeBlock(bytes: Int64?, approximate: Bool, estimate: MemoryEstimate?) -> some View {
        Group {
            if let bytes, bytes != 0 {
                let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(approximate ? "~" : "")\(size)")
                        .foregroundStyle(.primary)
                    if let estimate {
                        Text("\(Int((estimate.percentageOfRAM * 100).rounded()))% of RAM")
                            .foregroundStyle(estimate.isAmber ? Color.orange : .secondary)
                    }
                }
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .monospacedDigit()
        .frame(width: 110, alignment: .trailing)
    }

    /// A capability cell: lit when the model has it, dimmed when not. The
    /// tooltip carries what a column header would have said.
    private func capabilityIcons(text: Bool, dictation: Bool, vision: Bool) -> some View {
        HStack(spacing: 10) {
            capabilityIcon("mic", on: dictation, "Speech — can transcribe dictation")
            capabilityIcon("bubble.left.and.bubble.right", on: text, "Chat — can run conversations")
            capabilityIcon("eye", on: vision, "Vision — can read images")
        }
        .frame(width: 66)
    }

    private func capabilityIcon(_ name: String, on: Bool, _ legend: String) -> some View {
        Image(systemName: name)
            .font(.callout)
            .foregroundStyle(on ? AnyShapeStyle(.secondary) : AnyShapeStyle(.quaternary))
            .help(on ? legend : "\(legend) — not available on this model")
    }

    private func badge(text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(tint, in: .rect(cornerRadius: 7, style: .continuous))
    }

    // MARK: Derived values

    /// `badge.labTint` (DECISIONS.md, 2026-08-25): the colour is derived from
    /// the lab's name — Contacts' monogram treatment, which has no public API —
    /// by folding the name into the system named hues, so no hex is authored.
    /// The fold is hand-rolled because `String.hashValue` is not stable across
    /// launches, and a badge that changed colour between runs would look like
    /// a different model.
    private func labTint(_ lab: String) -> Color {
        let palette: [Color] = [.red, .orange, .green, .mint, .teal, .cyan, .blue, .indigo, .purple, .pink, .brown]
        let hash = lab.unicodeScalars.reduce(0) { $0 &* 31 &+ Int($1.value) }
        let index = Int(UInt(bitPattern: hash) % UInt(palette.count))
        return palette[index]
    }

    private func monogram(for id: String) -> String {
        String(id.prefix(2)).uppercased()
    }

    private func catalogEntry(for model: LocalModel) -> CuratedModel? {
        CuratedCatalog.models.first { $0.displayName == model.id }
    }

    private func isDownloading(_ candidate: ModelsState.Candidate) -> Bool {
        if case .downloading = candidate.phase { return true }
        return false
    }

    private func matches(_ name: String, _ lab: String?, _ blurb: String?) -> Bool {
        guard !search.isEmpty else { return true }
        let query = search.lowercased()
        return name.lowercased().contains(query)
            || lab?.lowercased().contains(query) == true
            || blurb?.lowercased().contains(query) == true
    }
}

private extension ModelsState.Candidate {
    /// The total the current download is measured against, for the row's
    /// "1.6 GB of 2.6 GB" line.
    var downloadTotal: Int64 {
        if case .downloading(_, let total) = phase { return total }
        return weightsBytes ?? 0
    }
}
