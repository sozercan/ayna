@testable import Ayna
import Foundation
import Testing

@Suite("OpenAIImageService Tests", .tags(.networking, .async))
struct OpenAIImageServiceTests {
    @Test
    func `cancelled handle cancels a URLSession task rejected during registration`() throws {
        let handle = OpenAIImageService.RequestHandle()
        let url = try #require(URL(string: "https://example.com/image"))
        let task = URLSession(configuration: .ephemeral).dataTask(with: url)
        handle.cancel()

        #expect(!handle.register(task))
        #expect(task.state != .suspended)
    }
}
