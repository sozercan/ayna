//
//  IOSMessageView.swift
//  ayna
//
//  Created on 11/22/25.
//

import Combine
import os.log
import SwiftUI
import UniformTypeIdentifiers

struct IOSMessageView: View {
    let message: Message
    var onRetry: (() -> Void)?

    @State private var contentBlocks: [ContentBlock]
    @State private var lastContentHash: Int
    @State private var decodedImage: UIImage?
    @State private var parseDebounceTask: Task<Void, Never>?
    @State private var lastParseTime: Date = .distantPast

    init(
        message: Message,
        onRetry: (() -> Void)? = nil
    ) {
        self.message = message
        self.onRetry = onRetry
        // Parse content synchronously on init to avoid flash of empty/raw text bubbles
        _contentBlocks = State(initialValue: MarkdownRenderer.parse(message.content))
        _lastContentHash = State(initialValue: message.content.hashValue)
    }

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .user {
                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                if let attachments = message.attachments, !attachments.isEmpty {
                    ForEach(attachments, id: \.fileName) { attachment in
                        HStack {
                            Image(systemName: "doc.fill")
                                .foregroundStyle(.secondary)
                            Text(attachment.fileName)
                                .font(.caption)
                                .lineLimit(1)
                        }
                        .padding(6)
                        .background(Color.black.opacity(0.1))
                        .cornerRadius(6)
                    }
                }

                if message.mediaType == .image, let imageData = message.imageData {
                    if let decodedImage {
                        Image(uiImage: decodedImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 280)
                            .cornerRadius(12)
                    } else {
                        ProgressView()
                            .frame(maxWidth: 280)
                            .task {
                                decodedImage = await Task.detached(priority: .userInitiated) {
                                    UIImage(data: imageData)
                                }.value
                            }
                    }
                }

                // Show typing indicator for empty assistant messages (waiting for response)
                if message.role == .assistant, message.content.isEmpty, message.mediaType != .image {
                    IOSTypingIndicatorView()
                } else if contentBlocks.isEmpty {
                    if !message.content.isEmpty {
                        // Show raw text while parsing or if parsing fails/returns empty
                        Text(message.content)
                    }
                } else {
                    ForEach(contentBlocks) { block in
                        IOSContentBlockView(block: block)
                    }
                }
            }
            .padding(.leading, message.role == .user ? 12 : 18)
            .padding(.trailing, message.role == .user ? 18 : 12)
            .padding(.vertical, 10)
            .background(
                MessageBubbleShape(isFromCurrentUser: message.role == .user)
                    .fill(message.role == .user ? Color.blue : Color(uiColor: .systemGray5))
            )
            .foregroundStyle(message.role == .user ? .white : .primary)
            .frame(maxWidth: 300, alignment: message.role == .user ? .trailing : .leading)
            .contextMenu {
                // Copy button - available for all messages with content
                if !message.content.isEmpty {
                    Button {
                        UIPasteboard.general.string = message.content
                        // Success haptic for copy
                        let generator = UINotificationFeedbackGenerator()
                        generator.notificationOccurred(.success)
                        DiagnosticsLogger.log(
                            .chatView,
                            level: .info,
                            message: "📋 Message copied to clipboard"
                        )
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                }

                // Retry button - only for assistant messages
                if message.role == .assistant, let onRetry {
                    Button {
                        // Medium haptic for retry
                        let generator = UIImpactFeedbackGenerator(style: .medium)
                        generator.impactOccurred()
                        DiagnosticsLogger.log(
                            .chatView,
                            level: .info,
                            message: "🔄 Retry requested via context menu",
                            metadata: ["messageId": message.id.uuidString]
                        )
                        onRetry()
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                }

                // Copy image if present
                if message.mediaType == .image, let imageData = message.imageData,
                   let image = UIImage(data: imageData)
                {
                    Button {
                        UIPasteboard.general.image = image
                        // Success haptic for copy image
                        let generator = UINotificationFeedbackGenerator()
                        generator.notificationOccurred(.success)
                        DiagnosticsLogger.log(
                            .chatView,
                            level: .info,
                            message: "🖼️ Image copied to clipboard"
                        )
                    } label: {
                        Label("Copy Image", systemImage: "photo.on.rectangle")
                    }
                }
            }

            if message.role != .user {
                Spacer()
            }
        }
        .onChange(of: message.content) { _, newContent in
            // Only re-parse if content actually changed
            let newHash = newContent.hashValue
            guard newHash != lastContentHash else { return }
            lastContentHash = newHash

            // Cancel any pending debounce task
            parseDebounceTask?.cancel()

            // Check if enough time has passed since last parse (200ms minimum during streaming)
            let now = Date()
            let timeSinceLastParse = now.timeIntervalSince(lastParseTime)
            let minInterval: TimeInterval = 0.2 // 200ms minimum between parses

            if timeSinceLastParse >= minInterval {
                // Enough time has passed, parse immediately
                performParse(content: newContent)
            } else {
                // Debounce: wait for remaining time before parsing
                let waitTime = minInterval - timeSinceLastParse
                parseDebounceTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(Int(waitTime * 1000)))
                    guard !Task.isCancelled else { return }
                    performParse(content: newContent)
                }
            }
        }
    }

    private func performParse(content: String) {
        lastParseTime = Date()
        Task.detached(priority: .userInitiated) {
            let blocks = MarkdownRenderer.parse(content)
            await MainActor.run {
                contentBlocks = blocks
            }
        }
    }
}

private struct MessageBubbleShape: Shape {
    var isFromCurrentUser: Bool

