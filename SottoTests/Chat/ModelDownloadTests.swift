//
//  ModelDownloadTests.swift
//  SottoTests
//
//  Slice 8's acquisition plumbing against a stubbed URLProtocol, never the
//  network: what survives the manifest filter, download → verify → promote,
//  resume across launches through an HTTP Range, corrupt-payload discard, and
//  the already-on-disk rung winning before any byte moves.
//

import Testing
import Foundation
import CryptoKit
@testable import Sotto

// MARK: - The stub

private struct StubResponse: Sendable {
    var status: Int
    var headers: [String: String]
    var body: Data
}

private typealias Route = @Sendable (URLRequest) -> StubResponse

/// Route table plus a request counter, shared across the stub's loading threads.
private final class StubState: @unchecked Sendable {
    static let shared = StubState()
    private let lock = NSLock()
    private var routes: [String: Route] = [:]
    private var requests = 0

    var requestCount: Int {
        lock.lock(); defer { lock.unlock() }; return requests
    }

    func reset(routes newRoutes: [String: Route]) {
        lock.lock(); routes = newRoutes; requests = 0; lock.unlock()
    }

    func response(for path: String, request: URLRequest) -> StubResponse? {
        lock.lock(); requests += 1; let route = routes[path]; lock.unlock()
        return route?(request)
    }
}

private final class StubHTTPProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = StubState.shared.response(for: url.path, request: request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let http = HTTPURLResponse(
            url: url,
            statusCode: response.status,
            httpVersion: nil,
            headerFields: response.headers
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// An ephemeral session whose every exchange lands in the route table.
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubHTTPProtocol.self]
        return URLSession(configuration: configuration)
    }
}

/// Honours `Range` the way the CDN does, and records whether a resume arrived.
private func rangedServer(_ body: Data, sawRange: Locked<Bool>) -> Route {
    { request in
        if let range = request.value(forHTTPHeaderField: "Range"),
           let offset = Int(range.dropFirst("bytes=".count).dropLast()) {
            sawRange.set(true)
            return StubResponse(
                status: 206,
                headers: ["Content-Range": "bytes \(offset)-\(body.count - 1)/\(body.count)"],
                body: Data(body.dropFirst(offset))
            )
        }
        return StubResponse(status: 200, headers: [:], body: body)
    }
}

// MARK: - Small shared pieces

/// Locks one value so stub threads and the test task can share it.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value

    init(_ value: Value) { _value = value }

    var value: Value {
        lock.lock(); defer { lock.unlock() }; return _value
    }

    func set(_ value: Value) {
        lock.lock(); _value = value; lock.unlock()
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _last: (downloaded: Int64, total: Int64)?

    func record(_ downloaded: Int64, _ total: Int64) {
        lock.lock(); _last = (downloaded, total); lock.unlock()
    }

    var last: (downloaded: Int64, total: Int64)? {
        lock.lock(); defer { lock.unlock() }; return _last
    }
}

@discardableResult
private func tempRoot() -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: "sotto-download-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func randomBytes(_ count: Int) -> Data {
    Data((0..<count).map { _ in UInt8.random(in: .min ... .max) })
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func manifestJSON(siblings: [String]) -> String {
    "{\"siblings\":[\(siblings.joined(separator: ","))]}"
}

private func siblingJSON(name: String, size: Int, sha256: String? = nil) -> String {
    let lfs = sha256.map { ",\"lfs\":{\"oid\":\"\($0)\",\"size\":\(size)}" } ?? ""
    return "{\"rfilename\":\"\(name)\",\"size\":\(size)\(lfs)}"
}

/// The smallest config `CapabilityRegistry.parseMLXConfig` accepts, so a
/// promoted download loads as a real `LocalModel`.
private let minimalConfig = """
{"model_type":"llama","num_hidden_layers":4,"num_attention_heads":8,
 "num_key_value_heads":2,"hidden_size":512,"head_dim":64,"max_position_embeddings":8192}
"""

// MARK: - Tests

/// The stub's route table is process-global, so members must not race it.
@Suite(.serialized) struct ModelDownloadTests {

