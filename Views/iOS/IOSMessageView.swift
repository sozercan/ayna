//
//  IOSMessageView.swift
//  ayna
//
//  Created on 11/22/25.
//

import Combine
import os.log
import Photos
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Design System Integration

// Uses Theme, Typography, Spacing, and Motion from Core/Design/

struct IOSMessageView: View {
    let message: Message
    var onRetry: (() -> Void)?
    var onSwitchModel: ((String) -> Void)?
    var onEdit: ((String) -> Void)?
    var availableModels: [String] = []

    @State private var contentBlocks: [ContentBlock]
    @State private var lastContentHash: Int
    @State private var decodedImage: UIImage?
    @State private var parseDebounceTask: Task<Void, Never>?
    @State private var lastParseTime: Date = .distantPast
    @State private var hasAppeared = false
    @State private var isEditing = false
    @State private var editText = ""

    init(
        message: Message,
        onRetry: (() -> Void)? = nil,
        onSwitchModel: ((String) -> Void)? = nil,
        onEdit: ((String) -> Void)? = nil,
        availableModels: [String] = []
    ) {
        self.message = message
        self.onRetry = onRetry
        self.onSwitchModel = onSwitchModel
        self.onEdit = onEdit
        self.availableModels = availableModels
        // Parse content synchronously on init to avoid flash of empty/raw text bubbles
        _contentBlocks = State(initialValue: MarkdownRenderer.parse(message.content))
        _lastContentHash = State(initialValue: message.content.hashValue)
        // Pre-set hasAppeared to true for messages that are likely already in view
        // This prevents janky animations when scrolling through existing messages
        _hasAppeared = State(initialValue: !message.content.isEmpty)
    }

    @State private var isToolExpanded = false

    var body: some View {
        if message.role == .tool {
            toolMessageView
        } else {
            regularMessageView
        }
    }

    // MARK: - Tool Message View

    private var toolMessageView: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                // Tool name label
                Text(toolDisplayName)
                    .font(Typography.captionBold)
                    .foregroundStyle(Theme.textSecondary)

