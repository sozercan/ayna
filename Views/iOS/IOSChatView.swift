//
//  IOSChatView.swift
//  ayna
//
//  Created on 11/22/25.
//

import os.log
import SwiftUI
import UniformTypeIdentifiers

struct IOSChatView: View {
    let conversationId: UUID
    @EnvironmentObject var conversationManager: ConversationManager
    @StateObject private var openAIService = OpenAIService.shared

    @State private var isFileImporterPresented = false
    @State private var showingSystemPromptSheet = false
    @StateObject private var viewModel = IOSChatViewModel.placeholder()

    /// Get the conversation from the environment's conversation manager
    private var conversation: Conversation? {
        conversationManager.conversations.first { $0.id == conversationId }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let conversation {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(spacing: 12) {
                            ForEach(conversation.messages) { message in
                                IOSMessageView(
                                    message: message,
                                    onRetry: message.role == .assistant ? {
                                        viewModel.retryMessage(beforeMessage: message)
                                    } : nil
                                )
                                .id(message.id)
                                .accessibilityIdentifier(TestIdentifiers.ChatView.messageRow(for: message.id))
                            }
                        }
                        .padding()
                    }
                    .accessibilityIdentifier(TestIdentifiers.ChatView.messagesList)
                    .defaultScrollAnchor(.bottom)
                    .onChange(of: conversation.messages.count) { _ in
                        scrollToBottom(proxy: proxy, conversation: conversation)
                    }
                    .onChange(of: conversation.messages.last?.content) { _ in
                        if viewModel.isGenerating, let lastId = conversation.messages.last?.id {
                            proxy.scrollTo(lastId, anchor: .bottom)
                        }
                    }
                    .onAppear {
                        DiagnosticsLogger.log(
                            .chatView,
                            level: .info,
                            message: "📱 IOSChatView appeared",
                            metadata: ["conversationId": conversationId.uuidString]
                        )
                        // Scroll to bottom after a short delay to ensure content is laid out
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(100))
                            if let lastId = conversation.messages.last?.id {
                                proxy.scrollTo(lastId, anchor: .bottom)
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView("Conversation not found", systemImage: "exclamationmark.triangle")
                    .accessibilityIdentifier(TestIdentifiers.ChatView.emptyState)
            }

            IOSMessageComposer(
                messageText: $viewModel.messageText,
                isGenerating: $viewModel.isGenerating,
                errorMessage: $viewModel.errorMessage,
                attachedFiles: $viewModel.attachedFiles,
                showAttachmentButton: true,
                identifierPrefix: "chat.composer",
                onSend: { viewModel.sendMessage() },
                onCancel: { viewModel.cancelGeneration() },
                onAttachmentRequested: { isFileImporterPresented = true }
            )
        }
        .navigationTitle(conversation?.title ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            viewModel.handleFileImport(result)
        }
        .toolbar {
            if let conversation {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(conversation.title)
                            .font(.headline)

                        Menu {
                            ForEach(openAIService.usableModels, id: \.self) { model in
                                Button {
                                    conversationManager.updateModel(for: conversation, model: model)
                                } label: {
                                    if conversation.model == model {
                                        Label(model, systemImage: "checkmark")
                                    } else {
                                        Text(model)
                                    }
                                }
                            }
                        } label: {
                            Text(conversation.model)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(TestIdentifiers.ChatView.modelSelector)
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingSystemPromptSheet = true
                    } label: {
                        Image(systemName: "text.bubble")
                    }
                    .accessibilityIdentifier("chat.systemPrompt.button")
                }
            }
        }
        .sheet(isPresented: $showingSystemPromptSheet) {
            if let conversation {
                IOSConversationSystemPromptSheet(conversation: conversation)
                    .environmentObject(conversationManager)
            }
        }
        .onAppear {
            // Configure ViewModel with actual environment object and conversation ID
            viewModel.configure(with: conversationManager, conversationId: conversationId)
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy, conversation: Conversation) {
        if let lastId = conversation.messages.last?.id {
            withAnimation {
                proxy.scrollTo(lastId, anchor: .bottom)
            }
        }
    }
}

// MARK: - Conversation System Prompt Sheet

struct IOSConversationSystemPromptSheet: View {
    let conversation: Conversation
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var conversationManager: ConversationManager

    @State private var selectedMode: SystemPromptModeSelection = .inheritGlobal
    @State private var customPrompt: String = ""

    enum SystemPromptModeSelection: String, CaseIterable {
        case inheritGlobal = "Global"
        case custom = "Custom"
        case disabled = "None"
    }

    init(conversation: Conversation) {
        self.conversation = conversation

        // Initialize state from conversation
        switch conversation.systemPromptMode {
        case .inheritGlobal:
            _selectedMode = State(initialValue: .inheritGlobal)
            _customPrompt = State(initialValue: "")
        case let .custom(prompt):
            _selectedMode = State(initialValue: .custom)
            _customPrompt = State(initialValue: prompt)
        case .disabled:
            _selectedMode = State(initialValue: .disabled)
            _customPrompt = State(initialValue: "")
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Mode", selection: $selectedMode) {
                        ForEach(SystemPromptModeSelection.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("chat.systemPromptMode.picker")
                } header: {
                    Text("System Prompt Mode")
                }

                if selectedMode == .inheritGlobal {
                    Section {
                        let globalPrompt = AppPreferences.globalSystemPrompt
                        if globalPrompt.isEmpty {
                            Text("No global prompt set")
                                .foregroundStyle(.secondary)
                                .italic()
                        } else {
                            Text(globalPrompt)
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Current Global Prompt")
                    }
                } else if selectedMode == .custom {
                    Section {
                        TextEditor(text: $customPrompt)
                            .frame(minHeight: 120)
                            .accessibilityIdentifier("chat.systemPrompt.customEditor")
                    } header: {
                        Text("Custom Prompt")
                    }
                } else {
                    Section {
                        Text("No system prompt will be used for this conversation.")
                            .foregroundStyle(.secondary)
                            .italic()
                    }
                }
            }
            .navigationTitle("System Prompt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveAndDismiss()
                    }
                }
            }
        }
    }

    private func saveAndDismiss() {
        let mode: SystemPromptMode = switch selectedMode {
        case .inheritGlobal:
            .inheritGlobal
        case .custom:
            .custom(customPrompt)
        case .disabled:
            .disabled
        }

        conversationManager.updateSystemPromptMode(for: conversation, mode: mode)
        dismiss()
    }
}
