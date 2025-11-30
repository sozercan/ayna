//
//  WatchChatView.swift
//  Ayna Watch App
//
//  Created on 11/29/25.
//

#if os(watchOS)

import SwiftUI

/// Chat view for Watch showing messages and input
/// Mimics iMessage style with bubbles and bottom composer bar
struct WatchChatView: View {
    let conversationId: UUID
    @ObservedObject var viewModel: WatchChatViewModel
    @EnvironmentObject var conversationStore: WatchConversationStore

    @State private var messageText = ""

    var body: some View {
        VStack(spacing: 0) {
            // Messages list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        if let conversation = conversationStore.conversation(for: conversationId) {
                            ForEach(conversation.messages) { message in
                                WatchMessageView(message: message)
                                    .id(message.id)
                            }

                            // Typing indicator when loading
                            if viewModel.isLoading {
                                typingIndicator
                                    .id("typing")
                            }

                            // Error message if any
                            if let error = viewModel.errorMessage {
                                errorView(error)
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.bottom, 8)
                }
                .onChange(of: conversationStore.conversation(for: conversationId)?.messages.count) { _, _ in
                    // Scroll to bottom when new message arrives
                    withAnimation {
                        if viewModel.isLoading {
                            proxy.scrollTo("typing", anchor: .bottom)
                        } else if let lastId = conversationStore.conversation(for: conversationId)?.messages.last?.id {
                            proxy.scrollTo(lastId, anchor: .bottom)
                        }
                    }
                }
            }

            // Bottom composer bar (iMessage style)
            composerBar
        }
        .navigationTitle(conversationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            viewModel.setConversation(conversationId)
        }
    }

    private var conversationTitle: String {
        conversationStore.conversation(for: conversationId)?.title ?? "Chat"
    }

    /// iMessage-style bottom composer bar with inline TextField
    private var composerBar: some View {
        HStack(spacing: 8) {
            if viewModel.isLoading {
                // Stop button when generating
                Button {
                    viewModel.cancelRequest()
                } label: {
                    HStack {
                        Image(systemName: "stop.fill")
                        Text("Stop")
                    }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.red)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            } else {
                // Inline text field - tapping triggers dictation automatically on watchOS
                TextField("Message", text: $messageText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.gray.opacity(0.3))
                    .clipShape(Capsule())
                    .submitLabel(.send)
                    .onSubmit {
                        sendMessage()
                    }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .padding(.bottom, 4)
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
    }

    private func errorView(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 11))
            .foregroundColor(.red)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.red.opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: 8))
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
