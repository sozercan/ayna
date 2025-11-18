@testable import Ayna
import XCTest

final class EncryptedConversationStoreTests: XCTestCase {
    func testSaveAndLoadRoundTripsConversations() throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let conversations = [TestHelpers.sampleConversation(title: "Alpha")]

        try store.save(conversations)
        let loaded = try store.loadConversations()

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.title, "Alpha")
        XCTAssertEqual(loaded.first?.messages.count, conversations.first?.messages.count)
    }

    func testClearRemovesEncryptedFile() throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        try store.save([TestHelpers.sampleConversation()])

        try store.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("conversations.enc").path))
    }

    func testSecondStoreInstanceLoadsDataUsingSameKey() throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let keyIdentifier = UUID().uuidString
        let fileURL = directory.appendingPathComponent("conversations.enc")

        let firstStore = EncryptedConversationStore(fileURL: fileURL, keyIdentifier: keyIdentifier)
        try firstStore.save([TestHelpers.sampleConversation(title: "Persisted")])

        let secondStore = EncryptedConversationStore(fileURL: fileURL, keyIdentifier: keyIdentifier)
        let loaded = try secondStore.loadConversations()

        XCTAssertEqual(loaded.first?.title, "Persisted")
    }
}
