//
//  WatchMessageView.swift
//  Ayna Watch App
//
//  Created on 11/29/25.
//

#if os(watchOS)

import SwiftUI

/// Compact message bubble for Watch
/// iMessage-style with user messages on right (blue) and assistant on left (gray)
struct WatchMessageView: View {
    let message: WatchMessage

    private var isUser: Bool {
        message.role == "user"
    }

    var body: some View {
        HStack {
            if isUser {
                Spacer(minLength: 20)
            }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 2) {
                // Message content
                Text(WatchMarkdownRenderer.render(message.content))
                    .font(.system(size: 14))
                    .foregroundColor(isUser ? .white : .primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(bubbleBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                // Timestamp
                Text(formattedTime)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
            }

            if !isUser {
                Spacer(minLength: 20)
            }
        }
    }

    private var bubbleBackground: Color {
        isUser ? Color.blue : Color(white: 0.25)
    }

    private var formattedTime: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: message.timestamp)
    }
}

/// Streaming message view that shows typing indicator then content
struct WatchStreamingMessageView: View {
    let content: String
    let isStreaming: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                if content.isEmpty && isStreaming {
                    // Typing indicator
                    HStack(spacing: 4) {
                        ForEach(0 ..< 3, id: \.self) { index in
                            Circle()
                                .fill(Color.secondary)
                                .frame(width: 6, height: 6)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color(white: 0.25))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                } else {
                    // Content
                    Text(WatchMarkdownRenderer.render(content))
                        .font(.system(size: 14))
                        .foregroundColor(.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(white: 0.25))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }

            Spacer(minLength: 20)
        }
    }
}

#if DEBUG
struct WatchMessageView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 8) {
            WatchMessageView(
                message: WatchMessage(
                    from: Message(role: .user, content: "Hello, how are you?")
                )
            )

            WatchMessageView(
                message: WatchMessage(
                    from: Message(role: .assistant, content: "I'm doing well, thank you! How can I help you today?")
                )
            )

            WatchStreamingMessageView(content: "", isStreaming: true)
            WatchStreamingMessageView(content: "Thinking...", isStreaming: true)
        }
        .padding()
    }
}
#endif

#endif
