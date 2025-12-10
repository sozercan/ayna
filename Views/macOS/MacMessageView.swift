//
//  MacMessageView.swift
//  ayna
//
//  Created on 11/2/25.
//

// swiftlint:disable file_length

import SwiftUI

// MARK: - Design System Integration

// Uses Theme, Typography, Spacing, and Motion from Core/Design/

@MainActor
struct MacMessageView: View {
    let message: Message
    var modelName: String?
    var onRetry: (() -> Void)?
    var onSwitchModel: ((String) -> Void)?
    @State private var isHovered = false
    @State private var showReasoning = false
    @State private var showModelMenu = false
    @EnvironmentObject var conversationManager: ConversationManager
    @ObservedObject private var openAIService = OpenAIService.shared

    // Performance: Cache parsed content blocks to avoid re-parsing on every render
    // Initialize synchronously to avoid flash of empty bubbles on first render
    @State private var cachedContentBlocks: [ContentBlock]
    @State private var cachedReasoningBlocks: [ContentBlock]
    @State private var lastContentHash: Int
    @State private var lastReasoningHash: Int
    @State private var parseTask: Task<Void, Never>?
    @State private var reasoningParseTask: Task<Void, Never>?
    @State private var parseDebounceTask: Task<Void, Never>?
    @State private var lastParseTime: Date = .distantPast

    init(
        message: Message,
        modelName: String? = nil,
        onRetry: (() -> Void)? = nil,
        onSwitchModel: ((String) -> Void)? = nil
    ) {
        self.message = message
        self.modelName = modelName
        self.onRetry = onRetry
        self.onSwitchModel = onSwitchModel
        // Parse content synchronously on init to avoid flash of empty bubbles
        _cachedContentBlocks = State(initialValue: MarkdownRenderer.parse(message.content))
        _lastContentHash = State(initialValue: message.content.hashValue)
        if let reasoning = message.reasoning {
            _cachedReasoningBlocks = State(initialValue: MarkdownRenderer.parse(reasoning))
            _lastReasoningHash = State(initialValue: reasoning.hashValue)
        } else {
            _cachedReasoningBlocks = State(initialValue: [])
            _lastReasoningHash = State(initialValue: 0)
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    // Design tokens from Core/Design/
    private let userBubbleGradient = Theme.userBubbleGradient
    private let recipientBubbleGradient = Theme.assistantBubbleGradient
    private let toolBubbleColor = Theme.toolBubble

    private var primaryToolCall: MCPToolCall? {
        message.toolCalls?.first
    }

    private var toolDisplayName: String {
        primaryToolCall?.toolName ?? "Tool Result"
    }

    private var formattedToolArguments: String? {
        guard let arguments = primaryToolCall?.arguments, !arguments.isEmpty else {
            return nil
        }

        let rawArguments = arguments.reduce(into: [String: Any]()) { result, entry in
            result[entry.key] = entry.value.value
        }

        guard JSONSerialization.isValidJSONObject(rawArguments),
              let data = try? JSONSerialization.data(withJSONObject: rawArguments, options: [.prettyPrinted]),
              let jsonString = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        return jsonString
    }

    @MainActor private struct ToolCallResultCard: View {
        let toolName: String
        let arguments: String?
        let contentBlocks: [ContentBlock]
        let fallbackText: String
        @State private var isExpanded = false

        private var previewText: String {
            let trimmed = fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Tool returned no output." : trimmed
        }

        var body: some View {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Button(action: {
                    withAnimation(Motion.springSnappy) {
                        isExpanded.toggle()
                    }
                }) {
                    HStack(spacing: Spacing.md) {
                        Spacer()

                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(Typography.caption)
                            .foregroundStyle(Theme.userBubbleText.opacity(0.7))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())

                if !isExpanded {
                    Text(previewText)
                        .font(Typography.bodySecondary)
                        .foregroundStyle(Theme.userBubbleText.opacity(0.9))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    if let arguments, !arguments.isEmpty {
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            Text("Arguments")
                                .font(Typography.caption)
                                .foregroundStyle(Theme.userBubbleText.opacity(0.7))
                            ScrollView(.horizontal, showsIndicators: false) {
                                Text(arguments)
                                    .font(Typography.code)
                                    .foregroundStyle(Theme.userBubbleText)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(Spacing.sm)
                            .background(Color.black.opacity(0.15))
                            .clipShape(.rect(cornerRadius: Spacing.CornerRadius.md))
                        }
                    }

                    Divider()
                        .background(Theme.separator)

                    if contentBlocks.isEmpty {
                        Text(previewText)
                            .font(Typography.bodySecondary)
                            .foregroundStyle(Theme.userBubbleText)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        VStack(alignment: .leading, spacing: Spacing.sm) {
                            ForEach(contentBlocks, id: \.id) { block in
                                block.view
                            }
                        }
                        .foregroundStyle(Theme.userBubbleText)
                    }
                }
            }
            .padding(Spacing.md)
        }
    }

    @MainActor var body: some View {
        messageContent
            .padding(.horizontal, Spacing.contentPadding)
            .padding(.vertical, Spacing.xs)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovered = hovering
            }
            .onAppear {
                updateCachedBlocks()
                updateCachedReasoningBlocks()
            }
            .onChange(of: message.content) { _, _ in
                updateCachedBlocks()
            }
            .onChange(of: message.reasoning) { _, _ in
                updateCachedReasoningBlocks()
            }
    }

    private var accessibilityText: String {
        if message.role == .tool {
            let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = trimmed.isEmpty ? "Tool returned no visible text." : trimmed
            return "Tool \(toolDisplayName) result. \(summary)"
        }

        if message.content.isEmpty {
            return message.role == .assistant ? "Assistant response" : "User message"
        }

        return message.content
    }

    @MainActor @ViewBuilder
    private var messageContent: some View {
        if message.role == .tool {
            toolMessageView
        } else {
            bubbleMessageView
        }
    }

    @MainActor
    private var bubbleMessageView: some View {
        let isCurrentUser = message.role == .user
        let alignment: HorizontalAlignment = isCurrentUser ? .trailing : .leading

        return VStack(alignment: alignment, spacing: 6) {
            if message.role == .assistant, let modelName {
                Text(modelName)
                    .font(Typography.captionBold)
                    .foregroundStyle(Theme.textSecondary)
            }

            HStack(alignment: .bottom, spacing: Spacing.sm) {
                if isCurrentUser {
                    Spacer(minLength: Spacing.Component.bubbleMinWidth)
                }

                bubbleContainer(isCurrentUser: isCurrentUser)

                if !isCurrentUser {
                    Spacer(minLength: Spacing.Component.bubbleMinWidth)
                }
            }

            Text(timestampText)
                .font(Typography.timestamp)
                .foregroundStyle(Theme.textSecondary)
                .padding(isCurrentUser ? .trailing : .leading, Spacing.xs)
        }
    }

    @MainActor
    private func bubbleContainer(isCurrentUser: Bool) -> some View {
        let bubbleStyle = isCurrentUser ? userBubbleGradient : recipientBubbleGradient

        return ZStack(alignment: isCurrentUser ? .topLeading : .topTrailing) {
            VStack(alignment: .leading, spacing: Spacing.md) {
                bubbleContent
            }
            .frame(maxWidth: Spacing.Component.bubbleMaxWidth, alignment: .leading)
            .foregroundStyle(Theme.userBubbleText)
            .padding(.leading, isCurrentUser ? Spacing.bubblePaddingH : Spacing.contentPadding)
            .padding(.trailing, isCurrentUser ? Spacing.contentPadding : Spacing.bubblePaddingH)
            .padding(.vertical, Spacing.bubblePaddingV)
            .background(
                MessageBubbleShape(isFromCurrentUser: isCurrentUser)
                    .fill(bubbleStyle)
            )
            .overlay(
                MessageBubbleShape(isFromCurrentUser: isCurrentUser)
                    .stroke(Theme.border, lineWidth: Spacing.Border.standard)
            )
            .shadow(color: Theme.shadow, radius: Spacing.Shadow.radiusStandard, x: 0, y: Spacing.Shadow.offsetYElevated)
            .environment(\.colorScheme, .dark)
            .tint(.white)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(verbatim: accessibilityText))
            .accessibilityIdentifier("chat.message.\(message.id.uuidString)")

            actionControls(for: message.role)
                .offset(y: -26)
        }
        .padding(.top, 30) // Extra space for action controls above bubble
        .contentShape(Rectangle()) // Make entire area including controls hoverable
        .animation(Motion.easeStandard, value: isHovered)
    }

