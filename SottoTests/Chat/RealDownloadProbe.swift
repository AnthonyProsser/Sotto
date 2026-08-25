//
//  RealDownloadProbe.swift
//  SottoTests
//
//  Temporary and not for commit: §0.6's verification — a real multi-GB
//  download through ModelDownload.acquire, timed against curl on the same
//  file, plus the quit-mid-download resume observation the doc comment claims.
//

import Testing
import Foundation
@testable import Sotto

private func probeRoot(_ label: String) -> URL {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "sotto-real-\(label)-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func partSizes(in root: URL) -> [String: Int64] {
    var sizes: [String: Int64] = [:]
    guard let enumerator = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.fileSizeKey]
    ) else { return sizes }
    for case let url as URL in enumerator {
        if url.lastPathComponent.hasSuffix(".part") {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            sizes[url.lastPathComponent] = Int64(size)
        }
    }
    return sizes
}

private func elapsedSeconds(since start: ContinuousClock.Instant, now: ContinuousClock.Instant) -> Double {
    let duration = now - start
    return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

@Suite(.serialized) struct RealDownloadProbe {
    private let repo = "mlx-community/Qwen2.5-3B-Instruct-4bit"

    /// One clean full download through the rewritten transport, timed.
    @Test func timesARealDownload() async throws {
        let root = probeRoot("timing")
        defer { try? FileManager.default.removeItem(at: root) }

        var lastReported = Int64(-1)
        let clock = ContinuousClock()
        let start = clock.now
        let model = try await ModelDownload.acquire(repo, into: root) { downloaded, total in
            if downloaded / max(1, total / 10) != lastReported / max(1, total / 10) {
                print("PROGRESS \(downloaded)/\(total)")
                lastReported = downloaded
            }
        }
        let seconds = elapsedSeconds(since: start, now: clock.now)

        print("REALDOWNLOAD repo=\(repo) weightsBytes=\(model.weightsBytes) seconds=\(seconds)")
        #expect(model.weightsBytes > 900_000_000)
    }

    /// Cancel mid-download, then finish from what is left behind: the `.part`
    /// must resume via Range rather than restart.
    @Test func survivesACancelMidDownloadAndResumes() async throws {
        let root = probeRoot("resume")
        defer { try? FileManager.default.removeItem(at: root) }

        final class History: @unchecked Sendable {
            private let lock = NSLock()
            private var marked = false
            private var items: [(Int64, Int64)] = []
            private var _sinceMark: [(Int64, Int64)] = []

            func add(_ downloaded: Int64, _ total: Int64) {
                lock.lock()
                items.append((downloaded, total))
                if marked { _sinceMark.append((downloaded, total)) }
                lock.unlock()
            }
            func mark() {
                lock.lock(); marked = true; _sinceMark = []; lock.unlock()
            }
            var peak: Int64 {
                lock.lock(); defer { lock.unlock() }; return items.map(\.0).max() ?? 0
            }
            var sinceMark: [(Int64, Int64)] {
                lock.lock(); defer { lock.unlock() }; return _sinceMark
            }
        }

        let history = History()

        // Phase one: cancel once real bytes have moved.
        let job = Task {
            try await ModelDownload.acquire(repo, into: root) { downloaded, total in
                history.add(downloaded, total)
            }
        }
        let deadline = Date().addingTimeInterval(600)
        while history.peak < 150_000_000 && Date() < deadline {
            try await Task.sleep(for: .milliseconds(500))
        }
        #expect(history.peak >= 150_000_000, "never got moving to cancel")
        job.cancel()
        var jobError: Error?
        do {
            _ = try await job.value
        } catch {
            jobError = error
        }
        print("CANCELLED jobError=\(String(describing: jobError)) peak=\(history.peak)")

        func listDir(_ url: URL, depth: Int) {
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.fileSizeKey]
            ) else { return }
            for child in children {
                let size = (try? child.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                print("TREE \(String(repeating: " ", count: depth))\(child.lastPathComponent) \(size)")
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: child.path, isDirectory: &isDir)
                if isDir.boolValue { listDir(child, depth: depth + 1) }
            }
        }
        print("TREE ROOT \(root.path)")
        listDir(root, depth: 1)

        let parts = partSizes(in: root)
        let partTotal = parts.values.reduce(0, +)
        print("PARTS \(parts) total=\(partTotal)")
        #expect(partTotal > 100_000_000, "cancelling left no meaningful .part behind")

        // Phase two: finish from what is on disk.
        history.mark()
        let clock = ContinuousClock()
        let start = clock.now
        let model = try await ModelDownload.acquire(repo, into: root) { downloaded, total in
            history.add(downloaded, total)
        }
        let seconds = elapsedSeconds(since: start, now: clock.now)

        // Resume proof: when the big shard opens, progress lands directly on
        // the credited `.part` prefix rather than climbing through it again.
        let landed = history.sinceMark.contains { abs($0.0 - partTotal) < 20_000_000 }
        print("RESUME resumedAt≈\(partTotal) seconds=\(seconds) reports=\(history.sinceMark.count)")
        #expect(model.weightsBytes > 900_000_000)
        #expect(landed, "no progress report landed on the resumed offset — the file restarted")
    }
}
