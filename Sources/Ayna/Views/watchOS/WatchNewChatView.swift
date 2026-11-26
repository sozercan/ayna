#if os(watchOS)

    #if os(watchOS)

        import SwiftUI

        struct WatchNewChatView: View {
            @Environment(\.dismiss) private var dismiss
            @ObservedObject var viewModel: WatchChatViewModel
            @EnvironmentObject var conversationStore: WatchConversationStore

            @State private var messageText = ""
            @State private var createdConversationId: UUID?

            var body: some View {
                Group {
                    if let conversationId = createdConversationId {
                        WatchChatView(conversationId: conversationId, viewModel: viewModel)
                    } else {
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
                        .accessibilityIdentifier(TestIdentifiers.Watch.modelSelectorButton)
                    }
                }
            }

            private var newChatContent: some View {
                ScrollView {
                    VStack(spacing: 12) {
                        Spacer()
                            .frame(height: 40)

                        composerBar

                        if let error = viewModel.errorMessage {
                            Text(error)
                                .font(.caption2)
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .defaultScrollAnchor(.bottom)
                .accessibilityIdentifier(TestIdentifiers.Watch.newChatView)
            }

            private var composerBar: some View {
                TextField("Ask anything", text: $messageText)
                    .font(.system(size: 13))
                    .frame(height: 28)
                    .submitLabel(.send)
                    .onSubmit {
                        sendFirstMessage()
                    }
                    .accessibilityIdentifier(TestIdentifiers.Watch.newChatComposerTextField)
            }

            private func sendFirstMessage() {
                let trimmed = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }

                guard let newId = viewModel.createNewConversation() else { return }
                createdConversationId = newId
                conversationStore.selectedConversationId = newId

                if viewModel.sendMessage(trimmed).consumedInput {
                    messageText = ""
                }
            }
        }

    #endif
#endif
