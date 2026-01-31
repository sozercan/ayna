//
//  MultiModelResponseView.swift
//  ayna
//
//  Created on 11/25/25.
//

import SwiftUI

/// A view that displays parallel responses from multiple AI models in a grid layout.
/// Users can compare responses and select one to continue the conversation.
@MainActor
struct MultiModelResponseView: View {
    let responseGroupId: UUID
    let responses: [Message]
    let conversation: Conversation
    var onSelectResponse: ((UUID) -> Void)?
    var onRetry: ((Message) -> Void)?

    @EnvironmentObject var conversationManager: ConversationManager

    private var responseGroup: ResponseGroup? {
        conversation.getResponseGroup(responseGroupId)
    }

    private var selectedResponseId: UUID? {
        responseGroup?.selectedResponseId
    }

    private var isSelectionMade: Bool {
        selectedResponseId != nil
    }

    private var defaultCandidateId: UUID? {
        // 1. Primary: conversation.model
        if let match = responses.first(where: { $0.model == conversation.model }) {
            return match.id
        }
        // 2. Fallback: First model
        return responses.first?.id
    }

    /// Determines the grid layout based on number of responses
    private var columns: [GridItem] {
        let count = responses.count
        switch count {
        case 1:
            return [GridItem(.flexible())]
        case 2:
            return [GridItem(.flexible()), GridItem(.flexible())]
        case 3:
            return [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
        default:
            // 4+ models: 2x2 grid
            return [GridItem(.flexible()), GridItem(.flexible())]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            // Header
            HStack {
                Image(systemName: "square.stack.3d.up")
                    .foregroundStyle(Theme.textSecondary)
                Text("Multi-Model Responses")
                    .font(Typography.captionBold)
                    .foregroundStyle(Theme.textSecondary)

                Spacer()

                if !isSelectionMade {
                    Text("Select a response to continue")
                        .font(Typography.caption)
                        .foregroundStyle(Theme.statusConnecting)
                } else {
                    HStack(spacing: Spacing.xxs) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Theme.statusConnected)
                        Text("Response selected")
                            .font(Typography.caption)
                            .foregroundStyle(Theme.statusConnected)
                    }
                }
            }
            .padding(.horizontal, Spacing.contentPadding)

            // Response Grid
            LazyVGrid(columns: columns, spacing: Spacing.lg) {
                ForEach(responses) { response in
                    MultiModelResponseCard(
                        message: response,
                        isSelected: response.id == selectedResponseId,
                        isSelectionMade: isSelectionMade,
                        isDefaultCandidate: !isSelectionMade && response.id == defaultCandidateId,
                        responseStatus: responseGroup?.responses.first { $0.id == response.id }?.status,
                        onSelect: {
                            onSelectResponse?(response.id)
                        },
                        onRetry: {
                            onRetry?(response)
                        }
                    )
                }
            }
            .padding(.horizontal, Spacing.contentPadding)
        }
        .padding(.vertical, Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: Spacing.CornerRadius.xxl)
                .fill(Theme.textSecondary.opacity(0.05))
                .strokeBorder(Theme.border, lineWidth: Spacing.Border.standard)
        )
        .padding(.horizontal, Spacing.contentPadding)
    }
}

/// Individual response card in the multi-model grid
@MainActor
struct MultiModelResponseCard: View {
    let message: Message
    let isSelected: Bool
    let isSelectionMade: Bool
    let isDefaultCandidate: Bool
    let responseStatus: ResponseGroupStatus?
    var onSelect: (() -> Void)?
    var onRetry: (() -> Void)?

    @State private var isHovered = false
    @State private var cachedContentBlocks: [ContentBlock]

    init(
        message: Message,
        isSelected: Bool,
        isSelectionMade: Bool,
        isDefaultCandidate: Bool = false,
        responseStatus: ResponseGroupStatus?,
        onSelect: (() -> Void)? = nil,
        onRetry: (() -> Void)? = nil
    ) {
        self.message = message
        self.isSelected = isSelected
        self.isSelectionMade = isSelectionMade
        self.isDefaultCandidate = isDefaultCandidate
        self.responseStatus = responseStatus
        self.onSelect = onSelect
        self.onRetry = onRetry
        _cachedContentBlocks = State(initialValue: MarkdownRenderer.parse(message.content))
    }

    private var modelName: String {
        message.model ?? "Unknown Model"
    }

    private var isStreaming: Bool {
        responseStatus == .streaming
    }

    private var hasFailed: Bool {
        responseStatus == .failed
    }

    private var borderColor: Color {
        if isSelected {
            Theme.statusConnected
        } else if isHovered, !isSelectionMade {
            Theme.accent
        } else if isDefaultCandidate {
            Theme.textSecondary.opacity(0.4)
        } else if hasFailed {
            Theme.statusError.opacity(0.5)
        } else {
            Theme.border
        }
    }

    private var cardOpacity: Double {
        if isSelectionMade, !isSelected {
            return 0.5
        }
        return 1.0
    }