    @MainActor @ViewBuilder
    private var bubbleContent: some View {
        // Attachments
        if let attachments = message.attachments, !attachments.isEmpty {
            ForEach(attachments.indices, id: \.self) { index in
                let attachment = attachments[index]
                if attachment.mimeType.starts(with: "image/"),
                   let data = attachment.content,
                   let nsImage = NSImage(data: data)
                {
                    VStack(alignment: .leading, spacing: 4) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 360)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
                            .contextMenu {
                                Button("Save Image...") {
                                    saveImage(nsImage)
                                }
                                Button("Copy Image") {
                                    copyImage(nsImage)
                                }
                            }
                        Text(attachment.fileName)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
            }
        }

        // Generated images
        if message.mediaType == .image {
            if let imageData = message.effectiveImageData, let nsImage = NSImage(data: imageData) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 420)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.25), radius: 10, x: 0, y: 4)
                    .contextMenu {
                        Button("Save Image...") {
                            saveImage(nsImage)
                        }
                        Button("Copy Image") {
                            copyImage(nsImage)
                        }
                    }
            } else {
                ImageGeneratingView()
            }
        }

        // Check if message has meaningful reasoning content
        let hasReasoning = message.reasoning.map { !$0.isEmpty } ?? false

        // Show typing indicator for empty assistant messages (waiting for response)
        // But not if we have reasoning content (model is thinking)
        if message.role == .assistant, message.content.isEmpty, message.mediaType != .image, !hasReasoning {
            TypingIndicatorView()
        }

        if hasReasoning, let reasoning = message.reasoning {
            // Determine if still actively thinking (has reasoning but no content yet)
            let isStillThinking = message.content.isEmpty && message.mediaType != .image

            Button(action: {
                withAnimation(Motion.springStandard) {
                    showReasoning.toggle()
                }
            }) {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: showReasoning ? "chevron.down" : "chevron.right")
                        .font(Typography.caption)
                    Text(isStillThinking ? "Thinking..." : "Thinking")
                        .font(Typography.captionBold)
                    if isStillThinking {
                        // Show animated indicator while still thinking
                        ThinkingIndicatorDots()
                    }
                    Spacer(minLength: 0)
                    Text("\(reasoning.count) chars")
                        .font(Typography.caption)
                        .foregroundStyle(Theme.userBubbleText.opacity(0.7))
                }
                .foregroundStyle(Theme.userBubbleText)
                .padding(.vertical, Spacing.xs)
                .padding(.horizontal, Spacing.md)
                .background(Color.white.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)

            if showReasoning {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    ForEach(cachedReasoningBlocks, id: \.id) { block in
                        block.view
                    }
                }
                .padding(Spacing.md)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: Spacing.CornerRadius.lg))
            }
        }

        ForEach(cachedContentBlocks, id: \.id) { block in
            block.view
        }

        // Citation sources footer for web search results
        if let citations = message.citations, !citations.isEmpty {
            CitationSourcesFooter(citations: citations)
                .padding(.top, 8)
        }
    }

    @MainActor @ViewBuilder
    private func actionControls(for role: Message.Role) -> some View {
        if isHovered || UITestEnvironment.isEnabled {
            HStack(spacing: Spacing.xxs) {
                Button(action: {
                    copyToClipboard(message.content)
                }) {
                    Image(systemName: "doc.on.doc")
                        .font(Typography.caption)
                        .padding(Spacing.sm)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("message.action.copy")
                .accessibilityLabel("Copy message")

                if role == .assistant {
                    Menu {
                        Section {
                            Text("Used \(modelName ?? message.model ?? "Unknown Model")")
                                .font(Typography.caption)
                        }

                        Divider()

                        if let onRetry {
                            Button(action: onRetry) {
                                Label("Try Again", systemImage: "arrow.clockwise")
                            }
                        }

                        Menu {
                            ForEach(openAIService.usableModels, id: \.self) { model in
                                Button(action: {
                                    onSwitchModel?(model)
                                }) {
                                    HStack {
                                        Text(model)
                                        if model == modelName || model == message.model {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            Label("Switch Model", systemImage: "arrow.left.arrow.right")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(Typography.caption)
                            .padding(Spacing.sm)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("More options")
                }
            }
            .foregroundStyle(Theme.userBubbleText)
            .background(.ultraThinMaterial, in: Capsule())
            .shadow(color: Theme.shadowElevated, radius: Spacing.Shadow.radiusSubtle, x: 0, y: 3)
            .transition(Motion.scaleTransition)
        }
    }

    @MainActor
    private var toolMessageView: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(toolDisplayName)
                .font(Typography.captionBold)
                .foregroundStyle(Theme.textSecondary)

            HStack(alignment: .bottom) {
                ZStack(alignment: .topTrailing) {
                    VStack(alignment: .leading, spacing: 12) {
                        ToolCallResultCard(
                            toolName: toolDisplayName,
                            arguments: formattedToolArguments,
                            contentBlocks: cachedContentBlocks,
                            fallbackText: message.content
                        )
                    }
                    .frame(maxWidth: Spacing.Component.bubbleMaxWidth, alignment: .leading)
                    .foregroundStyle(Theme.userBubbleText)
                    .padding(.leading, Spacing.contentPadding)
                    .padding(.trailing, Spacing.bubblePaddingH)
                    .padding(.vertical, Spacing.bubblePaddingV)
                    .background(
                        MessageBubbleShape(isFromCurrentUser: false)
                            .fill(toolBubbleColor)
                    )
                    .overlay(
                        MessageBubbleShape(isFromCurrentUser: false)
                            .stroke(Theme.border, lineWidth: Spacing.Border.standard)
                    )
                    .shadow(color: Theme.toolBubble.opacity(0.3), radius: Spacing.Shadow.radiusStandard, x: 0, y: Spacing.Shadow.offsetYElevated)
                    .environment(\.colorScheme, .dark)
                    .accessibilityIdentifier("chat.message.\(message.id.uuidString)")

                    actionControls(for: message.role)
                        .offset(y: -26)
                }

                Spacer(minLength: 40)
            }

            Text(timestampText)
                .font(Typography.timestamp)
                .foregroundStyle(Theme.textSecondary)
                .padding(.leading, Spacing.xs)
        }
    }

    private var timestampText: String {
        Self.timestampFormatter.string(from: message.timestamp)
    }

    private func updateCachedBlocks() {
        let content = message.content
        let newHash = content.hashValue
        guard newHash != lastContentHash else { return }
        lastContentHash = newHash

        // Cancel any pending debounce task
        parseDebounceTask?.cancel()

        // Check if enough time has passed since last parse (400ms minimum during streaming)
        let now = Date()
        let timeSinceLastParse = now.timeIntervalSince(lastParseTime)
        let minInterval: TimeInterval = 0.4 // 400ms minimum between parses

        if timeSinceLastParse >= minInterval {
            // Enough time has passed, parse immediately
            performParse(content: content)
        } else {
            // Debounce: wait for remaining time before parsing
            let waitTime = minInterval - timeSinceLastParse
            parseDebounceTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(Int(waitTime * 1000)))
                guard !Task.isCancelled else { return }
                performParse(content: content)
            }
        }
    }

    private func performParse(content: String) {
        lastParseTime = Date()
        parseTask?.cancel()
        parseTask = Task.detached(priority: .userInitiated) {
            let blocks = MarkdownRenderer.parse(content)
            if !Task.isCancelled {
                await MainActor.run {
                    cachedContentBlocks = blocks
                }
            }
        }
    }

    private func updateCachedReasoningBlocks() {
        if let reasoning = message.reasoning {
            let newHash = reasoning.hashValue
            if newHash != lastReasoningHash {
                lastReasoningHash = newHash
                reasoningParseTask?.cancel()
                reasoningParseTask = Task.detached(priority: .userInitiated) {
                    let blocks = MarkdownRenderer.parse(reasoning)
                    if !Task.isCancelled {
                        await MainActor.run {
                            cachedReasoningBlocks = blocks
                        }
                    }
                }
            }
        }
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func saveImage(_ image: NSImage) {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.png, .jpeg]
        savePanel.nameFieldStringValue = "generated-image.png"

        savePanel.begin { response in
            if response == .OK, let url = savePanel.url {
                if let tiffData = image.tiffRepresentation,
                   let bitmapImage = NSBitmapImageRep(data: tiffData),
                   let pngData = bitmapImage.representation(using: .png, properties: [:])
                {
                    try? pngData.write(to: url)
                }
            }
        }
    }

    private func copyImage(_ image: NSImage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }
}

private struct MessageBubbleShape: Shape {
    var isFromCurrentUser: Bool

    func path(in rect: CGRect) -> Path {
        let path = Path { path in
            let tailWidth: CGFloat = Spacing.xs
            let radius: CGFloat = Spacing.CornerRadius.bubble

            if isFromCurrentUser {
                // Right bubble
                let bodyMaxX = rect.maxX - tailWidth

                // Start top-left
                path.move(to: CGPoint(x: rect.minX, y: rect.minY + radius))

                // Top-left corner
                path.addArc(center: CGPoint(x: rect.minX + radius, y: rect.minY + radius),
                            radius: radius,
                            startAngle: Angle(degrees: 180),
                            endAngle: Angle(degrees: 270),
                            clockwise: false)

                // Top edge
                path.addLine(to: CGPoint(x: bodyMaxX - radius, y: rect.minY))

                // Top-right corner
                path.addArc(center: CGPoint(x: bodyMaxX - radius, y: rect.minY + radius),
                            radius: radius,
                            startAngle: Angle(degrees: 270),
                            endAngle: Angle(degrees: 0),
                            clockwise: false)

                // Right edge
                path.addLine(to: CGPoint(x: bodyMaxX, y: rect.maxY - radius))

                // Tail (Bottom-Right)
                // Curve out to tip
                path.addCurve(to: CGPoint(x: rect.maxX, y: rect.maxY),
                              control1: CGPoint(x: bodyMaxX, y: rect.maxY),
                              control2: CGPoint(x: rect.maxX, y: rect.maxY))

                // Curve back to bottom
                path.addCurve(to: CGPoint(x: bodyMaxX - 4, y: rect.maxY),
                              control1: CGPoint(x: rect.maxX - 2, y: rect.maxY),
                              control2: CGPoint(x: bodyMaxX + 2, y: rect.maxY))

                // Bottom edge
                path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))

                // Bottom-left corner
                path.addArc(center: CGPoint(x: rect.minX + radius, y: rect.maxY - radius),
                            radius: radius,
                            startAngle: Angle(degrees: 90),
                            endAngle: Angle(degrees: 180),
                            clockwise: false)

                path.closeSubpath()

            } else {
                // Left bubble
                let bodyMinX = rect.minX + tailWidth

                // Start top-left (after tail)
                path.move(to: CGPoint(x: bodyMinX, y: rect.minY + radius))

                // Top-left corner
                path.addArc(center: CGPoint(x: bodyMinX + radius, y: rect.minY + radius),
                            radius: radius,
                            startAngle: Angle(degrees: 180),
                            endAngle: Angle(degrees: 270),
                            clockwise: false)

                // Top edge
                path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))

                // Top-right corner
                path.addArc(center: CGPoint(x: rect.maxX - radius, y: rect.minY + radius),
                            radius: radius,
                            startAngle: Angle(degrees: 270),
                            endAngle: Angle(degrees: 0),
                            clockwise: false)

                // Right edge
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))

                // Bottom-right corner
                path.addArc(center: CGPoint(x: rect.maxX - radius, y: rect.maxY - radius),
                            radius: radius,
                            startAngle: Angle(degrees: 0),
                            endAngle: Angle(degrees: 90),
                            clockwise: false)

                // Bottom edge
                path.addLine(to: CGPoint(x: bodyMinX + 4, y: rect.maxY))

                // Tail (Bottom-Left)
                // Curve out to tip
                path.addCurve(to: CGPoint(x: rect.minX, y: rect.maxY),
                              control1: CGPoint(x: bodyMinX - 2, y: rect.maxY),
                              control2: CGPoint(x: rect.minX + 2, y: rect.maxY))

                // Curve back to side
                path.addCurve(to: CGPoint(x: bodyMinX, y: rect.maxY - radius),
                              control1: CGPoint(x: rect.minX, y: rect.maxY),
                              control2: CGPoint(x: bodyMinX, y: rect.maxY))

                // Left edge
                path.addLine(to: CGPoint(x: bodyMinX, y: rect.minY + radius))

                path.closeSubpath()
            }
        }
        return path
    }
}

