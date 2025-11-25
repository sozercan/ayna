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
            selectionStatusBar
        }
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
        .accessibilityIdentifier("multimodel.response.group")
    }

    private var headerTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(responses.enumerated()), id: \.offset) { index, response in
                    headerTab(index: index, response: response)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(Color(uiColor: .systemBackground))
    }

    private func headerTab(index: Int, response: Message) -> some View {
        let isResponseSelected = response.id == selectedResponseId
        let isCurrentTab = index == selectedTab
        let status = responseGroup?.responses.first { $0.id == response.id }?.status

        return Button {
            withAnimation {
                selectedTab = index
            }
        } label: {
            headerTabLabel(
                modelName: response.model ?? "Model \(index + 1)",
                status: status,
                isSelected: isResponseSelected,
                isCurrentTab: isCurrentTab
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(isResponseSelected ? .green : (isCurrentTab ? Color.accentColor : .primary))
    }

    private func headerTabLabel(modelName: String, status: ResponseGroupStatus?, isSelected: Bool, isCurrentTab: Bool) -> some View {
        HStack(spacing: 4) {
            statusIcon(status: status, isSelected: isSelected)
            Text(modelName)
                .font(.system(size: 12, weight: isCurrentTab ? .semibold : .regular))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(isCurrentTab ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1))
        )
        .overlay(
            Capsule()
                .strokeBorder(isSelected ? Color.green : (isCurrentTab ? Color.accentColor : Color.clear), lineWidth: 1.5)
        )
    }

    @ViewBuilder
    private func statusIcon(status: ResponseGroupStatus?, isSelected: Bool) -> some View {
        if status == .streaming {
            ProgressView()
                .scaleEffect(0.6)
        } else if status == .failed {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.red)
        } else if isSelected {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.green)
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

    private func responseCard(index: Int, response: Message) -> some View {
        IOSMultiModelResponseCard(
            message: response,
            isSelected: response.id == selectedResponseId,
            isSelectionMade: isSelectionMade,
            responseStatus: responseGroup?.responses.first { $0.id == response.id }?.status,
            onSelect: {
                let generator = UIImpactFeedbackGenerator(style: .medium)
                generator.impactOccurred()
                onSelectResponse?(response.id)
            },
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
                    .foregroundStyle(.green)
                if let selectedEntry = responseGroup?.selectedEntry {
                    Text("Selected: \(selectedEntry.modelName)")
                        .font(.system(size: 13, weight: .medium))
                }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color.green.opacity(0.1))
        }
    }
}

/// Individual response card for iOS
struct IOSMultiModelResponseCard: View {
    let message: Message
    let isSelected: Bool
    let isSelectionMade: Bool
    let responseStatus: ResponseGroupStatus?
    var onSelect: (() -> Void)?
    var onRetry: (() -> Void)?

    @State private var contentBlocks: [ContentBlock]

    init(
        message: Message,
        isSelected: Bool,
        isSelectionMade: Bool,
        responseStatus: ResponseGroupStatus?,
        onSelect: (() -> Void)? = nil,
        onRetry: (() -> Void)? = nil
    ) {
        self.message = message
        self.isSelected = isSelected
        self.isSelectionMade = isSelectionMade
        self.responseStatus = responseStatus
        self.onSelect = onSelect
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
            selectButton
        }
        .background(Color(uiColor: .systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
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
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(isSelected ? Color.green : Color.secondary.opacity(0.2), lineWidth: isSelected ? 2 : 1)
    }

    private var responseContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
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
                .padding(.vertical, 16)
        } else if hasFailed {
            failedStateView
        } else {
            ForEach(contentBlocks) { block in
                IOSContentBlockView(block: block)
            }
        }
    }

    private var failedStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(.red)
            Text("Failed to get response")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            if let onRetry {
                Button("Retry") {
                    onRetry()
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    @ViewBuilder
    private var pendingToolCallsIndicator: some View {
        if let pendingCalls = message.pendingToolCalls, !pendingCalls.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                Text("\(pendingCalls.count) tool call\(pendingCalls.count > 1 ? "s" : "") pending")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            }
            .padding(8)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private var selectButton: some View {
        if !isSelectionMade, !isStreaming, !hasFailed {
            Divider()
            Button(action: {
                onSelect?()
            }) {
                HStack {
                    Image(systemName: "checkmark.circle")
                    Text("Use this response")
                }
                .font(.system(size: 14, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .foregroundStyle(Color.accentColor)
        }
    }
}

/// iOS model selector for multi-model mode
struct IOSMultiModelSelector: View {
    @Binding var selectedModels: Set<String>
    let availableModels: [String]
    let maxSelection: Int

    var body: some View {
        List {
            Section {
                ForEach(availableModels, id: \.self) { model in
                    modelRow(for: model)
                }
            } header: {
                Text("Select up to \(maxSelection) models")
            } footer: {
                Text("Selected models will receive your message simultaneously for comparison.")
            }
        }
        .navigationTitle("Multi-Model")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func modelRow(for model: String) -> some View {
        let isModelSelected = selectedModels.contains(model)
        let isDisabled = !isModelSelected && selectedModels.count >= maxSelection

        return Button {
            toggleModel(model)
        } label: {
            HStack {
                Text(model)
                    .foregroundStyle(.primary)

                Spacer()

                Image(systemName: isModelSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isModelSelected ? Color.accentColor : Color.secondary)
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
