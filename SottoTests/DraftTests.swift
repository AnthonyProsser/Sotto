import Testing
@testable import Sotto
import Foundation

struct DraftTests {
    @Test func fenceLongerThanContent() {
        let d = Draft(text: "", attachments: [.selection(id: UUID(), app: "Safari", text: "hello ``` world")])
        let ser = d.serializedContent()
        print("SERIALIZED:", ser.debugDescription)
        // Should use ```` to wrap content containing ```
        #expect(ser.contains("````"))
        #expect(ser.contains("hello ``` world"))
        // Ensure not using 3-backtick fence for this content (which would break)
        // The 4-backtick fence will contain the 3-backtick text safely
        let threeFence = "```selection app=\"Safari\"\nhello ``` world\n```"
        #expect(ser != threeFence)
        #expect(ser.hasPrefix("````"))
    }

    @Test func attachmentsBeforeText() {
        let d = Draft(text: "question?", attachments: [.selection(id: UUID(), app: "Xcode", text: "sel")])
        let ser = d.serializedContent()
        // Attachment block should come before text
        let selRange = ser.range(of: "selection")
        let qRange = ser.range(of: "question?")
        #expect(selRange != nil && qRange != nil)
        #expect(selRange!.lowerBound < qRange!.lowerBound)
    }

    @Test func draftCodableRoundTrip() throws {
        let d = Draft(text: "hi", attachments: [.selection(id: UUID(), app: "App", text: "t"), .image(id: UUID(), filename: "img.png", data: Data([1,2,3]))], target: .existing(slug: "my-chat"))
        let data = try JSONEncoder().encode(d)
        let d2 = try JSONDecoder().decode(Draft.self, from: data)
        #expect(d == d2)
    }

    @Test func imageAttachmentsMap() {
        let d = Draft(text: "hi", attachments: [.image(id: UUID(), filename: "a.png", data: Data([1]))], target: .new)
        #expect(d.imageAttachments().count == 1)
        #expect(d.imageAttachments()["a.png"] != nil)
    }
}