extension ContentBlock {
    @MainActor @ViewBuilder
    var view: some View {
        switch type {
        case let .paragraph(text):
            Text(text)
                .font(Typography.body)
                .lineSpacing(Typography.bodyLineSpacing)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

        case let .heading(level, text):
            let font: Font = switch level {
            case 1:
                Typography.title2
            case 2:
                Typography.title3
            case 3:
                Typography.headline
            default:
                Typography.subheadline
            }
            Text(text)
                .font(font)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, level == 1 ? Spacing.xxs : Spacing.xxxs)

        case let .unorderedList(items):
            VStack(alignment: .leading, spacing: Spacing.xs) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                        Text("•")
                            .font(Typography.subheadline)
                            .accessibilityHidden(true)
                        Text(item)
                            .font(Typography.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, Spacing.xxxs)
                    .accessibilityLabel("Bullet item \(index + 1)")
                }
            }

        case let .orderedList(start, items):
            VStack(alignment: .leading, spacing: Spacing.xs) {
                ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                        Text(verbatim: "\(start + offset).")
                            .font(Typography.bodySecondary.weight(.semibold))
                            .frame(width: Spacing.xxxl, alignment: .trailing)
                            .accessibilityHidden(true)
                        Text(item)
                            .font(Typography.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case let .blockquote(text):
            HStack(alignment: .top, spacing: Spacing.md) {
                Rectangle()
                    .fill(Theme.textSecondary.opacity(0.4))
                    .frame(width: 3)
                    .clipShape(.rect(cornerRadius: 3))

                Text(text)
                    .font(Typography.body.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineSpacing(Typography.bodyLineSpacing)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Spacing.md)
            .background(Theme.textSecondary.opacity(0.08))
            .clipShape(.rect(cornerRadius: Spacing.CornerRadius.lg))

        case let .table(table):
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(spacing: 0) {
                    tableRowView(table.headers, alignments: table.alignments, isHeader: true)
                        .background(Theme.textSecondary.opacity(0.12))
                    Divider()
                    ForEach(Array(table.rows.enumerated()), id: \.offset) { rowIndex, row in
                        tableRowView(row, alignments: table.alignments, isHeader: false)
                        if rowIndex < table.rows.count - 1 {
                            Divider()
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Spacing.CornerRadius.md))
            }
            .background(Theme.textSecondary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: Spacing.CornerRadius.md))

        case .divider:
            Divider()
                .overlay(Theme.separator)

        case let .code(code, language):
            VStack(alignment: .leading, spacing: 0) {
                // Header with language and copy button
                HStack {
                    if !language.isEmpty {
                        Text(language.lowercased())
                            .font(Typography.captionBold)
                            .foregroundStyle(Theme.textSecondary)
                            .textCase(.lowercase)
                    }

                    Spacer()

                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                    }) {
                        HStack(spacing: Spacing.xxs) {
                            Image(systemName: "doc.on.doc")
                            Text("Copy code")
                        }
                        .font(Typography.caption)
                        .foregroundStyle(Theme.textSecondary)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .background(Theme.codeBackground.opacity(0.3))

                Divider()

                // Code content with syntax highlighting
                ScrollView(.horizontal, showsIndicators: false) {
                    SyntaxHighlightedCodeView(code: code, language: language)
                        .padding(Spacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .background(Theme.codeBackground)
            .overlay(
                RoundedRectangle(cornerRadius: Spacing.CornerRadius.md)
                    .stroke(Theme.codeBorder, lineWidth: Spacing.Border.standard)
            )
            .clipShape(RoundedRectangle(cornerRadius: Spacing.CornerRadius.md))

        case let .tool(name, result):
            VStack(alignment: .leading, spacing: 0) {
                // Tool header
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "wrench.and.screwdriver.fill")
                        .font(Typography.caption)
                        .foregroundStyle(Theme.userBubbleText)
                        .frame(width: Spacing.contentPadding, height: Spacing.contentPadding)
                        .background(
                            LinearGradient(
                                colors: [Theme.accent, Theme.accent.opacity(0.8)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: Spacing.CornerRadius.sm))

                    VStack(alignment: .leading, spacing: Spacing.xxxs) {
                        Text("Tool")
                            .font(Typography.micro)
                            .foregroundStyle(Theme.textSecondary)
                            .textCase(.uppercase)
                        Text(name)
                            .font(Typography.captionBold)
                            .foregroundStyle(Theme.textPrimary)
                    }

                    Spacer()

                    Image(systemName: "checkmark.circle.fill")
                        .font(Typography.bodySecondary)
                        .foregroundStyle(Theme.statusConnected)
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.md - 2)
                .background(Theme.accent.opacity(0.08))

                Divider()

                // Tool result
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(result)
                        .font(Typography.bodySecondary)
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                        .padding(Spacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
            }
            .background(Theme.accent.opacity(0.03))
            .overlay(
                RoundedRectangle(cornerRadius: Spacing.CornerRadius.md)
                    .stroke(Theme.accent.opacity(0.2), lineWidth: Spacing.Border.emphasized)
            )
            .clipShape(RoundedRectangle(cornerRadius: Spacing.CornerRadius.md))
            .shadow(color: Theme.accent.opacity(0.1), radius: Spacing.Shadow.radiusSubtle, x: 0, y: Spacing.Shadow.offsetY)
        }
    }

    @ViewBuilder
    private func tableRowView(
        _ cells: [AttributedString],
        alignments: [MarkdownTable.ColumnAlignment],
        isHeader: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: Spacing.lg) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                let columnAlignment = alignments.indices.contains(index) ? alignments[index] : .leading
                Text(cell)
                    .font(isHeader ? Typography.captionBold : Typography.bodySecondary)
                    .textSelection(.enabled)
                    .frame(minWidth: 80, alignment: horizontalAlignment(for: columnAlignment))
            }
        }
        .padding(.vertical, isHeader ? Spacing.md - 2 : Spacing.sm)
        .padding(.horizontal, Spacing.md)
    }

    private func horizontalAlignment(for alignment: MarkdownTable.ColumnAlignment) -> Alignment {
        switch alignment {
        case .leading:
            .leading
        case .center:
            .center
        case .trailing:
            .trailing
        }
    }
}

