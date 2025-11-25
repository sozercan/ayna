//
//  MacMessageView.swift
//  ayna
//
//  Created on 11/2/25.
//

import SwiftUI

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

    private let userBubbleGradient = LinearGradient(
        colors: [
            Color(red: 0.09, green: 0.45, blue: 1.0),
            Color(red: 0.01, green: 0.35, blue: 0.95)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    private let recipientBubbleGradient = LinearGradient(
        colors: [
            Color(red: 0.35, green: 0.36, blue: 0.38),
            Color(red: 0.23, green: 0.24, blue: 0.26)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    private let toolBubbleColor = Color.orange

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
            VStack(alignment: .leading, spacing: 12) {
                Button(action: {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                        isExpanded.toggle()
                    }
                }) {
                    HStack(spacing: 10) {
                        Spacer()

                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())

                if !isExpanded {
                    Text(previewText)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    if let arguments, !arguments.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Arguments")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                            ScrollView(.horizontal, showsIndicators: false) {
                                Text(arguments)
                                    .font(.system(size: 12, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(8)
                            .background(Color.orange.opacity(0.08))
                            .cornerRadius(8)
                        }
                    }

                    Divider()

                    if contentBlocks.isEmpty {
                        Text(previewText)
                            .font(.system(size: 13))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(contentBlocks, id: \.id) { block in
                                block.view
                            }
                        }
                    }
                }
            }
            .padding(14)
        }
    }

    @MainActor var body: some View {
        messageContent
            .padding(.horizontal, 24)
            .padding(.vertical, 6)
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
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .bottom, spacing: 8) {
                if isCurrentUser {
                    Spacer(minLength: 60)
                }

                bubbleContainer(isCurrentUser: isCurrentUser)

                if !isCurrentUser {
                    Spacer(minLength: 60)
                }
            }

            Text(timestampText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(isCurrentUser ? .trailing : .leading, 6)
        }
    }

    @MainActor
    private func bubbleContainer(isCurrentUser: Bool) -> some View {
        let bubbleStyle = isCurrentUser ? userBubbleGradient : recipientBubbleGradient

        return ZStack(alignment: isCurrentUser ? .topLeading : .topTrailing) {
            VStack(alignment: .leading, spacing: 12) {
                bubbleContent
            }
            .frame(maxWidth: 480, alignment: .leading)
            .foregroundColor(.white)
            .padding(.leading, isCurrentUser ? 18 : 24)
            .padding(.trailing, isCurrentUser ? 24 : 18)
            .padding(.vertical, 12)
            .background(
                MessageBubbleShape(isFromCurrentUser: isCurrentUser)
                    .fill(bubbleStyle)
            )
            .overlay(
                MessageBubbleShape(isFromCurrentUser: isCurrentUser)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.18), radius: 8, x: 0, y: 4)
            .environment(\.colorScheme, .dark)
            .tint(.white)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(verbatim: accessibilityText))
            .accessibilityIdentifier("chat.message.\(message.id.uuidString)")

            actionControls(for: message.role)
                .offset(y: -26)
        }
        .animation(.easeInOut(duration: 0.2), value: isHovered)
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

        if message.role == .assistant, message.content.isEmpty, message.mediaType != .image {
            TypingIndicatorView()
        }

        if let reasoning = message.reasoning, !reasoning.isEmpty {
            Button(action: {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    showReasoning.toggle()
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: showReasoning ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .medium))
                    Text("Thinking")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 0)
                    Text("\(reasoning.count) chars")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .foregroundStyle(.white)
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .background(Color.white.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)

            if showReasoning {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(cachedReasoningBlocks, id: \.id) { block in
                        block.view
                    }
                }
                .padding(14)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
        }

        ForEach(cachedContentBlocks, id: \.id) { block in
            block.view
        }
    }

    @MainActor @ViewBuilder
    private func actionControls(for role: Message.Role) -> some View {
        if isHovered || UITestEnvironment.isEnabled {
            HStack(spacing: 6) {
                Button(action: {
                    copyToClipboard(message.content)
                }) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12, weight: .medium))
                        .padding(6)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("message.action.copy")

                if role == .assistant {
                    Menu {
                        Section {
                            Text("Used \(modelName ?? message.model ?? "Unknown Model")")
                                .font(.system(size: 12))
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
                            .font(.system(size: 12, weight: .medium))
                            .padding(6)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .shadow(color: Color.black.opacity(0.25), radius: 6, x: 0, y: 3)
            .transition(.opacity.combined(with: .scale))
        }
    }

    @MainActor
    private var toolMessageView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(toolDisplayName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

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
                    .frame(maxWidth: 480, alignment: .leading)
                    .foregroundColor(.white)
                    .padding(.leading, 24)
                    .padding(.trailing, 18)
                    .padding(.vertical, 12)
                    .background(
                        MessageBubbleShape(isFromCurrentUser: false)
                            .fill(toolBubbleColor)
                    )
                    .overlay(
                        MessageBubbleShape(isFromCurrentUser: false)
                            .stroke(Color.white.opacity(0.15), lineWidth: 1)
                    )
                    .shadow(color: Color.orange.opacity(0.3), radius: 10, x: 0, y: 4)
                    .environment(\.colorScheme, .dark)
                    .accessibilityIdentifier("chat.message.\(message.id.uuidString)")

                    actionControls(for: message.role)
                        .offset(y: -26)
                }

                Spacer(minLength: 40)
            }

            Text(timestampText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
        }
    }

    private var timestampText: String {
        Self.timestampFormatter.string(from: message.timestamp)
    }

    private func updateCachedBlocks() {
        let content = message.content
        let newHash = content.hashValue
        if newHash != lastContentHash {
            lastContentHash = newHash
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
            let tailWidth: CGFloat = 6
            let radius: CGFloat = 18

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
                .font(.system(size: 15))
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

        case let .heading(level, text):
            let font: Font = switch level {
            case 1:
                .system(size: 22, weight: .bold)
            case 2:
                .system(size: 20, weight: .semibold)
            case 3:
                .system(size: 18, weight: .semibold)
            default:
                .system(size: 16, weight: .semibold)
            }
            Text(text)
                .font(font)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, level == 1 ? 4 : 2)

        case let .unorderedList(items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                            .font(.system(size: 16, weight: .semibold))
                            .accessibilityHidden(true)
                        Text(item)
                            .font(.system(size: 15))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, 2)
                    .accessibilityLabel("Bullet item \(index + 1)")
                }
            }

        case let .orderedList(start, items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: "\(start + offset).")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 32, alignment: .trailing)
                            .accessibilityHidden(true)
                        Text(item)
                            .font(.system(size: 15))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case let .blockquote(text):
            HStack(alignment: .top, spacing: 12) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 3)
                    .cornerRadius(3)

                Text(text)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(Color.secondary.opacity(0.08))
            .cornerRadius(10)

        case let .table(table):
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(spacing: 0) {
                    tableRowView(table.headers, alignments: table.alignments, isHeader: true)
                        .background(Color.secondary.opacity(0.12))
                    Divider()
                    ForEach(Array(table.rows.enumerated()), id: \.offset) { rowIndex, row in
                        tableRowView(row, alignments: table.alignments, isHeader: false)
                        if rowIndex < table.rows.count - 1 {
                            Divider()
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .background(Color.secondary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 8))

        case .divider:
            Divider()
                .overlay(Color.secondary.opacity(0.2))

        case let .code(code, language):
            VStack(alignment: .leading, spacing: 0) {
                // Header with language and copy button
                HStack {
                    if !language.isEmpty {
                        Text(language.lowercased())
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.lowercase)
                    }

                    Spacer()

                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.on.doc")
                            Text("Copy code")
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))

                Divider()

                // Code content with syntax highlighting
                ScrollView(.horizontal, showsIndicators: false) {
                    SyntaxHighlightedCodeView(code: code, language: language)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))

        case let .tool(name, result):
            VStack(alignment: .leading, spacing: 0) {
                // Tool header
                HStack(spacing: 8) {
                    Image(systemName: "wrench.and.screwdriver.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(
                            LinearGradient(
                                colors: [Color.blue, Color.blue.opacity(0.8)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tool")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        Text(name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                    }

                    Spacer()

                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.green)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.blue.opacity(0.08))

                Divider()

                // Tool result
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(result)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
            }
            .background(Color.blue.opacity(0.03))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.blue.opacity(0.2), lineWidth: 1.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(color: Color.blue.opacity(0.1), radius: 4, x: 0, y: 2)
        }
    }

    @ViewBuilder
    private func tableRowView(
        _ cells: [AttributedString],
        alignments: [MarkdownTable.ColumnAlignment],
        isHeader: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                let columnAlignment = alignments.indices.contains(index) ? alignments[index] : .leading
                Text(cell)
                    .font(.system(size: 13, weight: isHeader ? .semibold : .regular))
                    .textSelection(.enabled)
                    .frame(minWidth: 80, alignment: horizontalAlignment(for: columnAlignment))
            }
        }
        .padding(.vertical, isHeader ? 10 : 8)
        .padding(.horizontal, 12)
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
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.secondary.opacity(0.08))
                .strokeBorder(Color.secondary.opacity(0.1), lineWidth: 1)

            VStack(spacing: 16) {
                // Animated Icon
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.1))
                        .frame(width: 64, height: 64)
                        .scaleEffect(1 + sin(phase) * 0.1)

                    if #available(macOS 15.0, *) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 30))
                            .foregroundStyle(Color.accentColor)
                            .symbolEffect(.bounce, options: .repeating)
                    } else {
                        Image(systemName: "sparkles")
                            .font(.system(size: 30))
                            .foregroundStyle(Color.accentColor)
                            .symbolEffect(.variableColor)
                    }
                }

                Text("Dreaming up your image...")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
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