    @Test func manifestKeepsOnlyTheFilesMLXLoads() async throws {
        let weights = randomBytes(64)
        StubState.shared.reset(routes: [
            "/api/models/acme/tiny": { _ in
                StubResponse(status: 200, headers: [:], body: Data(manifestJSON(siblings: [
                    siblingJSON(name: "README.md", size: 10),
                    siblingJSON(name: ".gitattributes", size: 8),
                    siblingJSON(name: "config.json", size: 123),
                    siblingJSON(name: "model.safetensors", size: weights.count, sha256: sha256Hex(weights)),
                    siblingJSON(name: "tokenizer.json", size: 456)
                ]).utf8))
            }
        ])

        let manifest = try await ModelDownload.manifest(for: "acme/tiny", session: StubHTTPProtocol.session())

        #expect(manifest.files.map(\.name) == ["config.json", "model.safetensors", "tokenizer.json"])
        let weightsFile = try #require(manifest.files.first { $0.name == "model.safetensors" })
        #expect(weightsFile.sha256 == sha256Hex(weights))
        #expect(weightsFile.size == Int64(weights.count))
    }

    @Test func acquireDownloadsVerifiesAndPromotes() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let weights = randomBytes(4096)
        let config = Data(minimalConfig.utf8)
        let tokenizer = Data("{\"pad\":\"<unk>\"}".utf8)

        StubState.shared.reset(routes: [
            "/api/models/acme/tiny": { _ in
                StubResponse(status: 200, headers: [:], body: Data(manifestJSON(siblings: [
                    siblingJSON(name: "config.json", size: config.count),
                    siblingJSON(name: "tokenizer.json", size: tokenizer.count),
                    siblingJSON(name: "model.safetensors", size: weights.count, sha256: sha256Hex(weights))
                ]).utf8))
            },
            "/acme/tiny/resolve/main/config.json": { _ in
                StubResponse(status: 200, headers: [:], body: config)
            },
            "/acme/tiny/resolve/main/tokenizer.json": { _ in
                StubResponse(status: 200, headers: [:], body: tokenizer)
            },
            "/acme/tiny/resolve/main/model.safetensors": { _ in
                StubResponse(status: 200, headers: [:], body: weights)
            }
        ])

        let progress = ProgressRecorder()
        let model = try await ModelDownload.acquire(
            "acme/tiny",
            into: root,
            session: StubHTTPProtocol.session()
        ) { downloaded, total in
            progress.record(downloaded, total)
        }

        // Promoted and loadable: §9.1's id is the directory name, §2.3 sizes off
        // the safetensors actually present.
        #expect(model.id == "tiny")
        #expect(model.weightsBytes == Int64(weights.count))
        #expect(ModelStore.discover(in: root).map(\.id) == ["tiny"])

