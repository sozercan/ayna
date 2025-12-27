//
//  IOSMultiModelResponseView.swift
//  ayna
//
//  Created on 11/25/25.
//

import Combine
import SwiftUI

/// A view that displays parallel responses from multiple AI models using a swipeable TabView.
/// Users can compare responses and select one to continue the conversation.
struct IOSMultiModelResponseView: View {
    let responseGroupId: UUID
    let responses: [Message]
    let conversation: Conversation
    var onSelectResponse: ((UUID) -> Void)?
    var onRetry: ((Message) -> Void)?
    /// ID of the response that would be auto-selected if user continues without choosing
    var defaultCandidateId: UUID?

    @State private var selectedTab = 0

    private var responseGroup: ResponseGroup? {
        conversation.getResponseGroup(responseGroupId)
    }

    private var selectedResponseId: UUID? {
        responseGroup?.selectedResponseId
    }

    private var isSelectionMade: Bool {
        selectedResponseId != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            headerTabs
            Divider()
            contentTabView
            selectButtonSection
            selectionStatusBar
        }
        .background(Theme.backgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: Spacing.CornerRadius.xxl))
        .padding(.horizontal)
        .accessibilityIdentifier("multimodel.response.group")
    }

    private var headerTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.sm) {
                ForEach(Array(responses.enumerated()), id: \.offset) { index, response in
                    headerTab(index: index, response: response)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, Spacing.sm)
        }
        .background(Theme.background)
    }

    private func headerTab(index: Int, response: Message) -> some View {
        let isResponseSelected = response.id == selectedResponseId
        let isCurrentTab = index == selectedTab
        let status = responseGroup?.responses.first { $0.id == response.id }?.status
        let isDefault = response.id == defaultCandidateId && !isSelectionMade

        return Button {
            withAnimation {
                selectedTab = index
            }
        } label: {
            headerTabLabel(
                modelName: response.model ?? "Model \(index + 1)",
                status: status,
                isSelected: isResponseSelected,
                isCurrentTab: isCurrentTab,
                isDefaultCandidate: isDefault
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(isResponseSelected ? Theme.statusConnected : (isCurrentTab ? Theme.accent : Theme.textPrimary))
    }

    private func headerTabLabel(modelName: String, status: ResponseGroupStatus?, isSelected: Bool, isCurrentTab: Bool, isDefaultCandidate: Bool) -> some View {
        HStack(spacing: Spacing.xxs) {
            statusIcon(status: status, isSelected: isSelected)
            Text(modelName)
                .font(.system(size: Typography.Size.caption, weight: isCurrentTab ? .semibold : .regular))
                .lineLimit(1)
            if isDefaultCandidate {
                Text("Default")
                    .font(Typography.micro)
                    .foregroundStyle(.white)
                    .padding(.horizontal, Spacing.xxs)
                    .padding(.vertical, Spacing.xxxs)
                    .background(Capsule().fill(Theme.statusConnecting.opacity(0.8)))
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.xs)
        .background(
            Capsule()
                .fill(isCurrentTab ? Theme.accent.opacity(0.2) : Theme.textSecondary.opacity(0.1))
        )
        .overlay(
            Capsule()
                .strokeBorder(isSelected ? Theme.statusConnected : (isCurrentTab ? Theme.accent : (isDefaultCandidate ? Theme.statusConnecting.opacity(0.5) : Color.clear)), lineWidth: Spacing.Border.emphasized)
        )
    }

    @ViewBuilder
    private func statusIcon(status: ResponseGroupStatus?, isSelected: Bool) -> some View {
        if status == .streaming {
            ProgressView()
                .scaleEffect(0.6)
        } else if status == .failed {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: Typography.Size.xs))
                .foregroundStyle(Theme.statusError)
        } else if isSelected {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: Typography.Size.xs))
                .foregroundStyle(Theme.statusConnected)
        }
    }

    private var contentTabView: some View {
        TabView(selection: $selectedTab) {
            ForEach(Array(responses.enumerated()), id: \.offset) { index, response in
                responseCard(index: index, response: response)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .automatic))
        .frame(minHeight: 200)
    }

    private var currentResponse: Message? {
        guard selectedTab < responses.count else { return nil }
        return responses[selectedTab]
    }

    private var currentResponseStatus: ResponseGroupStatus? {
        guard let response = currentResponse else { return nil }
        return responseGroup?.responses.first { $0.id == response.id }?.status
    }

    @ViewBuilder
    private var selectButtonSection: some View {
        if !isSelectionMade,
           let response = currentResponse,
           currentResponseStatus != .streaming,
           currentResponseStatus != .failed
        {
            Divider()
            Button(action: {
                let generator = UIImpactFeedbackGenerator(style: .medium)
                generator.impactOccurred()
                onSelectResponse?(response.id)
            }) {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Use this response")
                }
                .font(Typography.subheadline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.md)
            }
            .foregroundStyle(.white)
            .background(Theme.accent)
            .accessibilityIdentifier("multimodel.selectResponse.button")
        }
    }

    private func responseCard(index: Int, response: Message) -> some View {
        IOSMultiModelResponseCard(
            message: response,
            isSelected: response.id == selectedResponseId,
            isSelectionMade: isSelectionMade,
            responseStatus: responseGroup?.responses.first { $0.id == response.id }?.status,
            onRetry: {
                onRetry?(response)
            }
        )
        .tag(index)
    }

    @ViewBuilder
    private var selectionStatusBar: some View {
        if isSelectionMade {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.statusConnected)
                if let selectedEntry = responseGroup?.selectedEntry {
                    Text("Selected: \(selectedEntry.modelName)")
                        .font(Typography.captionBold)
                }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, Spacing.sm)
            .background(Theme.statusConnected.opacity(0.1))
        }
    }
}