#Preview {
    VStack(spacing: 16) {
        MacMessageView(message: Message(
            role: .user,
            content: "What is SwiftUI?"
        ))

        MacMessageView(message: Message(
            role: .assistant,
            content: """
            SwiftUI is Apple's modern framework for building user interfaces across all Apple platforms. Here are some key features:

            - **Declarative Syntax**: Describe what your UI should look like
            - **Cross-Platform**: Works on iOS, macOS, watchOS, and tvOS
            - **Live Preview**: See changes instantly in Xcode
            - **Built-in Animations**: Smooth transitions with minimal code

            ```swift
            struct ContentView: View {
                var body: some View {
                    Text("Hello, SwiftUI!")
                }
            }
            ```
            """
        ))
    }
    .padding()
    .frame(width: 600)
}

// Loading animation for image generation
struct ImageGeneratingView: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        ZStack {
            // Background
            RoundedRectangle(cornerRadius: Spacing.CornerRadius.xl)
                .fill(Theme.textSecondary.opacity(0.08))
                .strokeBorder(Theme.border, lineWidth: Spacing.Border.standard)

            VStack(spacing: Spacing.lg) {
                // Animated Icon
                ZStack {
                    Circle()
                        .fill(Theme.accent.opacity(0.1))
                        .frame(width: Typography.IconSize.heroLarge, height: Typography.IconSize.heroLarge)
                        .scaleEffect(1 + sin(phase) * 0.1)

                    if #available(macOS 15.0, *) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 30))
                            .foregroundStyle(Theme.accent)
                            .symbolEffect(.bounce, options: .repeating)
                    } else {
                        Image(systemName: "sparkles")
                            .font(.system(size: 30))
                            .foregroundStyle(Theme.accent)
                            .symbolEffect(.variableColor)
                    }
                }

