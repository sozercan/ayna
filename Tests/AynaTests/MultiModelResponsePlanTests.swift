@testable import Ayna
import Foundation
import Testing

@Suite("MultiModelResponsePlan Tests", .tags(.fast))
struct MultiModelResponsePlanTests {
    @Test
    func `text plan creates streaming placeholders sharing one response group`() throws {
        let userMessageId = UUID()
        let responseGroupId = UUID()
        let models = ["gpt-5", "claude-sonnet"]

        let plan = MultiModelResponsePlan(
            models: models,
            userMessageId: userMessageId,
            responseGroupId: responseGroupId
        )

        #expect(plan.responseGroup.id == responseGroupId)
        #expect(plan.responseGroup.userMessageId == userMessageId)
        #expect(plan.responseGroup.responses.map(\.modelName) == models)
        #expect(plan.responseGroup.responses.allSatisfy { $0.status == .streaming })
        #expect(plan.placeholderMessages.count == models.count)

        for placeholder in plan.placeholderMessages {
            let model = try #require(placeholder.model)
            #expect(placeholder.role == .assistant)
            #expect(placeholder.content.isEmpty)
            #expect(placeholder.responseGroupId == responseGroupId)
            #expect(placeholder.mediaType == nil)
            #expect(plan.messageId(for: model) == placeholder.id)
            #expect(plan.responseGroup.responses.contains { $0.id == placeholder.id && $0.modelName == model })
        }
    }

    @Test
    func `image plan marks placeholders as image responses`() {
        let plan = MultiModelResponsePlan(
            models: ["dall-e", "gpt-image"],
            userMessageId: UUID(),
            mediaType: .image
        )

        #expect(plan.placeholderMessages.allSatisfy { $0.mediaType == .image })
        #expect(plan.placeholderMessages.allSatisfy { $0.imageData == nil && $0.imagePath == nil })
        #expect(Set(plan.messageIDsByModel.keys) == Set(["dall-e", "gpt-image"]))
    }

    @Test
    func `reasoning-only response renders reasoning instead of a typing indicator`() {
        let message = Message(role: .assistant, content: "", reasoning: "Compare the constraints first.")

        let plan = MultiModelResponseContentPlan(message: message, responseStatus: .streaming)

        #expect(plan.reasoning == message.reasoning)
        #expect(!plan.showsTypingIndicator)
    }

    @Test
    func `empty streaming response renders a typing indicator`() {
        let plan = MultiModelResponseContentPlan(
            message: Message(role: .assistant, content: ""),
            responseStatus: .streaming
        )

        #expect(plan.reasoning == nil)
        #expect(plan.showsTypingIndicator)
    }
}
