//
//  AppearanceSettings.swift
//  Sotto
//
//  Settings → Appearance. **This resurrects the Appearance section that spec
//  §8.5 ("Appearance — none"), CLAUDE.md §3, and rules/design.md §12 had cut** —
//  Anthony's call, 2026-09-03, logged in DECISIONS.md. It carries exactly one
//  control: the docked overlay's background surface. No theme struct, no
//  light/dark override, no token indirection — `Token.swift` still maps roles to
//  system values unchanged and this object sits beside it, not inside it.
//

import Foundation

/// The one thing the Appearance pane can change, and the only runtime state
/// Sotto keeps about how it looks: which surface is drawn behind the docked
/// overlay conversation and composer.
@MainActor
@Observable
final class AppearanceSettings {
    static let shared = AppearanceSettings()

    /// **`liquidBlur` is the default** (Anthony, 2026-09-03), which demotes the
    /// wash — the edgeless field from closed decision gap 1 and the measured
    /// 2026-09-01 glass rejection — to one option among three. See DECISIONS.md.
    ///
    /// - `liquidBlur` — a Liquid Glass panel whose edge feathers into the
    ///   wallpaper (`GlassPanelView(border: .feathered)`).
    /// - `liquidGlass` — a plain Liquid Glass panel, pulled in tight around the
    ///   conversation and composer (`GlassPanelView(border: .crisp)`).
    /// - `washBlur` — the original wash (`WashView`).
    enum ChatPanelStyle: String, CaseIterable, Identifiable {
        case liquidBlur, liquidGlass, washBlur
        var id: Self { self }
        var title: String {
            switch self {
            case .liquidBlur: "Liquid Blur"
            case .liquidGlass: "Liquid Glass"
            case .washBlur: "Wash Blur"
            }
        }
    }

    private enum Key {
        static let chatPanelStyle = "appearance.chatPanelStyle"
    }

    var chatPanelStyle: ChatPanelStyle {
        didSet {
            guard chatPanelStyle != oldValue else { return }
            UserDefaults.standard.set(chatPanelStyle.rawValue, forKey: Key.chatPanelStyle)
        }
    }

    private init() {
        chatPanelStyle = UserDefaults.standard.string(forKey: Key.chatPanelStyle)
            .flatMap(ChatPanelStyle.init) ?? .liquidBlur
    }
}