                Text("Dreaming up your image...")
                    .font(Typography.bodySecondary.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(width: 320, height: 320)
        .onAppear {
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                phase = .pi * 2
            }
        }
    }
}

// MARK: - Syntax Highlighting Regex Cache

/// Pre-compiled regex patterns for syntax highlighting to avoid expensive regex compilation
/// on every render. This cache is shared across all instances of SyntaxHighlightedCodeView.
/// Thread-safety is ensured through the use of nonisolated(unsafe) and atomic initialization.
private enum SyntaxRegexCache {
    /// Thread-safe cache for compiled regex patterns using a concurrent dictionary pattern
    private final class RegexCache: @unchecked Sendable {
        private var cache: [String: NSRegularExpression] = [:]
        private let lock = NSLock()

        func get(_ pattern: String) -> NSRegularExpression? {
            lock.lock()
            defer { lock.unlock() }

            if let cached = cache[pattern] {
                return cached
            }

            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
                return nil
            }

            cache[pattern] = regex
            return regex
        }
    }

    private static let sharedCache = RegexCache()

    /// Pre-compiled keyword patterns for each language
    static let swiftKeywords = createKeywordPattern([
        "func", "var", "let", "if", "else", "for", "while", "return", "import", "class", "struct",
        "enum", "protocol", "extension", "public", "private", "internal", "static", "override",
        "init", "self", "super", "nil", "true", "false", "guard", "switch", "case", "default",
        "break", "continue", "in", "where", "as", "is", "try", "catch", "throw", "throws",
        "async", "await", "actor"
    ])

    static let pythonKeywords = createKeywordPattern([
        "def", "class", "if", "elif", "else", "for", "while", "return", "import", "from", "as",
        "try", "except", "finally", "with", "lambda", "yield", "async", "await", "pass", "break",
        "continue", "and", "or", "not", "in", "is", "None", "True", "False", "self"
    ])

    static let jsKeywords = createKeywordPattern([
        "function", "const", "let", "var", "if", "else", "for", "while", "return", "import",
        "export", "class", "extends", "constructor", "this", "super", "async", "await", "try",
        "catch", "throw", "new", "typeof", "instanceof", "null", "undefined", "true", "false",
        "switch", "case", "default", "break", "continue"
    ])

    static let bashKeywords = createKeywordPattern([
        "if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac",
        "function", "return", "echo", "exit", "export", "source", "cd", "ls", "cp", "mv",
        "rm", "mkdir", "chmod", "sudo", "apt", "brew", "npm", "pip", "git"
    ])

    static let rustKeywords = createKeywordPattern([
        "fn", "let", "mut", "if", "else", "for", "while", "loop", "return", "use", "mod",
        "pub", "struct", "enum", "impl", "trait", "type", "where", "match", "self", "Self",
        "true", "false", "const", "static", "async", "await", "move"
    ])

    static let goKeywords = createKeywordPattern([
        "func", "var", "const", "if", "else", "for", "range", "return", "import", "package",
        "type", "struct", "interface", "map", "chan", "go", "defer", "select", "switch", "case",
        "default", "break", "continue", "nil", "true", "false"
    ])

    static let javaKeywords = createKeywordPattern([
        "public", "private", "protected", "class", "interface", "extends", "implements", "if",
        "else", "for", "while", "return", "import", "package", "new", "this", "super", "static",
        "final", "void", "int", "String", "boolean", "true", "false", "null", "try", "catch",
        "throw", "throws"
    ])

    static let cKeywords = createKeywordPattern([
        "if", "else", "for", "while", "return", "void", "int", "char", "float", "double",
        "struct", "typedef", "enum", "union", "static", "const", "sizeof", "break", "continue",
        "switch", "case", "default", "#include", "#define", "NULL"
    ])

    static let rubyKeywords = createKeywordPattern([
        "def", "end", "class", "module", "if", "elsif", "else", "unless", "case", "when", "for",
        "while", "until", "do", "return", "yield", "self", "super", "nil", "true", "false",
        "and", "or", "not", "begin", "rescue", "ensure"
    ])

    static let phpKeywords = createKeywordPattern([
        "function", "class", "if", "else", "elseif", "for", "foreach", "while", "return",
        "public", "private", "protected", "static", "new", "this", "self", "parent", "try",
        "catch", "throw", "null", "true", "false", "echo", "print", "require", "include"
    ])

    // Common patterns used across multiple languages
    static let doubleQuoteString = getOrCreate("\"(?:[^\"\\\\]|\\\\.)*\"")
    static let singleQuoteString = getOrCreate("'(?:[^'\\\\]|\\\\.)*'")
    static let backtickString = getOrCreate("`(?:[^`\\\\]|\\\\.)*`")
    static let singleLineComment = getOrCreate("//.*")
    static let hashComment = getOrCreate("#.*")
    static let multiLineComment = getOrCreate("/\\*[\\s\\S]*?\\*/")
    static let htmlComment = getOrCreate("<!--.*?-->")
    static let numbers = getOrCreate("\\b\\d+\\.?\\d*\\b")
    static let phpVariable = getOrCreate("\\$[a-zA-Z_][a-zA-Z0-9_]*")
    static let bashVariable = getOrCreate("\\$[a-zA-Z_][a-zA-Z0-9_]*")
    static let jsonKeyPattern = getOrCreate("\"[^\"]*\"\\s*:")
    static let jsonLiterals = getOrCreate("\\b(true|false|null)\\b")
    static let htmlTags = getOrCreate("<[^>]+>")
    static let cssSelector = getOrCreate("[.#][a-zA-Z][a-zA-Z0-9_-]*")
    static let cssProperty = getOrCreate("[a-zA-Z-]+(?=\\s*:)")

    /// Create a keyword pattern from array of keywords
    private static func createKeywordPattern(_ keywords: [String]) -> NSRegularExpression? {
        let pattern = "\\b(" + keywords.joined(separator: "|") + ")\\b"
        return try? NSRegularExpression(pattern: pattern, options: [])
    }

    /// Get or create a cached regex for the given pattern
    static func getOrCreate(_ pattern: String) -> NSRegularExpression? {
        sharedCache.get(pattern)
    }
}

