import XCTest
@testable import Ayna_iOS

#if os(iOS)
  import UIKit

  final class ConversationExporterIOSTests: XCTestCase {

    @MainActor
    func testGeneratePDF_iOS() async throws {
      // Create a dummy conversation
      let message = Message(role: .user, content: "Hello iOS PDF")
        let conversation = Conversation(
            id: UUID(),
            title: "iOS Test Conversation",
            messages: [message],
            createdAt: Date(),
            model: "gpt-4"
        )      // Generate PDF
      let url = ConversationExporter.generatePDF(for: conversation)

      // Verify
      XCTAssertNotNil(url, "PDF URL should not be nil")
      if let url = url {
        XCTAssertTrue(
          FileManager.default.fileExists(atPath: url.path), "PDF file should exist at path")

        // Clean up
        try? FileManager.default.removeItem(at: url)
      }
    }

    func testPlatformTypes_iOS() {
      // Verify that the typealiases resolve to UIKit types on iOS
      // Since we can't check typealias directly, we check instances

      let font = PlatformFont.systemFont(ofSize: 12)
      XCTAssertTrue(font is UIFont, "PlatformFont should be UIFont on iOS")

      let color = PlatformColor.blue
      XCTAssertTrue(color is UIColor, "PlatformColor should be UIColor on iOS")
    }
  }
#endif
