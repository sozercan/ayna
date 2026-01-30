@testable import Ayna_iOS
import Testing

#if os(iOS)
    import UIKit

    @Suite("ConversationExporter iOS Tests")
    @MainActor
    struct ConversationExporterIOSTests {
        @Test("Generate PDF for iOS")
        func generatePDFiOS() {
            // Create a dummy conversation
            let message = Message(role: .user, content: "Hello iOS PDF")
            let conversation = Conversation(
                id: UUID(),
                title: "iOS Test Conversation",
                messages: [message],
                createdAt: Date(),
                model: "gpt-4"
            )

            // Generate PDF
            let url = ConversationExporter.generatePDF(for: conversation)

            // Verify
            #expect(url != nil, "PDF URL should not be nil")
            if let url {
                #expect(FileManager.default.fileExists(atPath: url.path), "PDF file should exist at path")

                // Clean up
                try? FileManager.default.removeItem(at: url)
            }
        }

        @Test("Platform types resolve to UIKit on iOS")
        func platformTypesiOS() {
            // Verify that the typealiases resolve to UIKit types on iOS
            // Since we can't check typealias directly, we check instances

            let font = PlatformFont.systemFont(ofSize: 12)
            #expect(font is UIFont, "PlatformFont should be UIFont on iOS")

            let color = PlatformColor.blue
            #expect(color is UIColor, "PlatformColor should be UIColor on iOS")
        }
    }
#endif