// Syntax highlighted code view
struct SyntaxHighlightedCodeView: View {
    let code: String
    let language: String

    var body: some View {
        Text(AttributedString(highlightedCode()))
            .font(Typography.codeBlock)
            .textSelection(.enabled)
    }

    private func highlightedCode() -> NSAttributedString {
        let attributedString = NSMutableAttributedString(string: code)
        let fullRange = NSRange(location: 0, length: code.utf16.count)

        // Base styling
        let baseFont = NSFont.monospacedSystemFont(ofSize: Typography.Size.body, weight: .regular)
        let baseColor = NSColor.labelColor
        attributedString.addAttribute(.font, value: baseFont, range: fullRange)
        attributedString.addAttribute(.foregroundColor, value: baseColor, range: fullRange)

        // Apply syntax highlighting based on language
        let normalizedLang = language.lowercased()

        switch normalizedLang {
        case "swift":
            highlightSwift(attributedString)
        case "python", "py":
            highlightPython(attributedString)
        case "javascript", "js", "typescript", "ts":
            highlightJavaScript(attributedString)
        case "bash", "sh", "shell", "zsh":
            highlightBash(attributedString)
        case "json":
            highlightJSON(attributedString)
        case "html", "xml":
            highlightHTML(attributedString)
        case "css", "scss", "sass":
            highlightCSS(attributedString)
        case "rust", "rs":
            highlightRust(attributedString)
        case "go":
            highlightGo(attributedString)
        case "java", "kotlin":
            highlightJava(attributedString)
        case "c", "cpp", "c++", "objc":
            highlightC(attributedString)
        case "ruby", "rb":
            highlightRuby(attributedString)
        case "php":
            highlightPHP(attributedString)
        default:
            highlightGeneric(attributedString)
        }

        return attributedString
    }

