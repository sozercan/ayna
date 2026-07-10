@testable import Ayna
import Foundation
import Testing

@Suite("Request Builder Async Tests")
@MainActor
struct RequestBuilderAsyncTests {
    @Test("Async request builder resolves local-path image data off the synchronous payload path")
    func asyncRequestBuilderResolvesLocalPathImageDataOffSynchronousPayloadPath() async throws {
        let imageData = Self.pngData(byteCount: 4096)
        let attachment = Message.FileAttachment(
            fileName: "local.png",
            mimeType: "image/png",
            data: nil,
            localPath: "benchmark-local-image"
        )
        let message = Message(role: .user, content: "Describe this local image.", attachments: [attachment])

        let maybeRequest = try await OpenAIRequestBuilder.createChatCompletionsRequestAsync(
            url: #require(URL(string: "https://api.openai.com/v1/chat/completions")),
            messages: [message],
            model: "gpt-4o",
            stream: true,
            apiKey: "test-key",
            isAzure: false,
            attachmentDataLoader: { path in
                path == "benchmark-local-image" ? imageData : nil
            }
        )

        let request = try #require(maybeRequest)
        let bodyData = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        let payloadMessages = try #require(body["messages"] as? [[String: Any]])
        let content = try #require(payloadMessages.first?["content"] as? [[String: Any]])
        let imageBlock = try #require(content.first { $0["type"] as? String == "image_url" })
        let imageURL = try #require((imageBlock["image_url"] as? [String: Any])?["url"] as? String)

        #expect(imageURL.hasPrefix("data:image/png;base64,"))
        #expect(imageURL.contains(imageData.base64EncodedString()))
    }

    private static func pngData(byteCount: Int) -> Data {
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D])
        if byteCount > data.count {
            data.append(Data(repeating: 0xCD, count: byteCount - data.count))
        }
        return data
    }
}