// Syntax highlighted code view
struct SyntaxHighlightedCodeView: View {
    let code: String
    let language: String

    var body: some View {
        Text(AttributedString(highlightedCode()))
            .font(.system(size: 13, design: .monospaced))
            .textSelection(.enabled)
    }

    private func highlightedCode() -> NSAttributedString {
        let attributedString = NSMutableAttributedString(string: code)
        let fullRange = NSRange(location: 0, length: code.utf16.count)

        // Base styling
        let baseFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
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
        let keywords = ["func", "var", "let", "if", "else", "for", "while", "return", "import", "class", "struct", "enum", "protocol", "extension", "public", "private", "internal", "static", "override", "init", "self", "super", "nil", "true", "false", "guard", "switch", "case", "default", "break", "continue", "in", "where", "as", "is", "try", "catch", "throw", "throws", "async", "await", "actor"]
        highlightKeywords(attributedString, keywords: keywords, color: .systemPink)
        highlightStrings(attributedString, color: .systemRed)
        highlightComments(attributedString, color: .systemGreen)
        highlightNumbers(attributedString, color: .systemBlue)
    }

    private func highlightPython(_ attributedString: NSMutableAttributedString) {
        let keywords = ["def", "class", "if", "elif", "else", "for", "while", "return", "import", "from", "as", "try", "except", "finally", "with", "lambda", "yield", "async", "await", "pass", "break", "continue", "and", "or", "not", "in", "is", "None", "True", "False", "self"]
        highlightKeywords(attributedString, keywords: keywords, color: .systemPink)
        highlightStrings(attributedString, color: .systemRed)
        highlightComments(attributedString, color: .systemGreen, pattern: "#.*")
        highlightNumbers(attributedString, color: .systemBlue)
    }