    private func highlightSwift(_ attributedString: NSMutableAttributedString) {
        // Use pre-compiled patterns from cache
        if let keywordRegex = SyntaxRegexCache.swiftKeywords {
            applyRegex(keywordRegex, to: attributedString, color: .systemPink)
        }
        highlightStrings(attributedString, color: .systemRed)
        highlightComments(attributedString, color: .systemGreen)
        highlightNumbers(attributedString, color: .systemBlue)
    }

    private func highlightPython(_ attributedString: NSMutableAttributedString) {
        if let keywordRegex = SyntaxRegexCache.pythonKeywords {
            applyRegex(keywordRegex, to: attributedString, color: .systemPink)
        }
        highlightStrings(attributedString, color: .systemRed)
        highlightComments(attributedString, color: .systemGreen, useHashComment: true)
        highlightNumbers(attributedString, color: .systemBlue)
    }

    private func highlightJavaScript(_ attributedString: NSMutableAttributedString) {
        if let keywordRegex = SyntaxRegexCache.jsKeywords {
            applyRegex(keywordRegex, to: attributedString, color: .systemPink)
        }
        highlightStrings(attributedString, color: .systemRed)
        highlightComments(attributedString, color: .systemGreen)
        highlightNumbers(attributedString, color: .systemBlue)
    }

    private func highlightBash(_ attributedString: NSMutableAttributedString) {
        if let keywordRegex = SyntaxRegexCache.bashKeywords {
            applyRegex(keywordRegex, to: attributedString, color: .systemPink)
        }
        highlightStrings(attributedString, color: .systemRed)
        highlightComments(attributedString, color: .systemGreen, useHashComment: true)
        if let varRegex = SyntaxRegexCache.bashVariable {
            applyRegex(varRegex, to: attributedString, color: .systemCyan)
        }
    }

    private func highlightJSON(_ attributedString: NSMutableAttributedString) {
        if let keyRegex = SyntaxRegexCache.jsonKeyPattern {
            applyRegex(keyRegex, to: attributedString, color: .systemBlue)
        }
        highlightStrings(attributedString, color: .systemRed)
        if let literalRegex = SyntaxRegexCache.jsonLiterals {
            applyRegex(literalRegex, to: attributedString, color: .systemPink)
        }
        highlightNumbers(attributedString, color: .systemOrange)
    }

    private func highlightHTML(_ attributedString: NSMutableAttributedString) {
        if let tagRegex = SyntaxRegexCache.htmlTags {
            applyRegex(tagRegex, to: attributedString, color: .systemPink)
        }
        highlightStrings(attributedString, color: .systemRed)
        if let commentRegex = SyntaxRegexCache.htmlComment {
            applyRegex(commentRegex, to: attributedString, color: .systemGreen)
        }
    }

    private func highlightCSS(_ attributedString: NSMutableAttributedString) {
        if let selectorRegex = SyntaxRegexCache.cssSelector {
            applyRegex(selectorRegex, to: attributedString, color: .systemBlue)
        }
        if let propertyRegex = SyntaxRegexCache.cssProperty {
            applyRegex(propertyRegex, to: attributedString, color: .systemCyan)
        }
        highlightStrings(attributedString, color: .systemRed)
        if let commentRegex = SyntaxRegexCache.multiLineComment {
            applyRegex(commentRegex, to: attributedString, color: .systemGreen)
        }
        highlightNumbers(attributedString, color: .systemOrange)
    }

    private func highlightRust(_ attributedString: NSMutableAttributedString) {
        if let keywordRegex = SyntaxRegexCache.rustKeywords {
            applyRegex(keywordRegex, to: attributedString, color: .systemPink)
        }
        highlightStrings(attributedString, color: .systemRed)
        highlightComments(attributedString, color: .systemGreen)
        highlightNumbers(attributedString, color: .systemBlue)
    }

