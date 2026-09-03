//
//  GlassPanelView.swift
//  Sotto
//
//  Settings → Appearance. The docked overlay's background surface for the two
//  Liquid Glass options of `AppearanceSettings.ChatPanelStyle`.
//
//  **These reverse closed decision gap 1** (the docked overlay is deliberately
//  "a right-docked column with no panel edge … no border, no corner, no
//  surface") **and a measured rejection of glass for that field** (`WashView`
//  header / `DECISIONS.md` 2026-09-01). As of 2026-09-03 the feathered variant
//  ("Liquid Blur") is the shipped default — Anthony's call, logged in
//  DECISIONS.md. The material verdict is his, judged on screen.
//

import SwiftUI

/// A Liquid Glass panel behind the docked conversation and composer. Two edge
/// treatments:
///
/// - `.feathered` — glass whose rectangular edge dissolves into the wallpaper,
///   the closest glass analogue of `WashView`'s edgeless field. `glassEffect(in:)`
///   takes only a `Shape` and cannot feather, so the softness is a blurred mask
///   over the whole surface. If the mask flattens the glass on a given machine
///   this is the place to swap in a hybrid (soft blur band + inset glass rect).
/// - `.crisp` — a plain glass panel with the specular rim the bare bar and HUD
///   wear, pulled in tight around the content so its edge reads close to the
///   conversation rather than out at the wash's full bleed.
struct GlassPanelView: View {
    enum Border { case crisp, feathered }

    let border: Border

    private var radius: CGFloat {
        switch border {
        // A tight panel wants a smaller corner than the wash's 72, which was
        // sized to sit clear of a 40 pt feather band it no longer has.
        case .crisp: 32
        case .feathered: WashView.cornerRadius
        }
    }
    private var feather: CGFloat { WashView.feather }

    /// `.crisp` only: pull the glass rectangle in toward the docked content so
    /// its edge sits close to the conversation and composer instead of out at
    /// the wash's full bleed (Anthony, 2026-09-03: "slightly smaller … less
    /// space around the chat bar and the text before hitting the edge").
    /// `.feathered` keeps the full frame — its edge is meant to dissolve, not be
    /// seen. Against `OverlayView.dockedPanel`'s content insets (top 48, sides
    /// 34, bottom 15 + 36 slack) this leaves a roughly even ~18 pt gutter around
    /// the content. Local constants, one edit each.
    private static let crispInset = EdgeInsets(top: 30, leading: 16, bottom: 33, trailing: 16)

    var body: some View {
        switch border {
        case .crisp:
            glass
                .specularRim(radius: radius)
                .padding(Self.crispInset)
        case .feathered:
            glass
                .mask {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .padding(feather / 2)
                        .blur(radius: feather / 2)
                }
        }
    }

    private var glass: some View {
        GlassEffectContainer(spacing: 0) {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color.clear)
                .glassEffect(Token.Material.overlay, in: .rect(cornerRadius: radius, style: .continuous))
        }
    }
}