    private var headerBackgroundColor: Color {
        isSelected ? Theme.statusConnected.opacity(0.1) : Theme.textSecondary.opacity(0.08)
    }

    private var shadowColor: Color {
        isSelected ? Theme.statusConnected.opacity(0.2) : Theme.shadow
    }

    var body: some View {
        cardContent
            .background(Theme.backgroundSecondary)
            .clipShape(RoundedRectangle(cornerRadius: Spacing.CornerRadius.xl))
            .overlay(cardBorder)
            .opacity(cardOpacity)
            .shadow(color: shadowColor, radius: Spacing.Shadow.radiusStandard, x: 0, y: Spacing.Shadow.offsetY)
            .onHover { hovering in
                isHovered = hovering
            }
            .onChange(of: message.content) { _, newContent in
                Task.detached(priority: .userInitiated) {
                    let blocks = MarkdownRenderer.parse(newContent)
                    await MainActor.run {
                        cachedContentBlocks = blocks
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Response from \(modelName)")
            .accessibilityHint(isSelected ? "Selected" : "Double tap to select")
            .accessibilityIdentifier("multimodel.response.\(message.id.uuidString)")
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerView
            Divider()
            contentScrollView
            pendingToolCallsView
            selectionButtonView
        }
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: Spacing.CornerRadius.xl)
            .strokeBorder(borderColor, lineWidth: isSelected ? Spacing.Border.thick : Spacing.Border.standard)
    }

    private var headerView: some View {
        HStack {
            Text(modelName)
                .font(Typography.captionBold)
                .foregroundStyle(isSelected ? Theme.statusConnected : Theme.textPrimary)

            Spacer()

            headerStatusIcon
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(headerBackgroundColor)
    }

    @ViewBuilder
    private var headerStatusIcon: some View {
        if isStreaming {
            ProgressView()
                .scaleEffect(0.6)
        } else if hasFailed {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.statusError)
                .font(.system(size: Typography.IconSize.xs))
        } else if isSelected {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.statusConnected)
                .font(.system(size: Typography.IconSize.sm))
        } else if isDefaultCandidate {
            Text("Default")
                .font(Typography.micro)
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, Spacing.xs)
                .padding(.vertical, Spacing.xxxs)
                .background(Theme.textSecondary.opacity(0.1))
                .clipShape(Capsule())
        }
    }

    private var contentScrollView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                if message.mediaType == .image {
                    // Image generation content
                    if let imageData = message.effectiveImageData, let nsImage = NSImage(data: imageData) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: Spacing.CornerRadius.lg))
                            .contextMenu {
                                Button("Save Image...") {
                                    saveImage(nsImage)
                                }
                                Button("Copy Image") {
                                    copyImage(nsImage)
                                }
                            }
                    } else if isStreaming {
                        // Still generating
                        VStack(spacing: Spacing.md) {
                            ProgressView()
                                .scaleEffect(1.5)
                            Text("Generating image...")
                                .font(Typography.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Spacing.xxl)
                    } else if hasFailed {
                        failedContentView
                    } else {
                        // Completed but no image data (shouldn't happen)
                        Text("Image unavailable")
                            .font(Typography.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Spacing.xxl)
                    }
                } else if message.content.isEmpty, isStreaming {
                    TypingIndicatorView()
                        .padding(.vertical, Spacing.sm)
                } else if hasFailed {
                    failedContentView
                } else {
                    ForEach(cachedContentBlocks, id: \.id) { block in
                        block.view
                    }
                }
            }
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 120, maxHeight: 300)
    }

    private var failedContentView: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: Typography.IconSize.xl))
                .foregroundStyle(Theme.statusError)
            Text("Failed to get response")
                .font(Typography.captionBold)
                .foregroundStyle(Theme.textSecondary)
            if let onRetry {
                Button("Retry") {
                    onRetry()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.xxl)
    }

    @ViewBuilder
    private var pendingToolCallsView: some View {
        if let pendingCalls = message.pendingToolCalls, !pendingCalls.isEmpty {
            Divider()
            HStack(spacing: Spacing.xs) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: Typography.Size.sm))
                    .foregroundStyle(Theme.statusConnecting)
                Text("\(pendingCalls.count) tool call\(pendingCalls.count > 1 ? "s" : "") pending")
                    .font(.system(size: Typography.Size.sm))
                    .foregroundStyle(Theme.statusConnecting)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.xs)
            .background(Theme.statusConnecting.opacity(0.08))
        }
    }

    @ViewBuilder
    private var selectionButtonView: some View {
        if !isSelectionMade, !isStreaming, !hasFailed {
            Divider()
            Button(action: {
                onSelect?()
            }) {
                HStack {
                    Image(systemName: "checkmark.circle")
                    Text("Select this response")
                }
                .font(Typography.buttonSmall)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.sm)
            }
            .buttonStyle(.plain)
            .foregroundStyle(isHovered ? Theme.accent : Theme.textSecondary)
        }
    }

    // MARK: - Image Actions

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

