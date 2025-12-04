//
//  WatchChatView.swift
//  Ayna Watch App
//
//  Created on 11/29/25.
//

#if os(watchOS)

    import SwiftUI

    /// Activity type for Handoff
    private let handoffActivityType = "com.sertacozercan.ayna.conversation"

    /// Chat view for Watch showing messages and input
    /// Mimics iMessage style with bubbles and bottom composer bar
    struct WatchChatView: View {
        let conversationId: UUID
        @ObservedObject var viewModel: WatchChatViewModel
        @EnvironmentObject var conversationStore: WatchConversationStore

        @State private var messageText = ""

        var body: some View {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if let conversation = conversationStore.conversation(for: conversationId) {
                            ForEach(conversation.messages) { message in
                                // Don't show empty assistant messages (placeholder during streaming)
                                if !message.content.isEmpty || message.role.lowercased() == "user" {
                                    WatchMessageView(message: message)
                                        .id(message.id)
                                        .accessibilityIdentifier(TestIdentifiers.Watch.chatMessageRow(for: message.id))
                                }
                            }

                            // Typing indicator only when waiting for response (not during streaming)
                            if viewModel.isLoading, !viewModel.isStreaming {
                                if let toolName = viewModel.currentToolName {
                                    toolIndicator(toolName)
                                        .id("tool")
                                } else {
                                    typingIndicator
                                        .id("typing")
                                }
                            }

                            // Error message with retry if any
                            if let error = viewModel.errorMessage {
                                errorView(error)
                            }
                        }

                        // Spacer to separate messages from composer
                        Spacer()
                            .frame(height: 20)

                        // Composer at bottom of scroll content
                        composerBar
                            .id("composer")
                    }
                    .padding(.horizontal, 4)
                }
                .accessibilityIdentifier(TestIdentifiers.Watch.chatMessagesList)
                .onChange(of: conversationStore.conversation(for: conversationId)?.messages.count) { _, _ in
                    // Scroll to bottom when new message arrives
                    withAnimation {
                        if viewModel.isLoading, !viewModel.isStreaming {
                            // Waiting for response - scroll to typing indicator
                            if viewModel.currentToolName != nil {
                                proxy.scrollTo("tool", anchor: .bottom)
                            } else {
                                proxy.scrollTo("typing", anchor: .bottom)
                            }
                        } else if let lastId = conversationStore.conversation(for: conversationId)?.messages.last?.id {
                            // Streaming or idle - scroll to last message
                            proxy.scrollTo(lastId, anchor: .bottom)
                        }
                    }
                }
                .defaultScrollAnchor(.bottom)
            }
            .navigationTitle(conversationTitle)
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
            .onAppear {
                viewModel.setConversation(conversationId)
            }
            .userActivity(handoffActivityType) { activity in
                // Set up Handoff activity for this conversation
                activity.isEligibleForHandoff = true
                activity.title = conversationTitle
                activity.userInfo = ["conversationId": conversationId.uuidString]
                activity.needsSave = true
            }
        }

        private var conversationTitle: String {
            conversationStore.conversation(for: conversationId)?.title ?? "Chat"
        }

        /// iMessage-style composer bar
        private var composerBar: some View {
            HStack(spacing: 6) {
                if viewModel.isLoading {
                    // Stop button when generating
                    Button {
                        viewModel.cancelRequest()
                    } label: {
                        HStack {
                            Image(systemName: "stop.fill")
                            Text("Stop")
                        }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background(Color.red)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(TestIdentifiers.Watch.chatStopButton)
                } else {
                    // Text field - tapping triggers dictation on watchOS
                    TextField("Ask anything", text: $messageText)
                        .font(.system(size: 13))
                        .frame(height: 28)
                        .submitLabel(.send)
                        .onSubmit {
                            sendMessage()
                        }
                        .accessibilityIdentifier(TestIdentifiers.Watch.chatComposerTextField)
                }
            }
            .padding(.top, 4)
        }

        private func sendMessage() {
            let trimmed = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            viewModel.sendMessage(trimmed)
            messageText = ""
        }

        private var typingIndicator: some View {
            HStack(spacing: 4) {
                ForEach(0 ..< 3, id: \.self) { index in
                    Circle()
                        .fill(Color.secondary)
                        .frame(width: 6, height: 6)
                        .opacity(0.5)
                        .animation(
                            .easeInOut(duration: 0.5)
                                .repeatForever()
                                .delay(Double(index) * 0.15),
                            value: viewModel.isLoading
                        )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(white: 0.2))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(TestIdentifiers.Watch.chatTypingIndicator)
        }

        private func toolIndicator(_: String) -> some View {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.blue)
                Text("Searching...")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.blue.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        private func errorView(_ message: String) -> some View {
            VStack(spacing: 8) {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)

                if viewModel.failedMessage != nil {
                    HStack(spacing: 12) {
                        Button {
                            viewModel.retryFailedMessage()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.clockwise")
                                Text("Retry")
                            }
                            .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)

                        Button {
                            viewModel.dismissError()
                        } label: {
                            Text("Dismiss")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(Color.red.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    #if DEBUG
        struct WatchChatView_Previews: PreviewProvider {
            static var previews: some View {
                NavigationStack {
                    WatchChatView(
                        conversationId: UUID(),
                        viewModel: WatchChatViewModel()
                    )
                    .environmentObject(WatchConversationStore.shared)
                }
            }
        }
    #endif

#endif
