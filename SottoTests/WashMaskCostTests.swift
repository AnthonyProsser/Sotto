import Testing
@testable import Sotto
import Foundation
import CoreGraphics

/// Pins the cost and the output of the wash mask's per-pixel SDF.
///
/// The cost test exists because the PR #24 review claimed main-thread jank and
/// the first measurement proved it real: 659 ms for the largest size in a
/// Debug build (2026-09-02), which is what moved generation onto a background
/// queue. The ceiling below is a Debug-build tripwire — Release runs several
/// times faster — meant to catch the order-of-magnitude regressions (an
/// accidental O(n²)) that would read as a hitch even off-main.
///
/// The equivalence test is how "nothing drawn changed" is proven for that
/// move: the paired one-pass generator must be byte-identical to the
/// per-ceiling two-pass loop it replaced, because the scrim mask and the blur
/// `maskImage` have to agree at the edge.
struct WashMaskCostTests {
    /// MainActor because `WashView`'s constants are main-actor-isolated through
    /// `NSViewRepresentable` (the same rule `washMasks`'s own comment explains).
    @Test @MainActor func maskCostAtRealisticSizes() throws {
        // Docked column at 2x: 1040 px wide; ~1380 px tall on the reference
        // machine's screen, ~2880 px on a 5K-height display with the column at
        // its 70 %-of-visible cap. One call = the whole per-event cost: one
        // SDF pass writing both ceilings.
        for (width, height) in [(1040, 1380), (1040, 2880)] {
            let clock = ContinuousClock()
            let start = clock.now
            let pair = WashView.FieldView.washMasks(
                width: width, height: height,
                feather: WashView.feather * 2, radius: WashView.cornerRadius * 2,
                exponent: WashView.cornerExponent,
                ceilings: (scrim: 1, blur: WashView.blurMix))
            let elapsed = clock.now - start

            #expect(pair.scrim != nil)
            #expect(pair.blur != nil)
            let ms = Double(elapsed.components.seconds) * 1000
                + Double(elapsed.components.attoseconds) / 1e15
            print("washMasks \(width)×\(height), both ceilings, one pass: \(String(format: "%.1f", ms)) ms")
            // 5000 is a Debug-build tripwire, deliberately loose: the suite runs
            // tests in parallel and this loop measured 1106 ms under that
            // contention against ~330 ms alone (2026-09-02), so anything tighter
            // flakes on a busy machine. The regressions it exists to catch — an
            // accidental O(n²), a copy per consumer — land in the tens of
            // seconds at these sizes, far above it. The print is the real signal.
            #expect(ms < 5000)
        }
    }

    @Test @MainActor func pairedOutputMatchesThePerCeilingReference() throws {
        let width = 160, height = 120
        let scale: CGFloat = 2
        let pair = WashView.FieldView.washMasks(
            width: width, height: height,
            feather: WashView.feather * scale, radius: WashView.cornerRadius * scale,
            exponent: WashView.cornerExponent,
            ceilings: (scrim: 1, blur: WashView.blurMix))
        let referenceScrim = try referenceWashMask(
            width: width, height: height,
            feather: WashView.feather * scale, radius: WashView.cornerRadius * scale,
            exponent: WashView.cornerExponent, ceiling: 1)
        let referenceBlur = try referenceWashMask(
            width: width, height: height,
            feather: WashView.feather * scale, radius: WashView.cornerRadius * scale,
            exponent: WashView.cornerExponent, ceiling: WashView.blurMix)

        guard let scrimImage = pair.scrim, let blurImage = pair.blur else {
            Issue.record("washMasks returned nil images")
            return
        }
        #expect(try bitmapBytes(scrimImage) == bitmapBytes(referenceScrim))
        #expect(try bitmapBytes(blurImage) == bitmapBytes(referenceBlur))
    }

    /// Verbatim copy of the per-ceiling implementation `washMasks` replaced
    /// (WashView.swift before 2026-09-02) — the reference the pairing is
    /// checked against. Do not modernise it; its value is that it is the old
    /// code exactly.
    private func referenceWashMask(
        width: Int, height: Int, feather: CGFloat, radius: CGFloat,
        exponent n: CGFloat, ceiling: CGFloat
    ) throws -> CGImage {
        let w = CGFloat(width), h = CGFloat(height)
        let f = max(feather, 1)
        let r = max(min(radius, min(w, h) / 2), 0)
        let halfW = w / 2, halfH = h / 2
        let flatW = halfW - r, flatH = halfH - r

        var data = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let qy = abs(CGFloat(y) + 0.5 - halfH) - flatH
            for x in 0..<width {
                let qx = abs(CGFloat(x) + 0.5 - halfW) - flatW
                let signed: CGFloat = (qx > 0 && qy > 0)
                    ? pow(pow(qx, n) + pow(qy, n), 1 / n) - r
                    : max(qx, qy) - r
                data[(y * width + x) * 4 + 3] = UInt8((referenceSmooth(-signed / f) * ceiling * 255).rounded())
            }
        }

        var image: CGImage?
        data.withUnsafeMutableBytes { (ptr: UnsafeMutableRawBufferPointer) in
            let ctx = CGContext(
                data: ptr.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
            )
            image = ctx?.makeImage()
        }
        guard let image else { throw CocoaError(.fileReadUnknown) }
        return image
    }

    private func referenceSmooth(_ t: CGFloat) -> CGFloat {
        let x = max(0, min(t, 1))
        return x * x * (3 - 2 * x)
    }

    private func bitmapBytes(_ image: CGImage) throws -> [UInt8] {
        guard let data = image.dataProvider?.data else { throw CocoaError(.fileReadUnknown) }
        let length = CFDataGetLength(data)
        guard let ptr = CFDataGetBytePtr(data) else { throw CocoaError(.fileReadUnknown) }
        return [UInt8](UnsafeBufferPointer(start: ptr, count: length))
    }
}
