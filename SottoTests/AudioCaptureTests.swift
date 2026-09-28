//
//  AudioCaptureTests.swift
//  SottoTests
//
//  Microphone selection is stored by UID and resolved against the live device
//  list. The test host is Sotto itself, so the real preference key is saved and
//  restored around every test.
//

import Foundation
import Testing
@testable import Sotto

@Suite(.serialized)
struct AudioCaptureTests {
    private static let key = "InputDeviceUID"

    private func preservingSelection(_ body: () throws -> Void) rethrows {
        let saved = UserDefaults.standard.object(forKey: Self.key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: Self.key) }
            else { UserDefaults.standard.removeObject(forKey: Self.key) }
        }
        try body()
    }

    @Test func noStoredUIDMeansSystemDefault() {
        preservingSelection {
            UserDefaults.standard.removeObject(forKey: Self.key)
            #expect(AudioCapture.shared.selectedDevice == nil)
        }
    }

    @Test func aStoredUIDResolvesToTheSameDeviceAndClearingReturnsToDefault() throws {
        try preservingSelection {
            let device = try #require(AudioCapture.inputDevices().first, "no input device on this machine")
            AudioCapture.shared.selectedDevice = device
            let stored = try #require(UserDefaults.standard.string(forKey: Self.key))
            #expect(!stored.isEmpty)
            #expect(AudioCapture.shared.selectedDevice == device)

            AudioCapture.shared.selectedDevice = nil
            #expect(UserDefaults.standard.string(forKey: Self.key) == nil)
            #expect(AudioCapture.shared.selectedDevice == nil)
        }
    }

    /// The unplugged-device case at rest: the stored UID matches nothing, so the
    /// selection resolves to `nil` and `arm()` falls back to the system default
    /// (silently — the menu bar just no longer shows a checkmark).
    @Test func aUIDForAMissingDeviceResolvesToNil() {
        preservingSelection {
            UserDefaults.standard.set("no-such-device-UID", forKey: Self.key)
            #expect(AudioCapture.shared.selectedDevice == nil)
        }
    }

    @Test func theDefaultInputDeviceIsOneOfTheListedInputs() throws {
        let id = try #require(AudioCapture.defaultInputDevice(), "no default input device")
        #expect(AudioCapture.inputDevices().contains { $0.id == id })
    }
}
