//
//  HUDView.swift
//  Sotto
//
//  Slice 3. The HUD — sotto-spec.md §4.5, and the only design surface slice 3 has.
//

import SwiftUI

/// **The HUD's entire vocabulary: a waveform, a completion message, an error.**
/// There is no live transcript layer, no controls, and no waveform toggle — all
/// three were cut and stay cut. If a state is not in this enum the HUD cannot
/// say it, which is the point.
enum HUDState: Equatable {
    /// Capture is running. `level` is 0…1 and drives the bars' amplitude.
    case recording(level: Double)
    /// "Copied to clipboard", and the insertion-succeeded case (§3).
    case message(String)
    /// Transcription, model load, cleanup, or a rejected AX write (§4.5, §14.3).
    /// Errors stay on the surface that owns the failed work — there is no
    /// notification and no modal, because Sotto holds no Notifications grant.
    case error(String)
}

/// One glass surface that changes width with its content.
///
/// **The width is never set.** Recording, it is whatever eight bars and their
/// padding come to; carrying a message, it is whatever the string comes to in
/// the user's language. `sotto-tokens.md` §6.2's 152 pt floor and 320 pt cap are
/// gone — the floor was the message state's width mislabelled as the waveform's
/// requirement (`DECISIONS.md`, 2026-08-18), and a fixed frame sized for one
/// English string is the failure §14.4 names.
///
/// **The surface is a capsule, and the superellipse is deliberately forfeit.**
/// At `r = h/2` a continuous corner and a circular arc are the same curve —
/// measured, see `DECISIONS.md` — so the two cannot both be had. Rendered on
/// screen at 16, 17.5, and 18 (2026-08-19): 16 reads as a rounded rectangle, and
/// by 17.5 there is half a point of straight edge left for the superellipse to
/// blend into, which is no superellipse at all. Anthony ruled for the pill, and
/// both surfaces he pointed at as references are true capsules. This is the one
/// place in Sotto where `Token.shape` yields an arc.
struct HUDView: View {
    let state: HUDState

    /// **Decided once, when the HUD appears, and held until it goes away**
    /// (Anthony, 2026-08-19). Left to itself the glass re-reads the luminance
    /// behind it every frame and flips its labels with it — measured, and the
    /// reason this property exists: a HUD that inverts mid-dictation because the
    /// user scrolled a dark block under it draws attention to itself at the one
    /// moment it should be furthest from the mind. Two versions, one chosen at
    /// open. `HUDPanel` owns the choice; this type only obeys it.
    let appearance: ColorScheme

    /// **False whenever the panel is not on screen.** An ordered-out `NSPanel`
    /// hosting this view keeps its display link running — sampled 2026-08-24 with
    /// no gesture ever fired, `Waveform.body` was 151 of 2242 main-thread samples
    /// and the process sat at ~6 % CPU at rest. `Waveform`'s own note assumed
    /// occlusion stopped it; it does not, and `warm()` plus the armed window mean
    /// the panel spends nearly all of its life ordered out.
    let running: Bool

    /// Height is the one fixed dimension: the HUD is a single line of content and
    /// a line does not grow. Everything else derives from it.
    static let height: CGFloat = 36

    /// Exactly `height / 2`, which is what makes the ends fully round. That also
    /// makes the corner a circular arc rather than a superellipse — see the
    /// type's note; it is the ruling, not an oversight.
    static let radius: CGFloat = 18

    /// Left and right of the content, and the only reason the recording state is
    /// wider than its waveform.
    private static let padding: CGFloat = 16

