import Foundation
import os

/// §7.4's third rung: `ollama pull`, delegated.
///
/// Sotto does not re-implement Ollama. The pull is one `POST /api/pull` to the
/// server the user already runs: Ollama fetches, resumes its own layers across
/// launches, verifies its own digests, and stores in its own format — Sotto
/// streams the NDJSON progress lines and passes failures through with the
/// server's own wording. Nothing schedules, retries, or re-checks on its own,
/// so principle 1's consent rule holds structurally: the only caller is the
/// surface whose button the user pressed.
///
/// Failures reuse `ModelDownloadError` so one acquisition ladder has one failure
/// vocabulary, routed to the model list where the download was started (§14.3) —
/// never the HUD; this is not a dictation failure.
nonisolated enum OllamaPull {
    private static let log = Logger(subsystem: "com.anthonyprosser.Sotto", category: "ollama-pull")

    /// One line of a pull response. Ollama emits more keys per phase and they
    /// are ignored; unparseable lines are skipped rather than failing a pull.
    private struct PullLine: Decodable {
        let status: String?
        let error: String?
        let total: Int64?
        let completed: Int64?
    }

    /// Pulls `model` into Ollama's own store.
    ///
    /// The endpoint is not a parameter: `/api/pull` exists only on Ollama —
    /// llama-server and LM Studio serve no such route — so accepting a generic
    /// `LocalServerEndpoint` offered a failure mode disguised as flexibility.
    ///
    /// Progress carries byte counts from the lines that have them; the manifest
    /// and digest-verify phases carry none and report nothing. Cancelling the
    /// surrounding task aborts the request, and Ollama aborts the pull
    /// server-side when its client disconnects; resuming across launches is
    /// likewise delegated, so there is no `.part` handling here.
    static func pull(
        _ model: String,
        session: URLSession = .shared,
        progress: ModelDownload.ProgressHandler? = nil
    ) async throws {
        var request = URLRequest(url: LocalServerEndpoint.ollama.baseURL.appending(path: "api/pull"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model])

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw ModelDownloadError.downloadFailed(
                "Cannot reach Ollama at \(LocalServerEndpoint.ollama.baseURL.absoluteString) — \(error.localizedDescription)"
            )
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ModelDownloadError.downloadFailed("Ollama returned HTTP \(http.statusCode)")
        }

        let decoder = JSONDecoder()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let update = try? decoder.decode(PullLine.self, from: Data(line.utf8)) else { continue }

            if let message = update.error, !message.isEmpty {
                throw ModelDownloadError.downloadFailed(message)
            }
            if let total = update.total, let completed = update.completed, total > 0 {
                progress?(completed, total)
            }
            if update.status == "success" {
                log.notice("Pulled \(model, privacy: .public) through Ollama")
                return
            }
        }

        throw ModelDownloadError.downloadFailed("Ollama closed the connection before the pull finished")
    }
}
