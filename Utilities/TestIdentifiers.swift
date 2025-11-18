import Foundation

/// Central place to keep the accessibility identifiers we rely on in UI tests.
enum TestIdentifiers {
    enum Sidebar {
        static let searchField = "sidebar.searchField"
        static let newConversationButton = "sidebar.newConversationButton"
        static let conversationList = "sidebar.conversationList"

        static func conversationRow(for conversationId: UUID) -> String {
            "sidebar.conversationRow.\(conversationId.uuidString)"
        }
    }

    enum ChatComposer {
        static let textEditor = "chat.composer.textEditor"
        static let sendButton = "chat.composer.sendButton"
    }

    enum NewChatComposer {
        static let textEditor = "newchat.composer.textEditor"
        static let sendButton = "newchat.composer.sendButton"
    }
}