/// Individual response card for iOS
struct IOSMultiModelResponseCard: View {
    let message: Message
    let isSelected: Bool
    let isSelectionMade: Bool
    let responseStatus: ResponseGroupStatus?
    var onRetry: (() -> Void)?

    @State private var contentBlocks: [ContentBlock]

    init(
        message: Message,
        isSelected: Bool,
        isSelectionMade: Bool,
        responseStatus: ResponseGroupStatus?,
        onRetry: (() -> Void)? = nil
    ) {
        self.message = message
        self.isSelected = isSelected
        self.isSelectionMade = isSelectionMade
        self.responseStatus = responseStatus
        self.onRetry = onRetry
        _contentBlocks = State(initialValue: MarkdownRenderer.parse(message.content))
    }

    private var isStreaming: Bool {
        responseStatus == .streaming
    }

    private var hasFailed: Bool {
        responseStatus == .failed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            responseContent
        }
        .background(Theme.background)
        .clipShape(RoundedRectangle(cornerRadius: Spacing.CornerRadius.xl))
        .overlay(cardBorder)
        .opacity(isSelectionMade && !isSelected ? 0.6 : 1.0)
        .padding(.horizontal)
        .onChange(of: message.content) { _, newContent in
            Task.detached(priority: .userInitiated) {
                let blocks = MarkdownRenderer.parse(newContent)
                await MainActor.run {
                    contentBlocks = blocks
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Response from \(message.model ?? "unknown model")")
        .accessibilityHint(isSelected ? "Selected" : "Double tap to select")
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: Spacing.CornerRadius.xl)
            .strokeBorder(isSelected ? Theme.statusConnected : Theme.border, lineWidth: isSelected ? Spacing.Border.thick : Spacing.Border.standard)
    }

    private var responseContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                contentBody
                pendingToolCallsIndicator
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var contentBody: some View {
        if message.content.isEmpty, isStreaming {
            IOSTypingIndicatorView()
                .padding(.vertical, Spacing.lg)
        } else if hasFailed {
            failedStateView
        } else {
            ForEach(contentBlocks) { block in
                IOSContentBlockView(block: block)
            }
        }
    }

    private var failedStateView: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: Typography.IconSize.heroLarge / 2))
                .foregroundStyle(Theme.statusError)
            Text("Failed to get response")
                .font(Typography.bodySecondary)
                .foregroundStyle(Theme.textSecondary)
            if let onRetry {
                Button("Retry") {
                    onRetry()
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.xxxl)
    }

    @ViewBuilder
    private var pendingToolCallsIndicator: some View {
        if let pendingCalls = message.pendingToolCalls, !pendingCalls.isEmpty {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: Typography.Size.caption))
                    .foregroundStyle(Theme.statusConnecting)
                Text("\(pendingCalls.count) tool call\(pendingCalls.count > 1 ? "s" : "") pending")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.statusConnecting)
            }
            .padding(Spacing.sm)
            .background(Theme.statusConnecting.opacity(0.1), in: RoundedRectangle(cornerRadius: Spacing.CornerRadius.md))
        }
    }
}

