//
//  AppearancePane.swift
//  Sotto
//
//  Settings → Appearance. **Reverses the "Appearance — none" cut** (spec §8.5,
//  CLAUDE.md §3, rules/design.md §12) on Anthony's call, 2026-09-03 — see
//  DECISIONS.md. One control only: the docked overlay's background surface.
//
//  Built from the native grouped-form controls rather than custom chrome
//  (`rules/design.md` §1): `Form` + `.formStyle(.grouped)` is macOS's own
//  System-Settings styling — inset rounded groups, section headers, standard
//  rows.
//

import SwiftUI

struct AppearancePane: View {
    @Bindable private var settings = AppearanceSettings.shared

    var body: some View {
        Form {
            Section {
                Picker("Panel style", selection: $settings.chatPanelStyle) {
                    ForEach(AppearanceSettings.ChatPanelStyle.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Chat Panel")
            } footer: {
                Text("The surface drawn behind the overlay when it is docked to an existing chat.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .settingsToolbar("Appearance")
    }
}