/// A compact view for selecting models to use in multi-model mode
struct MultiModelSelector: View {
    @Binding var selectedModels: Set<String>
    let availableModels: [String]
    let maxSelection: Int

    @State private var isExpanded = false
    @ObservedObject private var aiService = AIService.shared

    /// Determines the capability type of currently selected models (if any)
    private var selectedCapabilityType: AIService.ModelCapability? {
        guard let firstSelected = selectedModels.first else { return nil }
        return aiService.getModelCapability(firstSelected)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            toggleButton
            if isExpanded {
                modelList
            }
        }
        .accessibilityIdentifier("multimodel.selector")
    }

    private var toggleButton: some View {
        Button(action: {
            withAnimation(Motion.springSnappy) {
                isExpanded.toggle()
            }
        }) {
            toggleButtonContent
        }
        .buttonStyle(.plain)
    }

    private var toggleButtonContent: some View {
        HStack {
            Image(systemName: "square.stack.3d.up")
            Text("Multi-Model")
                .font(Typography.buttonSmall)

            if !selectedModels.isEmpty {
                Text("(\(selectedModels.count))")
                    .font(Typography.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer()

            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: Typography.Size.xs, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: Spacing.CornerRadius.md)
                .fill(selectedModels.isEmpty ? Theme.textSecondary.opacity(0.1) : Theme.accent.opacity(0.15))
        )
    }

    private var modelList: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            // Header with capability hint
            if selectedCapabilityType == .imageGeneration {
                Text("Select up to \(maxSelection) image models:")
                    .font(Typography.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, Spacing.xxs)
            } else if selectedCapabilityType == .chat {
                Text("Select up to \(maxSelection) text models:")
                    .font(Typography.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, Spacing.xxs)
            } else {
                Text("Select up to \(maxSelection) models:")
                    .font(Typography.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, Spacing.xxs)
            }

            ForEach(availableModels, id: \.self) { model in
                modelRow(for: model)
            }
        }
        .padding(Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: Spacing.CornerRadius.md)
                .fill(Theme.textSecondary.opacity(0.05))
                .strokeBorder(Theme.border, lineWidth: Spacing.Border.standard)
        )
    }

    private func modelRow(for model: String) -> some View {
        let isSelected = selectedModels.contains(model)
        let modelCapability = aiService.getModelCapability(model)

        // Disable if max reached OR if mixing capability types
        let isCapabilityMismatch: Bool = {
            guard let selectedType = selectedCapabilityType else { return false }
            return modelCapability != selectedType
        }()
        let isDisabled = !isSelected && (selectedModels.count >= maxSelection || isCapabilityMismatch)

        return Button(action: {
            toggleModel(model)
        }) {
            HStack {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isSelected ? Theme.accent : Theme.textSecondary)

                Text(model)
                    .font(Typography.caption)
                    .lineLimit(1)

                Spacer()

                // Show capability badge for image gen models
                if modelCapability == .imageGeneration {
                    Image(systemName: "photo")
                        .font(.system(size: Typography.Size.xs))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: Spacing.CornerRadius.sm)
                    .fill(isSelected ? Theme.accent.opacity(0.1) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.5 : 1.0)
    }

    private func toggleModel(_ model: String) {
        if selectedModels.contains(model) {
            selectedModels.remove(model)
        } else if selectedModels.count < maxSelection {
            selectedModels.insert(model)
        }
    }
}

// MARK: - Previews

#if DEBUG
    struct MultiModelResponseView_Previews: PreviewProvider {
        static var previews: some View {
            let groupId = UUID()
            let responses = [
                Message(
                    role: .assistant,
                    content: "This is a response from GPT-4o.",
                    model: "gpt-4o",
                    responseGroupId: groupId
                ),
                Message(
                    role: .assistant,
                    content: "Claude's response here.",
                    model: "claude-3.5-sonnet",
                    responseGroupId: groupId
                )
            ]

            var conversation = Conversation()
            conversation.responseGroups = [
                ResponseGroup(
                    id: groupId,
                    userMessageId: UUID(),
                    responses: [
                        ResponseGroup.ResponseEntry(id: responses[0].id, modelName: "gpt-4o", status: .completed),
                        ResponseGroup.ResponseEntry(id: responses[1].id, modelName: "claude-3.5-sonnet", status: .completed)
                    ]
                )
            ]

            return MultiModelResponseView(
                responseGroupId: groupId,
                responses: responses,
                conversation: conversation
            )
            .frame(width: 800)
            .padding()
        }
    }

    struct MultiModelSelector_Previews: PreviewProvider {
        static var previews: some View {
            PreviewWrapper()
        }

        struct PreviewWrapper: View {
            @State private var selectedModels: Set<String> = ["gpt-4o"]

            var body: some View {
                MultiModelSelector(
                    selectedModels: $selectedModels,
                    availableModels: ["gpt-4o", "gpt-4o-mini", "claude-3.5-sonnet"],
                    maxSelection: 4
                )
                .frame(width: 250)
                .padding()
            }
        }
    }
#endif
