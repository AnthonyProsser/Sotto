//
//  AudioPlayback.swift
//  Sotto
//
//  Slice 6. Playing a stored recording, and the seek §9.3 is built around.
//

import AVFoundation
import Foundation
import Observation

/// One player for the whole app, because one recording plays at a time.
///
/// **`AVAudioPlayer` decodes the Opus-in-CAF file directly** — verified against a
/// real slice 5 entry on 2026-08-20, alongside `AVAudioFile` for the envelope and
/// `AVURLAsset` for duration. Slice 5's note that Opus is "decoded on demand"
/// turns out to need no decoding stage of Sotto's own.
@MainActor
@Observable
final class AudioPlayback {
    static let shared = AudioPlayback()

    /// **Ships at zero, and this is the hook §9.3 asks be kept** (`rules/audio-and-transcription.md`
    /// §2). Word starts err early and the error saturates at about −320 ms, which
    /// is the beat of lead-in an audio editor adds deliberately — so a correction
    /// would be removing a feature. Nothing writes this.
    static var seekOffset: TimeInterval = 0

    private(set) var id: String?
    private(set) var isPlaying = false
    private(set) var time: TimeInterval = 0
    private(set) var duration: TimeInterval = 0

    /// The drawn envelope, 0…1, normalised to the recording's own loudest moment
    /// so a quiet dictation still fills the strip. Empty until the decode lands —
    /// `PlaybackWaveform` draws a flat line meanwhile rather than a spinner.
    private(set) var peaks: [CGFloat] = []

    /// Resolution of the decode, not of the drawing. The strip resamples this down
    /// to whatever bar count its width allows, so resizing the window costs no
    /// second decode.
    nonisolated private static let buckets = 1024

    private var player: AVAudioPlayer?
    private var ticker: Timer?

    private init() {}

    var progress: Double {
        duration > 0 ? min(1, max(0, time / duration)) : 0
    }

    // MARK: - Transport

    /// Idempotent per recording: selecting the same row twice does not restart it.
    /// The id is committed only after the player exists, so a missing or unreadable
    /// file can be asked again instead of leaving Play dead on that row.
    func load(_ recording: AudioLibrary.Recording) {
        guard id != recording.id else { return }
        stop()
        guard let player = try? AVAudioPlayer(contentsOf: recording.audio) else { return }
        player.prepareToPlay()
        self.player = player
        id = recording.id
        duration = player.duration

        let url = recording.audio
        Task.detached(priority: .utility) {
            let drawn = Self.envelope(of: url, buckets: Self.buckets)
            await MainActor.run {
                guard self.id == recording.id else { return }
                self.peaks = drawn
            }
        }
    }

    func playPause() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            ticker?.invalidate()
        } else {
            // Restart from the top when the last play ran to the end, which is
            // what every system transport does with a finished track.
            if player.currentTime >= player.duration - 0.05 { player.currentTime = 0 }
            player.play()
            isPlaying = true
            startTicking()
        }
        time = player.currentTime
    }

    /// Where click-to-seek lands (§9.3), and where dragging the envelope lands.
    /// Playing continues if it was playing; a seek while paused moves the playhead
    /// and stays paused, which is what makes the transcript usable as an index.
    func seek(to seconds: TimeInterval) {
        guard let player else { return }
        let target = min(max(0, seconds + Self.seekOffset), player.duration)
        player.currentTime = target
        time = target
    }

    func stop() {
        ticker?.invalidate()
        ticker = nil
        player?.stop()
        player = nil
        id = nil
        isPlaying = false
        time = 0
        duration = 0
        peaks = []
    }

    // MARK: -

    /// 30 Hz, and only while playing. **Polled rather than delegated**: the finish
    /// callback is the only thing `AVAudioPlayerDelegate` would carry, and taking
    /// it means an `NSObject` shim and a nonisolated hop for one bool that this
    /// timer already has to read.
    private func startTicking() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard let player else { return }
        time = player.currentTime
        if !player.isPlaying {
            isPlaying = false
            ticker?.invalidate()
            ticker = nil
        }
    }

    nonisolated static func envelope(of url: URL, buckets: Int) -> [CGFloat] {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0, buckets > 0 else { return [] }
        let format = file.processingFormat
        let perBucket = max(1, Int(file.length) / buckets)
        // Capacity covers the remainder as well as one bucket: the last bucket
        // absorbs what integer division leaves over, up to `buckets - 1` frames.
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(perBucket + buckets)
        ) else { return [] }

        var levels: [CGFloat] = []
        levels.reserveCapacity(buckets)
        var loudest: Float = 0

        // **Bounded by `buckets`, not by the file.** Reading a fixed window until
        // EOF returned `buckets + 1` levels whenever the length did not divide
        // exactly — a short final bucket whose peak was measured over fewer
        // frames than every other one (found by test, 2026-08-20).
        while levels.count < buckets, file.framePosition < file.length {
            let remaining = Int(file.length - file.framePosition)
            let frames = levels.count == buckets - 1 ? remaining : min(perBucket, remaining)
            do { try file.read(into: buffer, frameCount: AVAudioFrameCount(frames)) } catch { break }
            guard buffer.frameLength > 0, let samples = buffer.floatChannelData?[0] else { break }
            var peak: Float = 0
            for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(samples[i])) }
            loudest = max(loudest, peak)
            levels.append(CGFloat(peak))
        }

        guard loudest > 0 else { return levels.map { _ in 0 } }
        return levels.map { $0 / CGFloat(loudest) }
    }
}
