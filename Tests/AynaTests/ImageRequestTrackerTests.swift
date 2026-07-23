@testable import Ayna
import Foundation
import Testing

@Suite("Image Request Tracker Tests")
@MainActor
struct ImageRequestTrackerTests {
    @Test
    func `cancel all cancels registered request handles`() {
        let tracker = ImageRequestTracker()
        let requestId = UUID()
        let handle = OpenAIImageService.RequestHandle()

        tracker.begin(requestId)
        tracker.register(handle, for: requestId)
        let cancelledIds = tracker.cancelAll()

        #expect(handle.isCancelled)
        #expect(!tracker.isActive(requestId))
        #expect(cancelledIds == [requestId])
    }

    @Test
    func `late handle registration is cancelled after request finishes`() {
        let tracker = ImageRequestTracker()
        let requestId = UUID()
        let handle = OpenAIImageService.RequestHandle()

        tracker.begin(requestId)
        #expect(tracker.finish(requestId))
        tracker.register(handle, for: requestId)

        #expect(handle.isCancelled)
    }
}