    func path(in rect: CGRect) -> Path {
        Path { path in
            let tailWidth: CGFloat = 6
            let radius: CGFloat = 18

            if isFromCurrentUser {
                // Right bubble
                let bodyMaxX = rect.maxX - tailWidth

                // Start top-left
                path.move(to: CGPoint(x: rect.minX, y: rect.minY + radius))

                // Top-left corner
                path.addArc(
                    center: CGPoint(x: rect.minX + radius, y: rect.minY + radius),
                    radius: radius,
                    startAngle: Angle(degrees: 180),
                    endAngle: Angle(degrees: 270),
                    clockwise: false
                )

                // Top edge
                path.addLine(to: CGPoint(x: bodyMaxX - radius, y: rect.minY))

                // Top-right corner
                path.addArc(
                    center: CGPoint(x: bodyMaxX - radius, y: rect.minY + radius),
                    radius: radius,
                    startAngle: Angle(degrees: 270),
                    endAngle: Angle(degrees: 0),
                    clockwise: false
                )

                // Right edge
                path.addLine(to: CGPoint(x: bodyMaxX, y: rect.maxY - radius))

                // Tail (Bottom-Right)
                // Curve out to tip
                path.addCurve(
                    to: CGPoint(x: rect.maxX, y: rect.maxY),
                    control1: CGPoint(x: bodyMaxX, y: rect.maxY),
                    control2: CGPoint(x: rect.maxX, y: rect.maxY)
                )

                // Curve back to bottom
                path.addCurve(
                    to: CGPoint(x: bodyMaxX - 4, y: rect.maxY),
                    control1: CGPoint(x: rect.maxX - 2, y: rect.maxY),
                    control2: CGPoint(x: bodyMaxX + 2, y: rect.maxY)
                )

                // Bottom edge
                path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))

                // Bottom-left corner
                path.addArc(
                    center: CGPoint(x: rect.minX + radius, y: rect.maxY - radius),
                    radius: radius,
                    startAngle: Angle(degrees: 90),
                    endAngle: Angle(degrees: 180),
                    clockwise: false
                )

                path.closeSubpath()

            } else {
                // Left bubble
                let bodyMinX = rect.minX + tailWidth

                // Start top-left (after tail)
                path.move(to: CGPoint(x: bodyMinX, y: rect.minY + radius))

                // Top-left corner
                path.addArc(
                    center: CGPoint(x: bodyMinX + radius, y: rect.minY + radius),
                    radius: radius,
                    startAngle: Angle(degrees: 180),
                    endAngle: Angle(degrees: 270),
                    clockwise: false
                )

                // Top edge
                path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))

                // Top-right corner
                path.addArc(
                    center: CGPoint(x: rect.maxX - radius, y: rect.minY + radius),
                    radius: radius,
                    startAngle: Angle(degrees: 270),
                    endAngle: Angle(degrees: 0),
                    clockwise: false
                )

                // Right edge
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))

                // Bottom-right corner
                path.addArc(
                    center: CGPoint(x: rect.maxX - radius, y: rect.maxY - radius),
                    radius: radius,
                    startAngle: Angle(degrees: 0),
                    endAngle: Angle(degrees: 90),
                    clockwise: false
                )

                // Bottom edge
                path.addLine(to: CGPoint(x: bodyMinX + 4, y: rect.maxY))

                // Tail (Bottom-Left)
                // Curve out to tip
                path.addCurve(
                    to: CGPoint(x: rect.minX, y: rect.maxY),
                    control1: CGPoint(x: bodyMinX - 2, y: rect.maxY),
                    control2: CGPoint(x: rect.minX + 2, y: rect.maxY)
                )

                // Curve back to side
                path.addCurve(
                    to: CGPoint(x: bodyMinX, y: rect.maxY - radius),
                    control1: CGPoint(x: rect.minX, y: rect.maxY),
                    control2: CGPoint(x: bodyMinX, y: rect.maxY)
                )

                // Left edge
                path.addLine(to: CGPoint(x: bodyMinX, y: rect.minY + radius))

                path.closeSubpath()
            }
        }
    }
}

struct IOSContentBlockView: View {
    let block: ContentBlock

    var body: some View {
        switch block.type {
        case let .paragraph(text):
            Text(text)
        case let .heading(level, text):
            Text(text).font(.system(size: CGFloat(24 - level * 2), weight: .bold))
        case let .unorderedList(items):
            VStack(alignment: .leading) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top) {
                        Text("•")
                        Text(item)
                    }
                }
            }
        case let .orderedList(start, items):
            VStack(alignment: .leading) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top) {
                        Text("\(start + index).")
                        Text(item)
                    }
                }
            }
        case let .blockquote(text):
            HStack {
                Rectangle().fill(Color.gray).frame(width: 4)
                Text(text).foregroundStyle(.secondary)
            }
        case let .code(code, _):
            ScrollView(.horizontal) {
                Text(code)
                    .font(.monospaced(.body)())
                    .padding()
                    .background(Color.black.opacity(0.1))
                    .cornerRadius(8)
            }
        case .divider:
            Divider()
        case .table:
            Text("[Table]") // Simplified for now
        case let .tool(name, result):
            VStack(alignment: .leading) {
                Text("Tool: \(name)").font(.caption).bold()
                Text(result).font(.caption).foregroundStyle(.secondary)
            }
            .padding(8)
            .background(Color.orange.opacity(0.1))
            .cornerRadius(8)
        }
    }
}

// Typing indicator for text responses (iOS version)
struct IOSTypingIndicatorView: View {
    @State private var animatingDot = 0

    let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0 ..< 3, id: \.self) { index in
                Circle()
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 8, height: 8)
                    .scaleEffect(animatingDot == index ? 1.2 : 0.8)
                    .animation(.easeInOut(duration: 0.4), value: animatingDot)
            }
        }
        .padding(.vertical, 4)
        .onReceive(timer) { _ in
            animatingDot = (animatingDot + 1) % 3
        }
    }
}
