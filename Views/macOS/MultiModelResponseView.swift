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
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: "square.stack.3d.up")
                    .foregroundStyle(.secondary)
                Text("Multi-Model Responses")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                if !isSelectionMade {
                    Text("Select a response to continue")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Response selected")
                            .font(.system(size: 12))
                            .foregroundStyle(.green)
                    }
                }
            }
            .padding(.horizontal, 24)

            // Response Grid
            LazyVGrid(columns: columns, spacing: 16) {
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
            .padding(.horizontal, 24)
        }
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.secondary.opacity(0.05))
                .strokeBorder(Color.secondary.opacity(0.1), lineWidth: 1)
        )
        .padding(.horizontal, 24)
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
            Color.green
        } else if isHovered, !isSelectionMade {
            Color.accentColor
        } else if isDefaultCandidate {
            Color.secondary.opacity(0.4)
        } else if hasFailed {
            Color.red.opacity(0.5)
        } else {
            Color.secondary.opacity(0.2)
        }
    }

    private var cardOpacity: Double {
        if isSelectionMade, !isSelected {
            return 0.5
        }
        return 1.0
    }

    private var headerBackgroundColor: Color {
        isSelected ? Color.green.opacity(0.1) : Color.secondary.opacity(0.08)
    }

    private var shadowColor: Color {
        isSelected ? Color.green.opacity(0.2) : Color.black.opacity(0.1)
    }

    var body: some View {
        cardContent
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(cardBorder)
            .opacity(cardOpacity)
            .shadow(color: shadowColor, radius: 8, x: 0, y: 4)
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

    @ViewBuilder
    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerView
            Divider()
            contentScrollView
            pendingToolCallsView
            selectionButtonView
        }
    }

    @ViewBuilder
    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(borderColor, lineWidth: isSelected ? 2 : 1)
    }

    @ViewBuilder
    private var headerView: some View {
        HStack {
            Text(modelName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isSelected ? Color.green : Color.primary)

            Spacer()

            headerStatusIcon
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(headerBackgroundColor)
    }

    @ViewBuilder
    private var headerStatusIcon: some View {
        if isStreaming {
            ProgressView()
                .scaleEffect(0.6)
        } else if hasFailed {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.red)
                .font(.system(size: 12))
        } else if isSelected {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.green)
                .font(.system(size: 14))
        } else if isDefaultCandidate {
            Text("Default")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.1))
                .clipShape(Capsule())
        }
    }

    @ViewBuilder
    private var contentScrollView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if message.content.isEmpty, isStreaming {
                    TypingIndicatorView()
                        .padding(.vertical, 8)
                } else if hasFailed {
                    failedContentView
                } else {
                    ForEach(cachedContentBlocks, id: \.id) { block in
                        block.view
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 120, maxHeight: 300)
    }

    @ViewBuilder
    private var failedContentView: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24))
                .foregroundStyle(Color.red)
            Text("Failed to get response")
                .font(.system(size: 13))
                .foregroundStyle(Color.secondary)
            if let onRetry {
                Button("Retry") {
                    onRetry()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    @ViewBuilder
    private var pendingToolCallsView: some View {
        if let pendingCalls = message.pendingToolCalls, !pendingCalls.isEmpty {
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.orange)
                Text("\(pendingCalls.count) tool call\(pendingCalls.count > 1 ? "s" : "") pending")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.orange)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.orange.opacity(0.08))
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
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .foregroundStyle(isHovered ? Color.accentColor : Color.secondary)
        }
    }
}

/// A compact view for selecting models to use in multi-model mode
struct MultiModelSelector: View {
    @Binding var selectedModels: Set<String>
    let availableModels: [String]
    let maxSelection: Int

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            toggleButton
            if isExpanded {
                modelList
            }
        }
        .accessibilityIdentifier("multimodel.selector")
    }

    private var toggleButton: some View {
        Button(action: {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
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
                .font(.system(size: 12, weight: .medium))

            if !selectedModels.isEmpty {
                Text("(\(selectedModels.count))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(selectedModels.isEmpty ? Color.secondary.opacity(0.1) : Color.accentColor.opacity(0.15))
        )
    }

    private var modelList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Select up to \(maxSelection) models:")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            ForEach(availableModels, id: \.self) { model in
                modelRow(for: model)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.05))
                .strokeBorder(Color.secondary.opacity(0.1), lineWidth: 1)
        )
    }

    private func modelRow(for model: String) -> some View {
        let isSelected = selectedModels.contains(model)
        let isDisabled = !isSelected && selectedModels.count >= maxSelection

        return Button(action: {
            toggleModel(model)
        }) {
            HStack {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                Text(model)
                    .font(.system(size: 12))
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
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