    private func highlightGo(_ attributedString: NSMutableAttributedString) {
        if let keywordRegex = SyntaxRegexCache.goKeywords {
            applyRegex(keywordRegex, to: attributedString, color: .systemPink)
        }
        highlightStrings(attributedString, color: .systemRed)
        highlightComments(attributedString, color: .systemGreen)
        highlightNumbers(attributedString, color: .systemBlue)
    }

    private func highlightJava(_ attributedString: NSMutableAttributedString) {
        if let keywordRegex = SyntaxRegexCache.javaKeywords {
            applyRegex(keywordRegex, to: attributedString, color: .systemPink)
        }
        highlightStrings(attributedString, color: .systemRed)
        highlightComments(attributedString, color: .systemGreen)
        highlightNumbers(attributedString, color: .systemBlue)
    }

    private func highlightC(_ attributedString: NSMutableAttributedString) {
        if let keywordRegex = SyntaxRegexCache.cKeywords {
            applyRegex(keywordRegex, to: attributedString, color: .systemPink)
        }
        highlightStrings(attributedString, color: .systemRed)
        highlightComments(attributedString, color: .systemGreen)
        highlightNumbers(attributedString, color: .systemBlue)
    }

    private func highlightRuby(_ attributedString: NSMutableAttributedString) {
        if let keywordRegex = SyntaxRegexCache.rubyKeywords {
            applyRegex(keywordRegex, to: attributedString, color: .systemPink)
        }
        highlightStrings(attributedString, color: .systemRed)
        highlightComments(attributedString, color: .systemGreen, useHashComment: true)
        highlightNumbers(attributedString, color: .systemBlue)
    }

    private func highlightPHP(_ attributedString: NSMutableAttributedString) {
        if let keywordRegex = SyntaxRegexCache.phpKeywords {
            applyRegex(keywordRegex, to: attributedString, color: .systemPink)
        }
        highlightStrings(attributedString, color: .systemRed)
        highlightComments(attributedString, color: .systemGreen)
        if let varRegex = SyntaxRegexCache.phpVariable {
            applyRegex(varRegex, to: attributedString, color: .systemCyan)
        }
        highlightNumbers(attributedString, color: .systemBlue)
    }

    private func highlightGeneric(_ attributedString: NSMutableAttributedString) {
        highlightStrings(attributedString, color: .systemRed)
        highlightComments(attributedString, color: .systemGreen)
        highlightNumbers(attributedString, color: .systemBlue)
    }

    // MARK: - Optimized Helper Methods

    /// Apply a pre-compiled regex to the attributed string
    private func applyRegex(_ regex: NSRegularExpression, to attributedString: NSMutableAttributedString, color: NSColor) {
        let range = NSRange(location: 0, length: attributedString.length)
        let matches = regex.matches(in: attributedString.string, options: [], range: range)
        for match in matches {
            attributedString.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }

    private func highlightStrings(_ attributedString: NSMutableAttributedString, color: NSColor) {
        // Double quotes
        if let regex = SyntaxRegexCache.doubleQuoteString {
            applyRegex(regex, to: attributedString, color: color)
        }
        // Single quotes
        if let regex = SyntaxRegexCache.singleQuoteString {
            applyRegex(regex, to: attributedString, color: color)
        }
        // Backticks (template literals)
        if let regex = SyntaxRegexCache.backtickString {
            applyRegex(regex, to: attributedString, color: color)
        }
    }

    private func highlightComments(_ attributedString: NSMutableAttributedString, color: NSColor, useHashComment: Bool = false) {
        if useHashComment {
            if let regex = SyntaxRegexCache.hashComment {
                applyRegex(regex, to: attributedString, color: color)
            }
        } else {
            if let regex = SyntaxRegexCache.singleLineComment {
                applyRegex(regex, to: attributedString, color: color)
            }
        }
        // Multi-line comments
        if let regex = SyntaxRegexCache.multiLineComment {
            applyRegex(regex, to: attributedString, color: color)
        }
    }

    private func highlightNumbers(_ attributedString: NSMutableAttributedString, color: NSColor) {
        if let regex = SyntaxRegexCache.numbers {
            applyRegex(regex, to: attributedString, color: color)
        }
    }
}

// Compact thinking indicator dots for inline use
struct ThinkingIndicatorDots: View {
    @State private var animatingDot = 0

    let timer = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0 ..< 3, id: \.self) { index in
                Circle()
                    .fill(Theme.userBubbleText.opacity(index == animatingDot ? 1.0 : 0.4))
                    .frame(width: 4, height: 4)
                    .animation(.easeInOut(duration: 0.2), value: animatingDot)
            }
        }
        .onReceive(timer) { _ in
            animatingDot = (animatingDot + 1) % 3
        }
    }
}

// Typing indicator for text responses - iMessage style wave animation
struct TypingIndicatorView: View {
    @State private var animatingDot = 0

    let timer = Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: Spacing.xs) {
            ForEach(0 ..< 3, id: \.self) { index in
                Circle()
                    .fill(Theme.textSecondary.opacity(0.6))
                    .frame(width: 8, height: 8)
                    // Wave animation: Y offset for iMessage feel
                    .offset(y: offsetForDot(at: index))
                    .animation(.easeInOut(duration: 0.3), value: animatingDot)
            }
        }
        .padding(.vertical, Spacing.sm)
        .onReceive(timer) { _ in
            animatingDot = (animatingDot + 1) % 6
        }
    }

    /// Calculate Y offset for wave effect
    private func offsetForDot(at index: Int) -> CGFloat {
        let activeIndex: Int = switch animatingDot {
        case 0, 5:
            0
        case 1, 4:
            1
        case 2, 3:
            2
        default:
            -1
        }
        return index == activeIndex ? -4 : 0
    }
}