                // Tool result content with collapse/expand
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    // Header with expand/collapse button
                    Button {
                        withAnimation(Motion.easeStandard) {
                            isToolExpanded.toggle()
                        }
                    } label: {
                        HStack {
                            // Preview text when collapsed
                            if !isToolExpanded {
                                Text(toolPreviewText)
                                    .font(Typography.bodySecondary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer()
                            Image(systemName: isToolExpanded ? "chevron.up" : "chevron.down")
                                .font(Typography.captionBold)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isToolExpanded ? "Collapse tool result" : "Expand tool result")
                    .accessibilityIdentifier("message.tool.expandButton")

                    // Expanded content
                    if isToolExpanded {
                        Divider()
                            .background(Theme.separator)

                        if contentBlocks.isEmpty {
                            Text(message.content)
                                .font(Typography.bodySecondary)
                        } else {
                            ForEach(contentBlocks) { block in
                                IOSContentBlockView(block: block)
                            }
                        }
                    }
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.md - 2)
                .background(Theme.toolBubble)
                .foregroundStyle(Theme.userBubbleText)
                .clipShape(.rect(cornerRadius: Spacing.CornerRadius.xxl))
            }
            .frame(maxWidth: Spacing.Component.bubbleMaxWidth + 20, alignment: .leading)

            Spacer()
        }
        .onChange(of: message.content) { _, newContent in
            updateContentBlocks(newContent)
        }
    }

    private var toolDisplayName: String {
        message.toolCalls?.first?.toolName ?? "web_search"
    }

    private var toolPreviewText: String {
        let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        // Extract summary if present, otherwise show first part
        if let summaryRange = content.range(of: "**Summary:**") {
            let afterSummary = content[summaryRange.upperBound...]
            if let endRange = afterSummary.range(of: "\n\n") {
                return String(afterSummary[..<endRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            return String(afterSummary.prefix(150)).trimmingCharacters(in: .whitespaces)
        }
        return String(content.prefix(100)) + (content.count > 100 ? "..." : "")
    }

    // MARK: - Regular Message View

    /// Whether this message should be hidden (empty assistant message waiting for tool execution)
    private var shouldHideMessage: Bool {
        // Hide empty assistant messages that have pending tool calls
        // This prevents showing an empty bubble artifact while waiting for tool execution
        message.role == .assistant &&
            message.content.isEmpty &&
            message.mediaType != .image &&
            message.toolCalls != nil &&
            !(message.toolCalls?.isEmpty ?? true)
    }

    @ViewBuilder
    private var regularMessageView: some View {
        if shouldHideMessage {
            // Don't render anything for empty assistant messages with pending tool calls
            EmptyView()
        } else {
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: Spacing.xxs) {
                regularMessageContent

                // Edited indicator
                if message.isEdited {
                    Text("edited")
                        .font(Typography.micro)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, Spacing.xs)
                }
            }
            .sheet(isPresented: $isEditing) {
                IOSMessageEditSheet(
                    originalContent: message.content,
                    editText: $editText,
                    onSave: { newContent in
                        onEdit?(newContent)
                        isEditing = false
                    },
                    onCancel: {
                        isEditing = false
                        editText = ""
                    }
                )
            }
        }
    }

    private var regularMessageContent: some View {
        HStack(alignment: .top) {
            if message.role == .user {
                Spacer()
            }

            VStack(alignment: .leading, spacing: Spacing.sm) {
                if let attachments = message.attachments, !attachments.isEmpty {
                    ForEach(attachments, id: \.fileName) { attachment in
                        HStack {
                            Image(systemName: "doc.fill")
                                .foregroundStyle(Theme.textSecondary)
                            Text(attachment.fileName)
                                .font(Typography.caption)
                                .lineLimit(1)
                        }
                        .padding(Spacing.xs)
                        .background(Color.black.opacity(0.1))
                        .clipShape(.rect(cornerRadius: Spacing.CornerRadius.sm))
                    }
                }

                if message.mediaType == .image {
                    if let decodedImage {
                        Image(uiImage: decodedImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: Spacing.Component.bubbleMaxWidth - 20)
                            .clipShape(.rect(cornerRadius: Spacing.CornerRadius.md))
                    } else {
                        ProgressView()
                            .frame(maxWidth: Spacing.Component.bubbleMaxWidth - 20)
                            .task {
                                // Load image from either imageData or imagePath
                                if let imageData = message.effectiveImageData {
                                    decodedImage = await Task.detached(priority: .userInitiated) {
                                        UIImage(data: imageData)
                                    }.value
                                }
                            }
                    }
                }

                // Show typing indicator for empty assistant messages (waiting for response)
                // Don't show if the message has tool calls (it's waiting for tool execution)
                if message.role == .assistant, message.content.isEmpty, message.mediaType != .image,
                   message.toolCalls == nil || message.toolCalls?.isEmpty == true
                {
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

                // Citation sources footer for web search results
                if let citations = message.citations, !citations.isEmpty {
                    IOSCitationSourcesFooter(citations: citations)
                        .padding(.top, Spacing.xxs)
                }
            }
            .padding(.leading, message.role == .user ? Spacing.md : Spacing.bubblePaddingH)
            .padding(.trailing, message.role == .user ? Spacing.bubblePaddingH : Spacing.md)
            .padding(.vertical, Spacing.md - 2)
            .background(
                MessageBubbleShape(isFromCurrentUser: message.role == .user)
                    .fill(message.role == .user ? Theme.userBubble : Theme.assistantBubble)
            )
            .foregroundStyle(message.role == .user ? Theme.userBubbleText : Theme.assistantBubbleText)
            .frame(maxWidth: Spacing.Component.bubbleMaxWidth, alignment: message.role == .user ? .trailing : .leading)
            // Message bubble physics: subtle spring animation on appear
            .scaleEffect(hasAppeared ? 1.0 : 0.92)
            .opacity(hasAppeared ? 1.0 : 0.0)
            .onAppear {
                withAnimation(Motion.springStandard) {
                    hasAppeared = true
                }
            }
            .contextMenu {
                // Copy button - available for all messages with content
                if !message.content.isEmpty {
                    Button {
                        UIPasteboard.general.string = message.content
                        // Use centralized haptic engine
                        HapticEngine.notification(.success)
                        DiagnosticsLogger.log(
                            .chatView,
                            level: .info,
                            message: "📋 Message copied to clipboard"
                        )
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                }

                // Edit button - only for user messages
                if message.role == .user, let onEdit {
                    Button {
                        HapticEngine.impact(.medium)
                        editText = message.content
                        isEditing = true
                        DiagnosticsLogger.log(
                            .chatView,
                            level: .info,
                            message: "✏️ Edit message requested",
                            metadata: ["messageId": message.id.uuidString]
                        )
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                }

                // Retry button - only for assistant messages
                if message.role == .assistant, let onRetry {
                    Button {
                        // Use centralized haptic engine
                        HapticEngine.impact(.medium)
                        DiagnosticsLogger.log(
                            .chatView,
                            level: .info,
                            message: "🔄 Retry requested via context menu",
                            metadata: ["messageId": message.id.uuidString]
                        )
                        onRetry()
                    } label: {
                        Label("Try Again", systemImage: "arrow.clockwise")
                    }
                }

                // Switch Model submenu - only for assistant messages
                if message.role == .assistant, let onSwitchModel, !availableModels.isEmpty {
                    Menu {
                        ForEach(availableModels, id: \.self) { model in
                            Button {
                                HapticEngine.impact(.medium)
                                DiagnosticsLogger.log(
                                    .chatView,
                                    level: .info,
                                    message: "🔄 Switch model requested via context menu",
                                    metadata: ["messageId": message.id.uuidString, "newModel": model]
                                )
                                onSwitchModel(model)
                            } label: {
                                HStack {
                                    Text(model)
                                    if model == message.model {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        Label("Switch Model", systemImage: "arrow.left.arrow.right")
                    }
                }

                // Copy image if present - use cached decodedImage to prevent memory leaks
                if message.mediaType == .image, let image = decodedImage {
                    Button {
                        UIPasteboard.general.image = image
                        // Use centralized haptic engine
                        HapticEngine.notification(.success)
                        DiagnosticsLogger.log(
                            .chatView,
                            level: .info,
                            message: "🖼️ Image copied to clipboard"
                        )
                    } label: {
                        Label("Copy Image", systemImage: "photo.on.rectangle")
                    }

                    Button {
                        saveImageToPhotos(image)
                    } label: {
                        Label("Save to Photos", systemImage: "square.and.arrow.down")
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

            // Check if enough time has passed since last parse (400ms minimum during streaming)
            let now = Date()
            let timeSinceLastParse = now.timeIntervalSince(lastParseTime)
            let minInterval: TimeInterval = 0.4 // 400ms minimum between parses

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
        .onChange(of: message.imagePath) { _, newPath in
            // Reload image when path changes (e.g., after generation completes)
            if newPath != nil {
                decodedImage = nil
                Task {
                    if let imageData = message.effectiveImageData {
                        decodedImage = await Task.detached(priority: .userInitiated) {
                            UIImage(data: imageData)
                        }.value
                    }
                }
            }
        }
        .onChange(of: message.imageData) { _, newData in
            // Reload image when data changes
            if newData != nil {
                decodedImage = nil
                Task {
                    if let imageData = message.effectiveImageData {
                        decodedImage = await Task.detached(priority: .userInitiated) {
                            UIImage(data: imageData)
                        }.value
                    }
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

    private func updateContentBlocks(_ content: String) {
        let newHash = content.hashValue
        guard newHash != lastContentHash else { return }
        lastContentHash = newHash
        performParse(content: content)
    }

    private func saveImageToPhotos(_ image: UIImage) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            Task { @MainActor in
                switch status {
                case .authorized, .limited:
                    PHPhotoLibrary.shared().performChanges {
                        PHAssetChangeRequest.creationRequestForAsset(from: image)
                    } completionHandler: { success, error in
                        Task { @MainActor in
                            if success {
                                HapticEngine.notification(.success)
                                DiagnosticsLogger.log(
                                    .chatView,
                                    level: .info,
                                    message: "📷 Image saved to Photos"
                                )
                            } else {
                                HapticEngine.notification(.error)
                                DiagnosticsLogger.log(
                                    .chatView,
                                    level: .error,
                                    message: "❌ Failed to save image: \(error?.localizedDescription ?? "Unknown error")"
                                )
                            }
                        }
                    }
                case .denied, .restricted:
                    HapticEngine.notification(.error)
                    DiagnosticsLogger.log(
                        .chatView,
                        level: .info,
                        message: "⚠️ Photo library access denied"
                    )
                case .notDetermined:
                    break
                @unknown default:
                    break
                }
            }
        }
    }
}

private struct MessageBubbleShape: Shape {
    var isFromCurrentUser: Bool

    func path(in rect: CGRect) -> Path {
        Path { path in
            let tailWidth: CGFloat = Spacing.xs
            let radius: CGFloat = Spacing.CornerRadius.bubble

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
            Text(text).font(level == 1 ? Typography.title2 : level == 2 ? Typography.title3 : Typography.headline)
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
                Rectangle().fill(Theme.textSecondary).frame(width: Spacing.xxs)
                Text(text).foregroundStyle(Theme.textSecondary)
            }
        case let .code(code, _):
            ScrollView(.horizontal) {
                Text(code)
                    .font(Typography.codeBlock)
                    .padding()
                    .background(Theme.codeBackground)
                    .clipShape(.rect(cornerRadius: Spacing.CornerRadius.md))
            }
        case .divider:
            Divider()
        case .table:
            Text("[Table]") // Simplified for now
        case let .tool(name, result):
            VStack(alignment: .leading) {
                Text("Tool: \(name)").font(Typography.captionBold)
                Text(result).font(Typography.caption).foregroundStyle(Theme.textSecondary)
            }
            .padding(Spacing.sm)
            .background(Theme.toolBubble.opacity(0.1))
            .clipShape(.rect(cornerRadius: Spacing.CornerRadius.md))
        }
    }
}

/// Typing indicator for text responses (iOS version) - iMessage style wave
/// Uses phaseAnimator for efficient animation without Timer overhead
struct IOSTypingIndicatorView: View {
    var body: some View {
        HStack(spacing: Spacing.xs) {
            ForEach(0 ..< 3, id: \.self) { index in
                TypingDot(index: index)
            }
        }
        .padding(.vertical, Spacing.xxs)
    }
}

/// Individual dot with staggered phase animation for wave effect
private struct TypingDot: View {
    let index: Int

    @State private var isAnimating = false

    var body: some View {
        Circle()
            .fill(Theme.textSecondary.opacity(0.6))
            .frame(width: 8, height: 8)
            .offset(y: isAnimating ? -4 : 0)
            .animation(
                .easeInOut(duration: 0.4)
                    .repeatForever(autoreverses: true)
                    .delay(Double(index) * 0.15),
                value: isAnimating
            )
            .onAppear {
                isAnimating = true
            }
    }
}

/// Sheet view for editing a message on iOS
struct IOSMessageEditSheet: View {
    let originalContent: String
    @Binding var editText: String
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: Spacing.md) {
                TextEditor(text: $editText)
                    .font(Typography.body)
                    .focused($isFocused)
                    .padding(Spacing.sm)
                    .background(Theme.backgroundSecondary)
                    .clipShape(.rect(cornerRadius: Spacing.CornerRadius.md))
                    .overlay(
                        RoundedRectangle(cornerRadius: Spacing.CornerRadius.md)
                            .stroke(Theme.border, lineWidth: 1)
                    )
                    .padding(.horizontal)

                Spacer()
            }
            .padding(.top, Spacing.md)
            .navigationTitle("Edit Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmedText = editText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmedText.isEmpty {
                            onSave(trimmedText)
                        }
                    }
                    .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .onAppear {
            if editText.isEmpty {
                editText = originalContent
            }
            isFocused = true
        }
        .presentationDetents([.medium, .large])
    }
}
