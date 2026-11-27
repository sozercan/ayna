import Foundation

enum TestIdentifiers {
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

    enum ChatView {
        static let messagesList = "chat.messagesList"
        static let modelSelector = "chat.modelSelector"
        static let emptyState = "chat.emptyState"

        static func messageRow(for messageId: UUID) -> String {
            "chat.message.\(messageId.uuidString)"
        }
    }

    enum Settings {
        static let doneButton = "settings.doneButton"
        static let addModelButton = "settings.addModelButton"
        static let clearConversationsButton = "settings.clearConversationsButton"
        static let autoGenerateTitleToggle = "settings.autoGenerateTitleToggle"

        static func modelRow(for modelName: String) -> String {
            "settings.modelRow.\(modelName)"
        }
    }

    enum Watch {
        static let conversationList = "watch.conversationList"
        static let emptyState = "watch.emptyState"
        static let newChatButton = "watch.newChatButton"
        static let modelSelectorButton = "watch.modelSelectorButton"
        static let modelList = "watch.modelList"
        static let newChatView = "watch.newChat.view"

        static func modelRow(for modelName: String) -> String {
            "watch.modelRow.\(modelName)"
        }

        static let chatMessagesList = "watch.chat.messagesList"
        static let chatComposerTextField = "watch.chat.composerTextField"
        static let chatStopButton = "watch.chat.stopButton"
        static let chatTypingIndicator = "watch.chat.typingIndicator"

        static func chatMessageRow(for messageId: UUID) -> String {
            "watch.chat.message.\(messageId.uuidString)"
        }

        static let newChatComposerTextField = "watch.newChat.composerTextField"

        static func conversationRow(for conversationId: UUID) -> String {
            "watch.conversationRow.\(conversationId.uuidString)"
        }
    }
}
