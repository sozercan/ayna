import Foundation
import os

extension ConversationManager {
    func generateTitle(for conversation: Conversation) {
        guard let firstMessage = conversation.messages.first(where: { $0.role == .user }) else {
            return
        }

        let content = firstMessage.content
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let imageCount = firstMessage.attachments?.count(where: {
                $0.mimeType.starts(with: "image/")
            }) ?? 0
            guard imageCount > 0 else { return }
            let fallbackTitle = imageCount == 1 ? "Image" : "\(imageCount) Images"
            renameConversation(conversation, newTitle: fallbackTitle)
            return
        }

        let modelCapability = AIService.shared.getModelCapability(conversation.model)
        if modelCapability == .imageGeneration {
            let fallbackTitle = String(content.prefix(50))
            renameConversation(conversation, newTitle: fallbackTitle + (content.count > 50 ? "..." : ""))
            return
        }

        let titleRequestGeneration = beginTitleRequest(for: conversation.id)
        let firstMessageId = firstMessage.id

        let titlePrompt = "Generate a very short title (3-5 words maximum) for a conversation that starts with: \"\(content.prefix(200))\". Only respond with the title, nothing else."

        let titleMessage = Message(role: .user, content: titlePrompt)

        let accumulator = TitleAccumulator()

        AIService.shared.sendMessage(
            messages: [titleMessage],
            model: conversation.model,
            stream: false,
            requestLane: .background,
            onChunk: { chunk in
                accumulator.append(chunk)
            },
            onComplete: { [weak self] in
                let selfRef = self
                let accumulatedTitle = accumulator.getTitle()
                Task { @MainActor in
                    guard let self = selfRef,
                          self.titleRequestIsCurrent(
                              conversationId: conversation.id,
                              generation: titleRequestGeneration,
                              firstMessageId: firstMessageId
                          ),
                          let currentConversation = self.conversationSnapshot(byId: conversation.id)
                    else { return }
                    let cleanTitle = accumulatedTitle
                        .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                        .replacingOccurrences(of: "\"", with: "")
                        .replacingOccurrences(of: "\n", with: " ")

                    if !cleanTitle.isEmpty {
                        self.renameConversation(currentConversation, newTitle: cleanTitle)
                    } else {
                        let fallbackTitle = String(content.prefix(50))
                        self.renameConversation(currentConversation, newTitle: fallbackTitle + (content.count > 50 ? "..." : ""))
                    }
                }
            },
            onError: { [weak self] error in
                let selfRef = self
                Task { @MainActor in
                    guard let self = selfRef,
                          self.titleRequestIsCurrent(
                              conversationId: conversation.id,
                              generation: titleRequestGeneration,
                              firstMessageId: firstMessageId
                          ),
                          let currentConversation = self.conversationSnapshot(byId: conversation.id)
                    else { return }
                    self.logManager(
                        "⚠️ Failed to generate AI title",
                        level: .error,
                        metadata: ["error": error.localizedDescription, "conversationId": conversation.id.uuidString]
                    )
                    let fallbackTitle = String(content.prefix(50))
                    self.renameConversation(currentConversation, newTitle: fallbackTitle + (content.count > 50 ? "..." : ""))
                }
            },
            onReasoning: nil
        )
    }

    private func beginTitleRequest(for conversationId: UUID) -> UInt64 {
        titleRequestGenerationByConversationId[conversationId, default: 0] &+= 1
        return titleRequestGenerationByConversationId[conversationId] ?? 0
    }

    func invalidateTitleRequest(for conversationId: UUID) {
        titleRequestGenerationByConversationId[conversationId, default: 0] &+= 1
    }

    private func titleRequestIsCurrent(
        conversationId: UUID,
        generation: UInt64,
        firstMessageId: UUID
    ) -> Bool {
        guard titleRequestGenerationByConversationId[conversationId] == generation,
              let currentConversation = conversationSnapshot(byId: conversationId)
        else { return false }
        return currentConversation.messages.first(where: { $0.role == .user })?.id == firstMessageId
    }
}

private final class TitleAccumulator: Sendable {
    private let title = OSAllocatedUnfairLock(initialState: "")

    func append(_ chunk: String) {
        title.withLock { $0 += chunk }
    }

    func getTitle() -> String {
        title.withLock { $0 }
    }
}
