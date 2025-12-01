//
//  WatchNewChatView.swift
//  Ayna Watch App
//
//  Created on 11/30/25.
//

#if os(watchOS)

    import SwiftUI

    /// New chat view that doesn't create a conversation until user sends a message
    struct WatchNewChatView: View {
        @Environment(\.dismiss) private var dismiss
        @ObservedObject var viewModel: WatchChatViewModel
        @EnvironmentObject var conversationStore: WatchConversationStore

        @State private var messageText = ""
        @State private var createdConversationId: UUID?

        var body: some View {
            Group {
                if let conversationId = createdConversationId {
                    // Once conversation is created, show the regular chat view
                    WatchChatView(conversationId: conversationId, viewModel: viewModel)
                } else {
                    // Show empty state with just the composer
                    newChatContent
                }
            }
            .navigationTitle("New Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        WatchModelSelectionView()
                    } label: {
                        Image(systemName: "cpu")
                    }
                }
            }
        }

        private var newChatContent: some View {
            ScrollView {
                VStack(spacing: 12) {
                    Spacer()
                        .frame(height: 40)

                    // Composer
                    composerBar
                }
                .padding(.horizontal, 4)
            }
            .defaultScrollAnchor(.bottom)
        }

        private var composerBar: some View {
            TextField("Ask anything", text: $messageText)
                .font(.system(size: 13))
                .frame(height: 28)
                .submitLabel(.send)
                .onSubmit {
                    sendFirstMessage()
                }
        }

        private func sendFirstMessage() {
            let trimmed = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }

            // Create the conversation only now
            let newId = viewModel.createNewConversation()
            createdConversationId = newId
            conversationStore.selectedConversationId = newId

            // Send the message
            viewModel.sendMessage(trimmed)
            messageText = ""
        }
    }

#endif
