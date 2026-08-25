import Foundation
import CryptoKit
import os

/// Download-source failures. Routed to the model list where the download was
/// started (§14.3) — never the HUD; this is not a dictation failure.
nonisolated enum ModelDownloadError: LocalizedError, Equatable {
    case manifestFailed(String)
    case downloadFailed(String)
    case integrityFailed(String)

    var errorDescription: String? {
        switch self {
        case .manifestFailed(let reason):
            return "Model lookup failed: \(reason)"
        case .downloadFailed(let reason):
            return "Download failed: \(reason)"
        case .integrityFailed(let reason):
            return "Download failed verification: \(reason)"
        }
    }
}

/// §7.4's second rung: resolving a Hugging Face `repo_id` and fetching MLX
/// weights from it.
///
/// The ladder's order lives here end to end — an already-on-disk model wins
/// before a single byte moves, matching `ModelStore`'s discovery. Nothing
/// schedules, retries, or re-checks on its own, so principle 1's consent rule
/// holds structurally: the only caller is the surface whose button the user
/// pressed. No background re-download and no auto-update; acquiring a repo
/// that is already on disk returns what is on disk.
///
/// Files are fetched from `resolve/<commit-sha>` — the same snapshot the
/// manifest came from — rather than the moving `resolve/main` ref, so the
/// bytes and the hashes they are checked against cannot disagree.
///
/// Resume shape is the stitcher's (§10.3): each file lands as `<name>.part`
/// and appends across launches via an HTTP `Range` request, so cancelling or
/// quitting keeps progress (a server that answers `200` to the range restarts
/// the file rather than corrupting it). A partially downloaded model is never
/// selectable: everything stages under a dot-prefixed directory that
/// `ModelStore.discover` skips, and the finished set is promoted by one rename
/// only after every file has passed its size and SHA-256 checks against the
/// source manifest. A file that fails verification is deleted, so the retry
/// refetches it instead of keeping the corruption.
nonisolated enum ModelDownload {
    private static let log = Logger(subsystem: "com.anthonyprosser.Sotto", category: "model-download")

    /// Read size when hashing a file for verification.
    private static let chunkBytes = 1 << 20

    typealias ProgressHandler = @Sendable (_ downloadedBytes: Int64, _ totalBytes: Int64) -> Void

    /// One file of a repo, with what the manifest says about verifying it.
    nonisolated struct RemoteFile: Sendable, Equatable {
        /// Repo-relative path, e.g. `"model.safetensors"`.
        let name: String
        /// Total bytes when reported (`blobs=true` always reports it).
        let size: Int64?
        /// The LFS blob's SHA-256, hex. Nil for small files stored inline in git.
        let sha256: String?
    }

    /// The files of one repo Sotto will fetch. Only what MLX loads — weights,
    /// configs, tokenizer — never `README.md` or git metadata.
    nonisolated struct Manifest: Sendable, Equatable {
        let repoID: String
        /// The commit the file list came from. File URLs pin this so a push to
        /// the repo mid-download cannot swap bytes under verified hashes.
        let revision: String
        let files: [RemoteFile]

        var totalBytes: Int64 { files.reduce(0) { $0 + ($1.size ?? 0) } }
    }

    // MARK: - Resolution

    /// Resolves `repoID` against huggingface.co to the files worth downloading.
    static func manifest(for repoID: String, session: URLSession = .shared) async throws -> Manifest {
        guard let url = URL(string: "https://huggingface.co/api/models/\(repoID)") else {
            throw ModelDownloadError.manifestFailed("Not a valid repo id: \(repoID)")
        }

        var request = URLRequest(url: url)
        request.url?.append(queryItems: [URLQueryItem(name: "blobs", value: "true")])
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw ModelDownloadError.manifestFailed("\(repoID): HTTP \(status)")
        }

        let dto = try decode(ManifestDTO.self, from: data)
        let files = (dto.siblings ?? [])
            .filter { sibling in Self.loadableExtensions.contains(sibling.rfilenamePathExtension) }
            .sorted { $0.rfilename < $1.rfilename }
            .map { RemoteFile(name: $0.rfilename, size: $0.lfs?.size ?? $0.size, sha256: $0.lfs?.oid) }

        guard !files.isEmpty else {
            throw ModelDownloadError.manifestFailed("\(repoID) has no MLX-loadable files")
        }

        return Manifest(repoID: repoID, revision: dto.sha ?? "main", files: files)
    }

    // MARK: - Acquisition

    /// Acquires `repoID` into `root` and returns it as a loadable model.
    ///
    /// Progress advances with every network chunk across the whole repo,
    /// seeded from what is already on disk — verified copies and resumable
    /// `.part` prefixes — against the manifest's total.
    @discardableResult
    static func acquire(
        _ repoID: String,
        into root: URL = ModelStore.root,
        session: URLSession = .shared,
        progress: ProgressHandler? = nil
    ) async throws -> LocalModel {
        let name = (repoID as NSString).lastPathComponent
        let finalDirectory = root.appending(path: name)

        // Rung one: already on disk wins before any byte moves (§7.4).
        if let existing = try? ModelStore.model(at: finalDirectory) {
            log.notice("\(repoID, privacy: .public) is already on disk")
            return existing
        }

        // A name taken by something that is not a usable model — hand-placed
        // weights caught halfway through being copied are §7.4's own case —
        // cannot be promoted over. Failing here is typed, costs no request,
        // and touches nothing of the user's.
        if FileManager.default.fileExists(atPath: finalDirectory.path) {
            throw ModelDownloadError.downloadFailed(
                "\(name) is already in the models folder but is not a usable model"
            )
        }

        let manifest = try await Self.manifest(for: repoID, session: session)
        let staging = root.appending(path: ".incomplete-\(name)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        let tally = RepoProgress(total: manifest.totalBytes, handler: progress)
        tally.report()

        for file in manifest.files {
            try Task.checkCancellation()
            try await fetch(
                file,
                repoID: repoID,
                revision: manifest.revision,
                staging: staging,
                session: session,
                progress: tally
            )
        }

        try FileManager.default.moveItem(at: staging, to: finalDirectory)
        log.notice("Acquired \(repoID, privacy: .public), \(manifest.totalBytes) bytes")
        return try ModelStore.model(at: finalDirectory)
    }

    // MARK: - One file

    /// Fetches one file into `staging`, resuming `<name>.part` if it exists,
    /// then verifies size and hash and discards the copy on mismatch.
    private static func fetch(
        _ file: RemoteFile,
        repoID: String,
        revision: String,
        staging: URL,
        session: URLSession,
        progress: RepoProgress
    ) async throws {
        let destination = staging.appending(path: file.name)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // A complete copy left by an interruption between verify and promote is
        // checked, not redownloaded.
        if FileManager.default.fileExists(atPath: destination.path) {
            if verifies(file, at: destination) {
                progress.credit(file.size ?? byteCount(of: destination))
                return
            }
            log.notice("Discarding corrupt \(file.name, privacy: .public)")
            try? FileManager.default.removeItem(at: destination)
        }

        let part = destination.appendingPathExtension("part")
        let resumeFrom = byteCount(of: part)

        guard let url = URL(string: "https://huggingface.co/\(repoID)/resolve/\(revision)/\(file.name)") else {
            throw ModelDownloadError.downloadFailed("Not a valid file path: \(file.name)")
        }
        var request = URLRequest(url: url)
        if resumeFrom > 0 {
            request.setValue("bytes=\(resumeFrom)-", forHTTPHeaderField: "Range")
        }

        // Credit the on-disk prefix before the first chunk lands; a `200`
        // answer below rewinds it, because the file has started over.
        progress.begin(bytesOnDisk: resumeFrom)

        let stream = ChunkStream()
        // A delegate-driven data task delivers buffers, where `AsyncBytes`
        // resumes once per byte. Cloning the caller session's configuration
        // keeps injected `URLProtocol`s — the hermetic test stub — in force.
        let transport = URLSession(configuration: session.configuration, delegate: stream, delegateQueue: nil)
        let task = transport.dataTask(with: request)
        task.resume()
        defer {
            task.cancel()
            transport.finishTasksAndInvalidate()
        }

        var handle: FileHandle?
        defer { try? handle?.close() }

        var __debugEventCount = 0
        var __debugTotal = 0
        do {
            for try await event in stream.events {
                __debugEventCount += 1
                let cancelled = Task.isCancelled
                switch event {
                case .status(let statusCode):
                    FileHandle.standardError.write("DEBUG event=\(__debugEventCount) isCancelled=\(cancelled) status=\(statusCode)\n".data(using: .utf8)!)
                    switch statusCode {
                    case 206:
                        break  // the server honoured the range; append to what is on disk
                    case 200:
                        // Full body — either a fresh download or a server that ignored the
                        // range. Restarting the file here is what keeps resume honest.
                        try? FileManager.default.removeItem(at: part)
                        FileManager.default.createFile(atPath: part.path, contents: nil)
                        progress.restart()
                    case let other:
                        throw ModelDownloadError.downloadFailed("\(file.name): HTTP \(other)")
                    }
                    if !FileManager.default.fileExists(atPath: part.path) {
                        FileManager.default.createFile(atPath: part.path, contents: nil)
                    }
                    let opened = try FileHandle(forWritingTo: part)
                    try opened.seekToEnd()
                    handle = opened
                case .data(let data):
                    __debugTotal += data.count
                    FileHandle.standardError.write("DEBUG event=\(__debugEventCount) isCancelled=\(cancelled) data=\(data.count) total=\(__debugTotal)\n".data(using: .utf8)!)
                    try Task.checkCancellation()
                    guard let handle else {
                        throw ModelDownloadError.downloadFailed("\(file.name): body arrived before a response")
                    }
                    try handle.write(contentsOf: data)
                    progress.receive(Int64(data.count))
                }
            }
        } catch {
            FileHandle.standardError.write("DEBUG loop threw after \(__debugEventCount) events, total=\(__debugTotal): \(error)\n".data(using: .utf8)!)
            throw error
        }
        FileHandle.standardError.write("DEBUG loop finished normally after \(__debugEventCount) events, total=\(__debugTotal)\n".data(using: .utf8)!)
        guard handle != nil else {
            throw ModelDownloadError.downloadFailed("\(file.name): the connection closed without a response")
        }
        try? handle?.close()
        handle = nil

        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: part, to: destination)

        guard verifies(file, at: destination) else {
            try? FileManager.default.removeItem(at: destination)
            throw ModelDownloadError.integrityFailed("\(file.name) does not match the source manifest")
        }
        progress.finishFile()
    }

    /// Size always; SHA-256 whenever the manifest carries an LFS oid.
    private static func verifies(_ file: RemoteFile, at url: URL) -> Bool {
        if let expected = file.size, byteCount(of: url) != expected { return false }
        guard let sha256 = file.sha256 else { return true }
        guard let actual = try? sha256Hex(of: url) else { return false }
        return actual.caseInsensitiveCompare(sha256) == .orderedSame
    }

    // MARK: - Helpers

    /// Extensions an MLX load reads: weights (`.safetensors`, and `.npz` for
    /// older mlx-lm conversions), configs, and tokenizer data — `tokenizer.model`
    /// ships with a `.model` extension, `merges.txt` / `vocab.txt` as `.txt`.
    private static let loadableExtensions: Set<String> = [
        "safetensors", "json", "jinja", "model", "txt", "npz",
    ]

    private static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: chunkBytes), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func byteCount(of url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.size] as? Int64 ?? 0
    }

    private static func decode<T: Decodable>(_ type: T.Type, from: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: from)
        } catch {
            throw ModelDownloadError.manifestFailed("Unreadable manifest: \(error.localizedDescription)")
        }
    }
}

