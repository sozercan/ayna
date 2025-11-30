//
//  WatchChatView.swift
//  Ayna Watch App
//
//  Created on 11/29/25.
//

#if os(watchOS)

import SwiftUI

/// Chat view for Watch showing messages and input
/// Mimics iMessage style with bubbles and bottom reply button
struct WatchChatView: View {
    let conversationId: UUID
    @ObservedObject var viewModel: WatchChatViewModel
    @EnvironmentObject var conversationStore: WatchConversationStore

    @State private var showingComposer = false

    var body: some View {
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
                .padding(.bottom, 60) // Space for reply button
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
        .navigationTitle(conversationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            replyButton
        }
        .sheet(isPresented: $showingComposer) {
            WatchMessageComposer(
                onSend: { text in
                    viewModel.sendMessage(text)
                    showingComposer = false
                },
                onCancel: {
                    showingComposer = false
                }
            )
        }
        .onAppear {
            viewModel.setConversation(conversationId)
        }
    }

    private var conversationTitle: String {
        conversationStore.conversation(for: conversationId)?.title ?? "Chat"
    }

    private var replyButton: some View {
        Button {
            if viewModel.isLoading {
                viewModel.cancelRequest()
            } else {
                showingComposer = true
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: viewModel.isLoading ? "stop.fill" : "mic.fill")
                    .font(.system(size: 14))

                Text(viewModel.isLoading ? "Stop" : "Reply")
                    .font(.system(size: 14, weight: .medium))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(viewModel.isLoading ? Color.red : Color.blue)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.bottom, 8)
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
