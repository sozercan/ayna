@testable import Ayna
import XCTest

final class EncryptedConversationStoreTests: XCTestCase {
  func testSaveAndLoadRoundTripsConversations() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
    let conversation = TestHelpers.sampleConversation(title: "Alpha")

    try await store.save(conversation)
    let loaded = try await store.loadConversations()

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.title, "Alpha")
    XCTAssertEqual(loaded.first?.messages.count, conversation.messages.count)
    }

  func testClearRemovesEncryptedFiles() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
    let conversation = TestHelpers.sampleConversation()
    try await store.save(conversation)

        try store.clear()

    let files = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil)
    XCTAssertTrue(files.isEmpty)
    }

  func testSecondStoreInstanceLoadsDataUsingSameKey() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
    let keyIdentifier = UUID().uuidString

    let firstStore = EncryptedConversationStore(
      directoryURL: directory, keyIdentifier: keyIdentifier)
    let conversation = TestHelpers.sampleConversation(title: "Persisted")
    try await firstStore.save(conversation)

    let secondStore = EncryptedConversationStore(
      directoryURL: directory, keyIdentifier: keyIdentifier)
    let loaded = try await secondStore.loadConversations()

        XCTAssertEqual(loaded.first?.title, "Persisted")
    }
}
