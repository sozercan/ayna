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
        var showTimestamp: Bool = false

        private var isUser: Bool {
            message.role == "user"
        }

        var body: some View {
            VStack(alignment: isUser ? .trailing : .leading, spacing: 2) {
                HStack {
                    if isUser {
                        Spacer(minLength: 40)
                    }

                    // Message content
                    Text(WatchMarkdownRenderer.render(message.content))
                        .font(.system(size: 15))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(bubbleBackground)
                        .clipShape(BubbleShape(isUser: isUser))

                    if !isUser {
                        Spacer(minLength: 40)
                    }
                }

                // Timestamp (optional, shown for last message)
                if showTimestamp {
                    Text(formattedTime)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 4)
                }
            }
        }

        private var bubbleBackground: Color {
            isUser ? Color.blue : Color(white: 0.2)
        }

        private var formattedTime: String {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            return formatter.string(from: message.timestamp)
        }
    }

    /// Custom bubble shape with tail like iMessage
    struct BubbleShape: Shape {
        let isUser: Bool

        func path(in rect: CGRect) -> Path {
            let width = rect.width
            let height = rect.height
            let radius: CGFloat = 16

            var path = Path()

            if isUser {
                // User bubble - tail on bottom right
                // Start top left
                path.move(to: CGPoint(x: radius, y: 0))

                // Top edge
                path.addLine(to: CGPoint(x: width - radius, y: 0))

                // Top right corner
                path.addArc(center: CGPoint(x: width - radius, y: radius), radius: radius, startAngle: Angle(degrees: -90), endAngle: Angle(degrees: 0), clockwise: false)

                // Right edge
                path.addLine(to: CGPoint(x: width, y: height - radius))

                // Bottom right (Tail) - Sharp corner
                path.addLine(to: CGPoint(x: width, y: height))
                path.addLine(to: CGPoint(x: width - radius, y: height))

                // Bottom edge
                path.addLine(to: CGPoint(x: radius, y: height))

                // Bottom left corner
                path.addArc(center: CGPoint(x: radius, y: height - radius), radius: radius, startAngle: Angle(degrees: 90), endAngle: Angle(degrees: 180), clockwise: false)

                // Left edge
                path.addLine(to: CGPoint(x: 0, y: radius))

                // Top left corner
                path.addArc(center: CGPoint(x: radius, y: radius), radius: radius, startAngle: Angle(degrees: 180), endAngle: Angle(degrees: 270), clockwise: false)

            } else {
                // Assistant bubble - tail on bottom left
                // Start top right
                path.move(to: CGPoint(x: width - radius, y: 0))

                // Top edge
                path.addLine(to: CGPoint(x: radius, y: 0))

                // Top left corner
                path.addArc(center: CGPoint(x: radius, y: radius), radius: radius, startAngle: Angle(degrees: -90), endAngle: Angle(degrees: -180), clockwise: true)

                // Left edge
                path.addLine(to: CGPoint(x: 0, y: height - radius))

                // Bottom left (Tail) - Sharp corner
                path.addLine(to: CGPoint(x: 0, y: height))
                path.addLine(to: CGPoint(x: radius, y: height))

                // Bottom edge
                path.addLine(to: CGPoint(x: width - radius, y: height))

                // Bottom right corner
                path.addArc(center: CGPoint(x: width - radius, y: height - radius), radius: radius, startAngle: Angle(degrees: 90), endAngle: Angle(degrees: 0), clockwise: true)

                // Right edge
                path.addLine(to: CGPoint(x: width, y: radius))

                // Top right corner
                path.addArc(center: CGPoint(x: width - radius, y: radius), radius: radius, startAngle: Angle(degrees: 0), endAngle: Angle(degrees: -90), clockwise: true)
            }

            return path
        }
    }

    /// Streaming message view that shows typing indicator then content
    struct WatchStreamingMessageView: View {
        let content: String
        let isStreaming: Bool

        var body: some View {
            HStack {
                if content.isEmpty, isStreaming {
                    // Typing indicator
                    HStack(spacing: 4) {
                        ForEach(0 ..< 3, id: \.self) { _ in
                            Circle()
                                .fill(Color.secondary)
                                .frame(width: 6, height: 6)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color(white: 0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                } else {
                    // Content
                    Text(WatchMarkdownRenderer.render(content))
                        .font(.system(size: 15))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(white: 0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }

                Spacer(minLength: 40)
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