    private func highlightJavaScript(_ attributedString: NSMutableAttributedString) {
        let keywords = ["function", "const", "let", "var", "if", "else", "for", "while", "return", "import", "export", "class", "extends", "constructor", "this", "super", "async", "await", "try", "catch", "throw", "new", "typeof", "instanceof", "null", "undefined", "true", "false", "switch", "case", "default", "break", "continue"]
        highlightKeywords(attributedString, keywords: keywords, color: .systemPink)
        highlightStrings(attributedString, color: .systemRed)
        highlightComments(attributedString, color: .systemGreen)
        highlightNumbers(attributedString, color: .systemBlue)
    }

    private func highlightBash(_ attributedString: NSMutableAttributedString) {
        let keywords = ["if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac", "function", "return", "echo", "exit", "export", "source", "cd", "ls", "cp", "mv", "rm", "mkdir", "chmod", "sudo", "apt", "brew", "npm", "pip", "git"]
        highlightKeywords(attributedString, keywords: keywords, color: .systemPink)
        highlightStrings(attributedString, color: .systemRed)
        highlightComments(attributedString, color: .systemGreen, pattern: "#.*")
        highlightPattern(attributedString, pattern: "\\$[a-zA-Z_][a-zA-Z0-9_]*", color: .systemCyan) // Variables
    }