/// Byte-level progress across a whole repo: what is on disk when each file
/// starts, plus every chunk that arrives, against the manifest's total.
private final class RepoProgress: @unchecked Sendable {
    private let lock = NSLock()
    private let total: Int64
    private let handler: ModelDownload.ProgressHandler?
    private var settled: Int64 = 0
    private var inFlight: Int64 = 0

    init(total: Int64, handler: ModelDownload.ProgressHandler?) {
        self.total = total
        self.handler = handler
    }

    func report() {
        handler?(settled + inFlight, total)
    }

    /// Credits a file that needed no fetching — already verified on disk.
    func credit(_ bytes: Int64) {
        lock.lock(); settled += bytes; lock.unlock()
        report()
    }

    /// Opens a file for fetching, crediting its on-disk `.part` prefix.
    func begin(bytesOnDisk: Int64) {
        lock.lock(); inFlight = bytesOnDisk; lock.unlock()
        report()
    }

    /// A `200` answer restarted the file: the credited prefix is gone.
    func restart() {
        lock.lock(); inFlight = 0; lock.unlock()
        report()
    }

    func receive(_ count: Int64) {
        lock.lock(); inFlight += count; lock.unlock()
        report()
    }

    /// Closes a finished file: its bytes join the settled tally.
    func finishFile() {
        lock.lock(); settled += inFlight; inFlight = 0; lock.unlock()
        report()
    }
}

