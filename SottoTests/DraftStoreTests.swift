import Testing
@testable import Sotto
import Foundation

/// DraftStore's file IO — the save/load/delete paths behind `draft`'s didSet.
/// Serialized because they share the `fileURLForTesting` seam; MainActor
/// because the app target defaults to main-actor isolation and the store's
/// API is isolated accordingly.
@Suite(.serialized)
@MainActor
struct DraftStoreTests {
    /// Each test points the store at its own temp file so nothing here touches
    /// the real Application Support draft.json.
    private func useTempFile() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sotto-draftstore-tests-\(UUID().uuidString).json")
        DraftStore.fileURLForTesting = url
        return url
    }

    private func cleanup(_ url: URL) {
        DraftStore.fileURLForTesting = nil
        try? FileManager.default.removeItem(at: url)
    }

    @Test func saveLoadRoundTrip() {
        let url = useTempFile()
        defer { cleanup(url) }

        let store = DraftStore(draft: Draft())
        store.setText("persisted text")
        store.forceSave()

        #expect(FileManager.default.fileExists(atPath: url.path))
        // init() is the loading path — it reads fileURL, which is the temp file.
        let reloaded = DraftStore()
        #expect(reloaded.draft.text == "persisted text")
    }

    @Test func emptyDraftDeletesFile() {
        let url = useTempFile()
        defer { cleanup(url) }

        let store = DraftStore(draft: Draft())
        store.setText("something")
        store.forceSave()
        #expect(FileManager.default.fileExists(atPath: url.path))

        store.reset()
        store.forceSave()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func imageAttachmentSurvivesRelaunch() {
        let url = useTempFile()
        defer { cleanup(url) }

        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4])
        let store = DraftStore(draft: Draft())
        store.addImage(filename: "shot.png", data: png)
        store.forceSave()

        let reloaded = DraftStore()
        #expect(reloaded.draft.attachments.count == 1)
        guard case .image(_, let filename, let data)? = reloaded.draft.attachments.first else {
            Issue.record("Expected an image attachment after round-trip")
            return
        }
        #expect(filename == "shot.png")
        #expect(data == png)
    }
}
