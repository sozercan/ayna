@testable import Ayna
import Foundation
import Testing

@Suite("File Attachment Identity Tests", .tags(.fast))
struct FileAttachmentIdentityTests {
    @Test
    func `attachments with identical content have distinct identities`() {
        let first = Message.FileAttachment(
            fileName: "image.png",
            mimeType: "image/png",
            data: Data([0x89, 0x50, 0x4E, 0x47])
        )
        let second = Message.FileAttachment(
            fileName: "image.png",
            mimeType: "image/png",
            data: Data([0x89, 0x50, 0x4E, 0x47])
        )

        #expect(first.id != second.id)
    }

    @Test
    func `attachment identity survives coding round trip`() throws {
        let attachment = Message.FileAttachment(
            fileName: "image.png",
            mimeType: "image/png",
            data: Data([0x89, 0x50, 0x4E, 0x47])
        )

        let decoded = try JSONDecoder().decode(
            Message.FileAttachment.self,
            from: JSONEncoder().encode(attachment)
        )

        #expect(decoded == attachment)
        #expect(decoded.id == attachment.id)
    }

    @Test
    func `legacy attachment without identity remains decodable`() throws {
        let legacyData = try JSONSerialization.data(withJSONObject: [
            "fileName": "legacy.png",
            "mimeType": "image/png",
            "data": Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString(),
        ])

        let migrated = try JSONDecoder().decode(Message.FileAttachment.self, from: legacyData)
        let persisted = try JSONDecoder().decode(
            Message.FileAttachment.self,
            from: JSONEncoder().encode(migrated)
        )

        #expect(migrated.fileName == "legacy.png")
        #expect(persisted.id == migrated.id)
    }
}