/// Bridges one `URLSessionDataTask` into an async stream of status-plus-body-
/// chunk events, replacing the per-byte resume cost of `URLSession.AsyncBytes`.
private final class ChunkStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Event: Sendable {
        case status(Int)
        case data(Data)
    }

    let events: AsyncThrowingStream<Event, Error>
    private var continuation: AsyncThrowingStream<Event, Error>.Continuation!

    override init() {
        var continuation: AsyncThrowingStream<Event, Error>.Continuation!
        events = AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation = $0 }
        self.continuation = continuation
        super.init()
        FileHandle.standardError.write("DEBUG ChunkStream init \(ObjectIdentifier(self))\n".data(using: .utf8)!)
    }

    deinit {
        FileHandle.standardError.write("DEBUG ChunkStream DEINIT \(ObjectIdentifier(self))\n".data(using: .utf8)!)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        completionHandler(.allow)
        continuation.yield(.status((response as? HTTPURLResponse)?.statusCode ?? 0))
    }

    var __debugYieldCount = 0
    var __debugYieldTotal = 0

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        __debugYieldCount += 1
        __debugYieldTotal += data.count
        FileHandle.standardError.write("DEBUG yield=\(__debugYieldCount) bytes=\(data.count) total=\(__debugYieldTotal) thread=\(Thread.current)\n".data(using: .utf8)!)
        continuation.yield(.data(data))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        FileHandle.standardError.write("DEBUG didComplete afterYields=\(__debugYieldCount) totalYielded=\(__debugYieldTotal) error=\(String(describing: error)) thread=\(Thread.current)\n".data(using: .utf8)!)
        if let error = error as NSError?, error.code == NSURLErrorCancelled {
            continuation.finish(throwing: CancellationError())
        } else if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }
}

// MARK: - Manifest JSON

/// `GET https://huggingface.co/api/models/{repo_id}?blobs=true`. Only what the
/// downloader reads; everything else in the response is ignored.
private nonisolated struct ManifestDTO: Decodable {
    nonisolated struct Sibling: Decodable {
        let rfilename: String
        let size: Int64?
        let lfs: LFS?

        var rfilenamePathExtension: String {
            (rfilename as NSString).pathExtension
        }
    }

    nonisolated struct LFS: Decodable {
        /// The blob's SHA-256, hex, no prefix.
        let oid: String?
        let size: Int64?
    }

    /// The commit the snapshot was taken at; pins `resolve/<sha>` for files.
    let sha: String?
    let siblings: [Sibling]?
}
