import Foundation

@MainActor
enum ConversationSendPreflight {
    static func loadConversationHistory(
        conversationId: UUID,
        manager: ConversationManager
    ) async -> Conversation? {
        guard !Task.isCancelled else { return nil }
        let conversation = await manager.ensureConversationLoaded(conversationId)
        guard !Task.isCancelled,
              conversation?.id == conversationId,
              !manager.isMetadataOnlyConversation(conversationId)
        else {
            return nil
        }
        return conversation
    }
}
