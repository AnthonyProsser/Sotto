//
//  BackdropSampleTests.swift
//  Sotto
//
//  The polarity mapping — luminance averaging and the light/dark ruling
//  (`OverlayPanel` pins the window appearance from it). The capture itself
//  needs a real screen and grant; it is verified on screen, not here.
//

import Testing
@testable import Sotto
import AppKit
import CoreGraphics
import Foundation

@MainActor
struct BackdropSampleTests {

    /// A solid-colour CGImage of the given 0–255 grey.
    private func solidImage(_ value: UInt8) -> CGImage {
        let context = CGContext(
            data: nil, width: 8, height: 8,
            bitsPerComponent: 8, bytesPerRow: 8 * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(NSColor(white: CGFloat(value) / 255, alpha: 1).cgColor)
        context.fill(NSRect(x: 0, y: 0, width: 8, height: 8))
        return context.makeImage()!
    }

    @Test func whiteReadsNearOne() {
        #expect(BackdropSample.meanLuminance(of: solidImage(255))! > 0.99)
    }

    @Test func blackReadsNearZero() {
        #expect(BackdropSample.meanLuminance(of: solidImage(0))! < 0.01)
    }

    @Test func midGreyReadsMid() {
        let luminance = BackdropSample.meanLuminance(of: solidImage(128))!
        #expect(luminance > 0.45 && luminance < 0.55)
    }

    @Test func aWhiteBackdropIsLightAndADarkOneIsNot() {
        #expect(BackdropSample.isLight(BackdropSample.meanLuminance(of: solidImage(255))!))
        #expect(!BackdropSample.isLight(BackdropSample.meanLuminance(of: solidImage(20))!))
    }

    @Test func thresholdSitsAtHalf() {
        #expect(!BackdropSample.isLight(0.49))
        #expect(BackdropSample.isLight(0.5))
    }
}