    private func highlightJSON(_ attributedString: NSMutableAttributedString) {
        highlightPattern(attributedString, pattern: "\"[^\"]*\"\\s*:", color: .systemBlue) // Keys
        highlightStrings(attributedString, color: .systemRed)
        highlightPattern(attributedString, pattern: "\\b(true|false|null)\\b", color: .systemPink)
        highlightNumbers(attributedString, color: .systemOrange)
    }

    private func highlightHTML(_ attributedString: NSMutableAttributedString) {
        highlightPattern(attributedString, pattern: "<[^>]+>", color: .systemPink) // Tags
        highlightStrings(attributedString, color: .systemRed)
        highlightComments(attributedString, color: .systemGreen, pattern: "<!--.*?-->")
    }

    private func highlightCSS(_ attributedString: NSMutableAttributedString) {
        highlightPattern(attributedString, pattern: "[.#][a-zA-Z][a-zA-Z0-9_-]*", color: .systemBlue) // Selectors
        highlightPattern(attributedString, pattern: "[a-zA-Z-]+(?=\\s*:)", color: .systemCyan) // Properties
        highlightStrings(attributedString, color: .systemRed)
        highlightComments(attributedString, color: .systemGreen, pattern: "/\\*.*?\\*/")
        highlightNumbers(attributedString, color: .systemOrange)
    }

    private func highlightRust(_ attributedString: NSMutableAttributedString) {
        let keywords = ["fn", "let", "mut", "if", "else", "for", "while", "loop", "return", "use", "mod", "pub", "struct", "enum", "impl", "trait", "type", "where", "match", "self", "Self", "true", "false", "const", "static", "async", "await", "move"]
        highlightKeywords(attributedString, keywords: keywords, color: .systemPink)
        highlightStrings(attributedString, color: .systemRed)
        highlightComments(attributedString, color: .systemGreen)
        highlightNumbers(attributedString, color: .systemBlue)
    }

    private func highlightGo(_ attributedString: NSMutableAttributedString) {
        let keywords = ["func", "var", "const", "if", "else", "for", "range", "return", "import", "package", "type", "struct", "interface", "map", "chan", "go", "defer", "select", "switch", "case", "default", "break", "continue", "nil", "true", "false"]
        highlightKeywords(attributedString, keywords: keywords, color: .systemPink)
        highlightStrings(attributedString, color: .systemRed)
        highlightComments(attributedString, color: .systemGreen)
        highlightNumbers(attributedString, color: .systemBlue)
    }

    private func highlightJava(_ attributedString: NSMutableAttributedString) {
        let keywords = ["public", "private", "protected", "class", "interface", "extends", "implements", "if", "else", "for", "while", "return", "import", "package", "new", "this", "super", "static", "final", "void", "int", "String", "boolean", "true", "false", "null", "try", "catch", "throw", "throws"]
        highlightKeywords(attributedString, keywords: keywords, color: .systemPink)
        highlightStrings(attributedString, color: .systemRed)
        highlightComments(attributedString, color: .systemGreen)
        highlightNumbers(attributedString, color: .systemBlue)
    }

