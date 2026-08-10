import Foundation

@MainActor
enum WatchModelSelectionCoordinator {
    nonisolated static func shouldAutoSelect(
        availableModelCount: Int,
        conversationID: UUID?
    ) -> Bool {
        availableModelCount == 1 && conversationID == nil
    }

    static func select(
        model: String,
        conversationID: UUID?,
        currentConversationModel: (UUID) -> String?,
        persistConversationModel: (String, UUID) -> Bool,
        applyGlobalModel: (String) -> Void
    ) -> Bool {
        if let conversationID {
            guard let currentModel = currentConversationModel(conversationID) else {
                return false
            }
            if currentModel != model,
               !persistConversationModel(model, conversationID)
            {
                return false
            }
        }

        applyGlobalModel(model)
        return true
    }
}