        // Nothing staged survives the promotion.
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: ".incomplete-tiny").path))

        // What landed is byte-for-byte what was served.
        #expect(try Data(contentsOf: root.appending(path: "tiny/model.safetensors")) == weights)

        // Progress ends at the manifest's total, having counted every file.
        let total = Int64(config.count + tokenizer.count + weights.count)
        #expect(progress.last?.total == total)
        #expect(progress.last?.downloaded == total)
    }

    /// The cross-launch case: a `.part` left behind by a quit mid-download is
    /// appended to over a Range request, never duplicated and never restarted.
    @Test func resumesAPartAcrossLaunchesWithoutDuplicatingIt() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let weights = randomBytes(8192)
        let resumed = Locked(false)
        let config = Data(minimalConfig.utf8)

        let staging = root.appending(path: ".incomplete-tiny")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data(weights.prefix(3000)).write(to: staging.appending(path: "model.safetensors.part"))

        StubState.shared.reset(routes: [
            "/api/models/acme/tiny": { _ in
                StubResponse(status: 200, headers: [:], body: Data(manifestJSON(siblings: [
                    siblingJSON(name: "config.json", size: config.count),
                    siblingJSON(name: "model.safetensors", size: weights.count, sha256: sha256Hex(weights))
                ]).utf8))
            },
            "/acme/tiny/resolve/main/config.json": { _ in
                StubResponse(status: 200, headers: [:], body: config)
            },
            "/acme/tiny/resolve/main/model.safetensors": rangedServer(weights, sawRange: resumed)
        ])

        _ = try await ModelDownload.acquire("acme/tiny", into: root, session: StubHTTPProtocol.session())

        #expect(resumed.value)
        let assembled = try Data(contentsOf: root.appending(path: "tiny/model.safetensors"))
        #expect(assembled == weights)
    }

    @Test func discardsACorruptPayloadInsteadOfKeepingIt() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let genuine = randomBytes(2048)
        let corrupt = randomBytes(2048)  // same length, wrong bytes
        let config = Data(minimalConfig.utf8)

        StubState.shared.reset(routes: [
            "/api/models/acme/tiny": { _ in
                StubResponse(status: 200, headers: [:], body: Data(manifestJSON(siblings: [
                    siblingJSON(name: "config.json", size: config.count),
                    siblingJSON(name: "model.safetensors", size: corrupt.count, sha256: sha256Hex(genuine))
                ]).utf8))
            },
            "/acme/tiny/resolve/main/config.json": { _ in
                StubResponse(status: 200, headers: [:], body: config)
            },
            "/acme/tiny/resolve/main/model.safetensors": { _ in
                StubResponse(status: 200, headers: [:], body: corrupt)
            }
        ])

        do {
            _ = try await ModelDownload.acquire("acme/tiny", into: root, session: StubHTTPProtocol.session())
            Issue.record("A hash mismatch must stop the acquisition")
        } catch let error as ModelDownloadError {
            guard case .integrityFailed = error else {
                Issue.record("expected integrityFailed, got \(error)")
                return
            }
        }

        // Never selectable: no promoted model, and the corrupt copy is gone so
        // a retry refetches it rather than keeping the corruption (§7.4).
        #expect(ModelStore.discover(in: root).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "tiny").path))
        #expect(!FileManager.default.fileExists(
            atPath: root.appending(path: ".incomplete-tiny/model.safetensors").path
        ))
    }

    @Test func prefersWhatIsAlreadyOnDiskOverAnyRequest() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let directory = root.appending(path: "tiny")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(minimalConfig.utf8).write(to: directory.appending(path: "config.json"))
        try randomBytes(1024).write(to: directory.appending(path: "model.safetensors"))

        // No routes configured at all: any network attempt fails loudly.
        StubState.shared.reset(routes: [:])

        let model = try await ModelDownload.acquire("acme/tiny", into: root, session: StubHTTPProtocol.session())

        #expect(model.id == "tiny")
        #expect(StubState.shared.requestCount == 0)
    }

    /// Hand-placed weights caught halfway through being copied: the name is
    /// taken but the directory loads as nothing. That must fail typed before
    /// any byte moves — never as a raw FileManager error at the promotion.
    @Test func aNameTakenByAnUnusableDirectoryFailsTypedBeforeAnythingMoves() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let directory = root.appending(path: "tiny")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(minimalConfig.utf8).write(to: directory.appending(path: "config.json"))
        let placedConfig = try Data(contentsOf: directory.appending(path: "config.json"))

        // No routes configured: proving the failure costs no request at all.
        StubState.shared.reset(routes: [:])

        do {
            _ = try await ModelDownload.acquire("acme/tiny", into: root, session: StubHTTPProtocol.session())
            Issue.record("A usable model's name taken by an unusable directory must fail")
        } catch let error as ModelDownloadError {
            guard case .downloadFailed = error else {
                Issue.record("expected downloadFailed, got \(error)")
                return
            }
        }

        // Nothing moved and nothing of the user's was touched.
        #expect(StubState.shared.requestCount == 0)
        #expect(try Data(contentsOf: directory.appending(path: "config.json")) == placedConfig)
        #expect(!FileManager.default.fileExists(
            atPath: directory.appending(path: "model.safetensors").path
        ))
    }

    @Test func aRepoWithNothingToLoadFailsTheResolutionNotThePromotion() async throws {
        StubState.shared.reset(routes: [
            "/api/models/acme/readme-only": { _ in
                StubResponse(status: 200, headers: [:], body: Data(manifestJSON(siblings: [
                    siblingJSON(name: "README.md", size: 10)
                ]).utf8))
            }
        ])

        do {
            _ = try await ModelDownload.manifest(for: "acme/readme-only", session: StubHTTPProtocol.session())
            Issue.record("A repo with no MLX files must not resolve")
        } catch let error as ModelDownloadError {
            guard case .manifestFailed = error else {
                Issue.record("expected manifestFailed, got \(error)")
                return
            }
        }
    }
}