    private func highlightC(_ attributedString: NSMutableAttributedString) {
        let keywords = ["if", "else", "for", "while", "return", "void", "int", "char", "float", "double", "struct", "typedef", "enum", "union", "static", "const", "sizeof", "break", "continue", "switch", "case", "default", "#include", "#define", "NULL"]
        highlightKeywords(attributedString, keywords: keywords, color: .systemPink)
        highlightStrings(attributedString, color: .systemRed)
        highlightComments(attributedString, color: .systemGreen)
        highlightNumbers(attributedString, color: .systemBlue)
    }

    private func highlightRuby(_ attributedString: NSMutableAttributedString) {
        let keywords = ["def", "end", "class", "module", "if", "elsif", "else", "unless", "case", "when", "for", "while", "until", "do", "return", "yield", "self", "super", "nil", "true", "false", "and", "or", "not", "begin", "rescue", "ensure"]
        highlightKeywords(attributedString, keywords: keywords, color: .systemPink)
        highlightStrings(attributedString, color: .systemRed)
        highlightComments(attributedString, color: .systemGreen, pattern: "#.*")
        highlightNumbers(attributedString, color: .systemBlue)
    }

    private func highlightPHP(_ attributedString: NSMutableAttributedString) {
        let keywords = ["function", "class", "if", "else", "elseif", "for", "foreach", "while", "return", "public", "private", "protected", "static", "new", "this", "self", "parent", "try", "catch", "throw", "null", "true", "false", "echo", "print", "require", "include"]
        highlightKeywords(attributedString, keywords: keywords, color: .systemPink)
        highlightStrings(attributedString, color: .systemRed)
        highlightComments(attributedString, color: .systemGreen)
        highlightPattern(attributedString, pattern: "\\$[a-zA-Z_][a-zA-Z0-9_]*", color: .systemCyan) // Variables
        highlightNumbers(attributedString, color: .systemBlue)
    }

    private func highlightGeneric(_ attributedString: NSMutableAttributedString) {
        highlightStrings(attributedString, color: .systemRed)
        highlightComments(attributedString, color: .systemGreen)
        highlightNumbers(attributedString, color: .systemBlue)
    }

    // Helper methods
    private func highlightKeywords(_ attributedString: NSMutableAttributedString, keywords: [String], color: NSColor) {
        for keyword in keywords {
            let pattern = "\\b\(keyword)\\b"
            highlightPattern(attributedString, pattern: pattern, color: color)
        }
    }

    private func highlightStrings(_ attributedString: NSMutableAttributedString, color: NSColor) {
        // Double quotes
        highlightPattern(attributedString, pattern: "\"(?:[^\"\\\\]|\\\\.)*\"", color: color)
        // Single quotes
        highlightPattern(attributedString, pattern: "'(?:[^'\\\\]|\\\\.)*'", color: color)
        // Backticks (template literals)
        highlightPattern(attributedString, pattern: "`(?:[^`\\\\]|\\\\.)*`", color: color)
    }

    private func highlightComments(_ attributedString: NSMutableAttributedString, color: NSColor, pattern: String = "//.*") {
        highlightPattern(attributedString, pattern: pattern, color: color)
        // Multi-line comments
        highlightPattern(attributedString, pattern: "/\\*[\\s\\S]*?\\*/", color: color)
    }

    private func highlightNumbers(_ attributedString: NSMutableAttributedString, color: NSColor) {
        highlightPattern(attributedString, pattern: "\\b\\d+\\.?\\d*\\b", color: color)
    }

    private func highlightPattern(_ attributedString: NSMutableAttributedString, pattern: String, color: NSColor) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return }
        let range = NSRange(location: 0, length: attributedString.length)
        let matches = regex.matches(in: attributedString.string, options: [], range: range)

        for match in matches {
            attributedString.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }
}

// Typing indicator for text responses
struct TypingIndicatorView: View {
    @State private var animatingDot = 0

    let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0 ..< 3) { index in
                Circle()
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 8, height: 8)
                    .scaleEffect(animatingDot == index ? 1.2 : 0.8)
                    .animation(.easeInOut(duration: 0.4), value: animatingDot)
            }
        }
        .padding(.vertical, 8)
        .onReceive(timer) { _ in
            animatingDot = (animatingDot + 1) % 3
        }
    }
}