/// iOS model selector for multi-model mode
struct IOSMultiModelSelector: View {
    @Binding var selectedModels: Set<String>
    let availableModels: [String]
    let maxSelection: Int

    @ObservedObject private var openAIService = OpenAIService.shared

    /// Determines the capability type of currently selected models (if any)
    private var selectedCapabilityType: OpenAIService.ModelCapability? {
        guard let firstSelected = selectedModels.first else { return nil }
        return openAIService.getModelCapability(firstSelected)
    }

    var body: some View {
        List {
            Section {
                ForEach(availableModels, id: \.self) { model in
                    modelRow(for: model)
                }
            } header: {
                Text("Select up to \(maxSelection) models")
            } footer: {
                if selectedCapabilityType == .imageGeneration {
                    Text("Image generation models selected. Only other image models can be added for comparison.")
                } else if selectedCapabilityType == .chat {
                    Text("Text models selected. Only other text models can be added for comparison.")
                } else {
                    Text("Selected models will receive your message simultaneously for comparison.")
                }
            }
        }
        .navigationTitle("Multi-Model")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func modelRow(for model: String) -> some View {
        let isModelSelected = selectedModels.contains(model)
        let modelCapability = openAIService.getModelCapability(model)

        // Disable if max reached OR if mixing capability types
        let isCapabilityMismatch: Bool = {
            guard let selectedType = selectedCapabilityType else { return false }
            return modelCapability != selectedType
        }()
        let isDisabled = !isModelSelected && (selectedModels.count >= maxSelection || isCapabilityMismatch)

        return Button {
            toggleModel(model)
        } label: {
            HStack {
                Text(model)
                    .foregroundStyle(Theme.textPrimary)

                Spacer()

                // Show capability badge for image gen models
                if modelCapability == .imageGeneration {
                    Image(systemName: "photo")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }

                Image(systemName: isModelSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isModelSelected ? Theme.accent : Theme.textSecondary)
            }
        }
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.5 : 1.0)
    }

    private func toggleModel(_ model: String) {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()

        if selectedModels.contains(model) {
            selectedModels.remove(model)
        } else if selectedModels.count < maxSelection {
            selectedModels.insert(model)
        }
    }
}

// MARK: - Previews

#if DEBUG
    struct IOSMultiModelResponseView_Previews: PreviewProvider {
        static var previews: some View {
            IOSMultiModelPreviewWrapper()
        }

        struct IOSMultiModelPreviewWrapper: View {
            var body: some View {
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

                return IOSMultiModelResponseView(
                    responseGroupId: groupId,
                    responses: responses,
                    conversation: conversation
                )
            }
        }
    }

    struct IOSMultiModelSelector_Previews: PreviewProvider {
        static var previews: some View {
            PreviewWrapper()
        }

        struct PreviewWrapper: View {
            @State private var selectedModels: Set<String> = ["gpt-4o"]

            var body: some View {
                NavigationStack {
                    IOSMultiModelSelector(
                        selectedModels: $selectedModels,
                        availableModels: ["gpt-4o", "gpt-4o-mini", "claude-3.5-sonnet"],
                        maxSelection: 4
                    )
                }
            }
        }
    }
#endif
