//
//  WashView.swift
//  Sotto
//
//  Slice 9e. Graduated wash — Designs for Slice9.pdf Frame 2, FINDING 2026-08-27.
//
//  No Glass API draws a variable-radius blur with no edge. Three candidates:
//  (a) single NSVisualEffectView masked by horizontal gradient (opacity ramps,
//      radius does not), (b) stacked masked effect views approximating ramp,
//  (c) uniform blur + white wash. **Default to (a)** per 2026-08-27 six answers (1):
//  cheapest, judgeable without building the expensive stack. Screenshot for ruling.

import AppKit
import SwiftUI

/// Right-docked 560pt column with no panel edge — Frame 2 wash.
/// One NSVisualEffectView masked by a horizontal gradient (opacity 0→1). The
/// white wash is a second gradient layer over it 0→93 % (decision 2026-08-27).
struct WashView: NSViewRepresentable {
    static let columnWidth: CGFloat = 560

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.masksToBounds = true

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        // Gradient opacity mask: left edge transparent, right edge opaque.
        let mask = CAGradientLayer()
        mask.startPoint = CGPoint(x: 0, y: 0.5)
        mask.endPoint = CGPoint(x: 1, y: 0.5)
        mask.colors = [NSColor.clear.cgColor, NSColor.white.cgColor]
        mask.locations = [0, 1]
        effect.layer?.mask = mask
        effect.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(effect)
        NSLayoutConstraint.activate([
            effect.topAnchor.constraint(equalTo: container.topAnchor),
            effect.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            effect.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        // White wash ramp 0 → 0.93 (Frame 2 caption 0→93 %, six answers (1) keeps it).
        let wash = NSView()
        wash.wantsLayer = true
        let washGrad = CAGradientLayer()
        washGrad.startPoint = CGPoint(x: 0, y: 0.5)
        washGrad.endPoint = CGPoint(x: 1, y: 0.5)
        washGrad.colors = [
            NSColor.white.withAlphaComponent(0).cgColor,
            NSColor.white.withAlphaComponent(0.93).cgColor,
        ]
        washGrad.locations = [0, 1]
        wash.layer = washGrad
        wash.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(wash)
        NSLayoutConstraint.activate([
            wash.topAnchor.constraint(equalTo: container.topAnchor),
            wash.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            wash.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            wash.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        // Keep masks sized with view — CAGradientLayer needs frame updates.
        context.coordinator.gradientLayers = [mask, washGrad]
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Layout pass will size layers via constraints; update mask frames.
        DispatchQueue.main.async {
            for layer in context.coordinator.gradientLayers {
                layer.frame = nsView.bounds
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var gradientLayers: [CAGradientLayer] = [] }
}
