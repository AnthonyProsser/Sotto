//
//  DictationPane.swift
//  Sotto
//
//  Settings → Dictation. §8.1's profiles as trimmed by DECISIONS.md — no model
//  pickers, no context slider, no language picker. Retention lives in General.
//

import SwiftUI

/// Profiles own every dictation setting. `Form` + `.formStyle(.grouped)` is
/// the house idiom: it is macOS's own System-Settings styling.
struct DictationPane: View {
    @Bindable private var store = ProfileStore.shared

    @State private var newTerm = ""

    var body: some View {
        Form {
            if let reason = Cleanup.shared.unavailabilityReason {
                Section {
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                ForEach(store.profiles) { profile in
                    Button {
                        store.activeID = profile.id
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(profile.name)
                                Text(profile.cleanupEnabled ? "Cleanup on" : "Cleanup off")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if profile.id == store.activeID {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Duplicate") { store.duplicate(profile) }
                        Button("Delete", role: .destructive) { store.delete(profile) }
                            .disabled(store.profiles.count <= 1)
                    }
                }

                Button("Add Profile") { store.add() }
            } header: {
                Text("Profiles")
            } footer: {
                Text("Selecting a profile switches every section below to it. Right-click a profile to duplicate or delete it.")
            }

            if let index = store.profiles.firstIndex(where: { $0.id == store.activeID }) {
                profileEditor($store.profiles[index])
            }
        }
        .formStyle(.grouped)
        // The window title, not a toolbar item (`DECISIONS.md`, 2026-09-03):
        // macOS 26 draws a bordered capsule around `.navigation` items. The
        // subtitle is cleared so the Audio pane's does not leak through.
        .navigationTitle("Dictation")
        .navigationSubtitle("")
    }

    // MARK: - Selected profile

    private func profileEditor(_ profile: Binding<DictationProfile>) -> some View {
        Group {
            Section {
                TextField("Profile name", text: profile.name)
            } header: {
                Text("Name")
            }

            Section {
                Toggle("Cleanup enabled", isOn: profile.cleanupEnabled)

                TextField(
                    "Extra instructions, e.g. keep product names capitalized",
                    text: profile.cleanupInstructions,
                    axis: .vertical
                )
                .lineLimit(6)
            } header: {
                Text("Cleanup")
            } footer: {
                Text(
                    profile.wrappedValue.cleanupEnabled
                    ? "Cleanup removes fillers, resolves self-corrections, and punctuates from your pauses."
                    : "When off, the raw transcript is inserted as-is — including on locales past Apple's 30, where there is no native punctuation."
                )
            }

            Section {
                ForEach(profile.wrappedValue.vocabulary, id: \.self) { term in
                    HStack {
                        Text(term)
                        Spacer()
                        Button {
                            profile.wrappedValue.vocabulary.removeAll { $0 == term }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(term)")
                    }
                }

                HStack {
                    TextField("Add term", text: $newTerm)
                        .onSubmit(addTerm(profile))
                    Button("Add", action: addTerm(profile))
                        .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Custom vocabulary")
            } footer: {
                Text("Preferred spellings for cleanup — “Sotto” over “soto”. Does nothing while cleanup is off.")
            }
        }
    }

    private func addTerm(_ profile: Binding<DictationProfile>) -> () -> Void {
        {
            let term = newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, !profile.wrappedValue.vocabulary.contains(term) else { return }
            profile.wrappedValue.vocabulary.append(term)
            newTerm = ""
        }
    }
}
