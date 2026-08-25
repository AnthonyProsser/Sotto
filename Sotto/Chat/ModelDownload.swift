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

    /// Chunk size for streaming reads, writes, and hashing.
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

        return Manifest(repoID: repoID, files: files)
    }

    // MARK: - Acquisition

    /// Acquires `repoID` into `root` and returns it as a loadable model.
    ///
    /// Progress is reported after each file lands; a repo's few multi-GB shards
    /// make finer granularity a concern of the surface that displays it, which
    /// can move the call into the byte loop when pixels exist to justify it.
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

        let total = manifest.totalBytes
        var downloaded: Int64 = 0
        progress?(downloaded, total)

        for file in manifest.files {
            try Task.checkCancellation()
            try await fetch(file, repoID: repoID, staging: staging, session: session)
            downloaded += file.size ?? 0
            progress?(downloaded, total)
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
        staging: URL,
        session: URLSession
    ) async throws {
        let destination = staging.appending(path: file.name)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // A complete copy left by an interruption between verify and promote is
        // checked, not redownloaded.
        if FileManager.default.fileExists(atPath: destination.path) {
            if verifies(file, at: destination) { return }
            log.notice("Discarding corrupt \(file.name, privacy: .public)")
            try? FileManager.default.removeItem(at: destination)
        }

        let part = destination.appendingPathExtension("part")
        let resumeFrom = byteCount(of: part)

        guard let url = URL(string: "https://huggingface.co/\(repoID)/resolve/main/\(file.name)") else {
            throw ModelDownloadError.downloadFailed("Not a valid file path: \(file.name)")
        }
        var request = URLRequest(url: url)
        if resumeFrom > 0 {
            request.setValue("bytes=\(resumeFrom)-", forHTTPHeaderField: "Range")
        }

        let (bytes, response) = try await session.bytes(for: request)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 206:
            break  // the server honoured the range; append to what is on disk
        case 200:
            // Full body — either a fresh download or a server that ignored the
            // range. Restarting the file here is what keeps resume honest.
            try? FileManager.default.removeItem(at: part)
            FileManager.default.createFile(atPath: part.path, contents: nil)
        case let status:
            throw ModelDownloadError.downloadFailed("\(file.name): HTTP \(status)")
        }

        if !FileManager.default.fileExists(atPath: part.path) {
            FileManager.default.createFile(atPath: part.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: part)
        defer { try? handle.close() }
        try handle.seekToEnd()

        // AsyncBytes has no chunked read, so buffer to `chunkBytes` here: one
        // write syscall per megabyte instead of per byte.
        var buffer = [UInt8]()
        buffer.reserveCapacity(chunkBytes)
        for try await byte in bytes {
            try Task.checkCancellation()
            buffer.append(byte)
            if buffer.count >= chunkBytes {
                try handle.write(contentsOf: Data(buffer))
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: Data(buffer))
        }

        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: part, to: destination)

        guard verifies(file, at: destination) else {
            try? FileManager.default.removeItem(at: destination)
            throw ModelDownloadError.integrityFailed("\(file.name) does not match the source manifest")
        }
    }

    /// Size always; SHA-256 whenever the manifest carries an LFS oid.
    private static func verifies(_ file: RemoteFile, at url: URL) -> Bool {
        if let expected = file.size, byteCount(of: url) != expected { return false }
        guard let sha256 = file.sha256 else { return true }
        guard let actual = try? sha256Hex(of: url) else { return false }
        return actual.caseInsensitiveCompare(sha256) == .orderedSame
    }

    // MARK: - Helpers

    /// Extensions an MLX load reads: weights, configs, and tokenizer data
    /// (`tokenizer.model` ships with a `.model` extension).
    private static let loadableExtensions: Set<String> = ["safetensors", "json", "jinja", "model"]

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

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ModelDownloadError.manifestFailed("Unreadable manifest: \(error.localizedDescription)")
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

    let siblings: [Sibling]?
}