    var body: some View {
        // A container is required wherever more than one glass surface can exist,
        // and it is what supplies the morph when the HUD changes state. One
        // surface today; the container is what lets the width change read as the
        // shape flowing rather than the window resizing.
        GlassEffectContainer(spacing: 0) {
            content
                .padding(.horizontal, Self.padding)
                .frame(height: Self.height)
                // Glass is applied last so it captures the appearance above it,
                // and the shape is passed in rather than clipped afterwards —
                // `glassEffect(_:in:)` needs the shape to place the specular edge
                // and the rim refraction, which a later `.clipShape` would cut.
                .glassEffect(Token.Material.hud, in: Token.shape(radius: Self.radius))
        }
        // The specular rim, on the *container* rather than inside it. Applied
        // inside, the glass composites the stroke and it comes out diffuse while
        // the waveform in the same frame stays crisp — which is what identified
        // it. Never a `clipShape`: that cuts the edge the material itself draws
        // outside the path (§6.1).
        .overlay {
            Token.shape(radius: Self.radius)
                .strokeBorder(
                    Token.Authored.Specular.rim,
                    lineWidth: Token.Authored.Specular.width
                )
        }
        // The panel is deliberately larger than any state so the glass can grow
        // without the window resizing (`HUDPanel`), which means the surface has
        // to say where in that canvas it sits. Centre: the HUD is anchored to the
        // middle of the screen's top edge, and both dimensions follow from that.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // This is the pin. An explicit `colorScheme` wins over the appearance
        // the glass would otherwise hand its own content — verified against a
        // backdrop/override matrix, `rules/design.md` §6.7. The *surface* still
        // tints and refracts from whatever is behind it, which is the material
        // doing its job and is not what was asked to hold still.
        .environment(\.colorScheme, appearance)
        .animation(.easeOut(duration: 0.22), value: widthKey)
    }

    /// What a width change should animate against. Level changes move bars, not
    /// the surface, so they must not retrigger the 220 ms ease-out (§5's motion
    /// table).
    private var widthKey: String {
        switch state {
        case .recording: "recording"
        case .message(let s), .error(let s): s
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .recording(let level):
            Waveform(level: level, running: running)
        case .message(let text):
            Text(text)
                // `.callout` is 12 pt. The 13 pt in `sotto-tokens.md` was never
                // authored — it was `.body` all along (`DECISIONS.md`).
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .fixedSize()
        case .error(let text):
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

/// The one element in Sotto with no system precedent, and therefore the one place
/// tier 2 was pre-approved before its slice started (§14.3).
///
/// **Symmetric about the centre line**, because a waveform grounded on a baseline
/// reads as a bar chart. Resting bars are dots — height equal to width — so the
/// idle state is a row of dots rather than an absence.
struct Waveform: View {
    let level: Double
    let running: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Named, not inlined: this is the recording state's whole width claim.
    /// `count * barWidth + (count - 1) * barGap`.
    static var width: CGFloat {
        let bar = Token.Authored.Waveform.self
        return CGFloat(bar.count) * bar.barWidth + CGFloat(bar.count - 1) * bar.barGap
    }

    var body: some View {
        // `.animation` drives a redraw per frame off the display link, and
        // `paused:` is what stops it — the link does *not* stop on its own when
        // the panel is ordered out (`HUDView.running`). A `Timer` would keep
        // running there too, and with no equivalent switch.
        TimelineView(.animation(paused: !running)) { timeline in
            let t = time(timeline.date)
            HStack(spacing: Token.Authored.Waveform.barGap) {
                ForEach(0..<Token.Authored.Waveform.count, id: \.self) { i in
                    // `Capsule`, not a continuous rounded rect: a 3.5 pt bar's
                    // cap is a semicircle either way, and writing `.continuous`
                    // at `r = h/2` claims a squircle the geometry cannot produce.
                    Capsule()
                        .fill(Token.Accent.primary)
                        .frame(
                            width: Token.Authored.Waveform.barWidth,
                            height: height(bar: i, at: t)
                        )
                }
            }
        }
        .frame(width: Self.width, height: Token.Authored.Waveform.peak)
    }

    /// **Reduce Motion snaps rather than stops.** A frozen waveform would assert
    /// that capture had stalled, which is the opposite of what the setting asks
    /// for — the waveform is the only confirmation that Sotto is hearing anything,
    /// so it steps at 8 Hz instead of animating continuously (§14.4).
    private func time(_ date: Date) -> Double {
        let t = date.timeIntervalSinceReferenceDate
        return reduceMotion ? (t * 8).rounded(.down) / 8 : t
    }

    /// Two sine terms whose periods share no common multiple, so the pattern
    /// never visibly loops — §6.2's "uneven and drifting" without storing a
    /// history. `level` scales it; the resting height is a dot, never zero.
    private func height(bar i: Int, at t: Double) -> CGFloat {
        let phase = Double(i) * 0.7
        let a = sin(t * 2.3 + phase) * 0.5 + 0.5
        let b = sin(t * 3.7 + phase * 1.9) * 0.5 + 0.5
        // `v^0.5` from §6.2: loudness is perceptual, so the tall end compresses.
        let envelope = pow((a * 0.65 + b * 0.35) * max(0, min(1, level)), 0.5)
        return max(Token.Authored.Waveform.resting, Token.Authored.Waveform.peak * envelope)
    }
}
