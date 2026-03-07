#if os(watchOS)
//
//  WatchMessageView.swift
//  Ayna Watch App
//
//  Created on 11/29/25.
//

#if os(watchOS)

    import SwiftUI

    // MARK: - Design System Integration

    // Uses Theme, Typography, Spacing from Core/Design/

    /// Compact message bubble for Watch
    /// iMessage-style with user messages on right (blue) and assistant on left (gray)
    struct WatchMessageView: View {
        let message: WatchMessage
        var showTimestamp: Bool = false
        @State private var renderedContent: AttributedString

        init(message: WatchMessage, showTimestamp: Bool = false) {
            self.message = message
            self.showTimestamp = showTimestamp
            _renderedContent = State(initialValue: WatchMarkdownRenderer.render(message.content))
        }

        private static let timeFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            return formatter
        }()

        private var isUser: Bool {
            message.role.lowercased() == "user"
        }

        var body: some View {
            VStack(alignment: isUser ? .trailing : .leading, spacing: Spacing.xxxs) {
                HStack {
                    if isUser {
                        Spacer(minLength: Spacing.Component.bubbleMinWidth - 20)
                    }

                    // Message content
                    Text(renderedContent)
                        .font(Typography.body)
                        .foregroundStyle(isUser ? Theme.userBubbleText : .primary)
                        .padding(.horizontal, Spacing.bubblePaddingH)
                        .padding(.vertical, Spacing.bubblePaddingV)
                        .background(bubbleBackground)
                        .clipShape(BubbleShape(isUser: isUser))

                    if !isUser {
                        Spacer(minLength: Spacing.Component.bubbleMinWidth - 20)
                    }
                }

                // Timestamp (optional, shown for last message)
                if showTimestamp {
                    Text(formattedTime)
                        .font(Typography.micro)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, Spacing.xxs)
                }
            }
            .onChange(of: message.content) { _, newContent in
                renderedContent = WatchMarkdownRenderer.render(newContent)
            }
        }

        private var bubbleBackground: Color {
            isUser ? Theme.userBubble : Theme.assistantBubble
        }

        private var formattedTime: String {
            Self.timeFormatter.string(from: message.timestamp)
        }
    }

    /// Custom bubble shape with tail like iMessage
    struct BubbleShape: Shape {
        let isUser: Bool

        func path(in rect: CGRect) -> Path {
            let width = rect.width
            let height = rect.height
            let radius: CGFloat = Spacing.CornerRadius.xxl

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
        @State private var renderedContent: AttributedString

        init(content: String, isStreaming: Bool) {
            self.content = content
            self.isStreaming = isStreaming
            _renderedContent = State(initialValue: WatchMarkdownRenderer.render(content))
        }

        var body: some View {
            HStack {
                if content.isEmpty, isStreaming {
                    // Typing indicator
                    HStack(spacing: Spacing.xxs) {
                        ForEach(0 ..< 3, id: \.self) { _ in
                            Circle()
                                .fill(Theme.textSecondary)
                                .frame(width: Spacing.xs, height: Spacing.xs)
                        }
                    }
                    .padding(.horizontal, Spacing.bubblePaddingH)
                    .padding(.vertical, Spacing.md - 2)
                    .background(Theme.assistantBubble)
                    .clipShape(RoundedRectangle(cornerRadius: Spacing.CornerRadius.xxl))
                } else {
                    // Content
                    Text(renderedContent)
                        .font(Typography.body)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, Spacing.bubblePaddingH)
                        .padding(.vertical, Spacing.bubblePaddingV)
                        .background(Theme.assistantBubble)
                        .clipShape(RoundedRectangle(cornerRadius: Spacing.CornerRadius.xxl))
                }

                Spacer(minLength: Spacing.Component.bubbleMinWidth - 20)
            }
            .onChange(of: content) { _, newContent in
                renderedContent = WatchMarkdownRenderer.render(newContent)
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
#endif
