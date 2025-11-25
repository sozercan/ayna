import Foundation

/// Central place to keep the accessibility identifiers we rely on in UI tests.
enum TestIdentifiers {
    // MARK: - Sidebar (Shared)

    enum Sidebar {
        static let searchField = "sidebar.searchField"
        static let newConversationButton = "sidebar.newConversationButton"
        static let conversationList = "sidebar.conversationList"
        static let editButton = "sidebar.editButton"
        static let settingsButton = "sidebar.settingsButton"
        static let deleteSelectedButton = "sidebar.deleteSelectedButton"

        static func conversationRow(for conversationId: UUID) -> String {
            "sidebar.conversationRow.\(conversationId.uuidString)"
        }

        static func conversationCheckbox(for conversationId: UUID) -> String {
            "sidebar.conversationCheckbox.\(conversationId.uuidString)"
        }
    }

    // MARK: - Chat Composer (Shared)

    enum ChatComposer {
        static let textEditor = "chat.composer.textEditor"
        static let sendButton = "chat.composer.sendButton"
        static let attachButton = "chat.composer.attachButton"
        static let micButton = "chat.composer.micButton"
        static let errorMessage = "chat.composer.errorMessage"
        static let attachmentsList = "chat.composer.attachmentsList"
    }

    enum NewChatComposer {
        static let textEditor = "newchat.composer.textEditor"
        static let sendButton = "newchat.composer.sendButton"
        static let attachButton = "newchat.composer.attachButton"
        static let micButton = "newchat.composer.micButton"
        static let errorMessage = "newchat.composer.errorMessage"
    }

    // MARK: - Chat View

    enum ChatView {
        static let messagesList = "chat.messagesList"
        static let modelSelector = "chat.modelSelector"
        static let emptyState = "chat.emptyState"

        static func messageRow(for messageId: UUID) -> String {
            "chat.message.\(messageId.uuidString)"
        }
    }

    // MARK: - Settings

    enum Settings {
        static let doneButton = "settings.doneButton"
        static let addModelButton = "settings.addModelButton"
        static let clearConversationsButton = "settings.clearConversationsButton"
        static let autoGenerateTitleToggle = "settings.autoGenerateTitleToggle"

        static func modelRow(for modelName: String) -> String {
            "settings.modelRow.\(modelName)"
        }
    }
}
