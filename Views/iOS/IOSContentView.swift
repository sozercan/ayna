//
//  IOSContentView.swift
//  ayna
//
//  Created on 11/22/25.
//

import os.log
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct IOSContentView: View {
    @EnvironmentObject var conversationManager: ConversationManager
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            IOSSidebarView(columnVisibility: $columnVisibility)
        } detail: {
            if let selectedId = conversationManager.selectedConversationId,
               selectedId != ConversationManager.newConversationId
            {
                IOSChatView(conversationId: selectedId)
            } else {
                IOSNewChatView()
                    .id(conversationManager.selectedConversationId)
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}

struct IOSNewChatView: View {
    @EnvironmentObject var conversationManager: ConversationManager
    @StateObject private var openAIService = OpenAIService.shared
    @StateObject private var viewModel = IOSChatViewModel.placeholder()

    @State private var isFileImporterPresented = false
    @State private var isPhotoPickerPresented = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var showSettings = false
    @State private var showModelSelector = false

    /// Get the pending conversation from the environment's conversation manager
    private var pendingConversation: Conversation? {
        guard let id = viewModel.conversationId else { return nil }
        return conversationManager.conversations.first { $0.id == id }
    }

    var body: some View {
        if openAIService.usableModels.isEmpty {
            onboardingView
        } else {
            chatInterface
        }
    }

    @ViewBuilder
    private var chatInterface: some View {
        VStack(spacing: 0) {
            if let conversation = pendingConversation {
                // Show messages while generating (before navigating away)
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
                }
            } else {
                // Empty state - welcome screen
                welcomeView
            }

            IOSMessageComposer(
                messageText: $viewModel.messageText,
                isGenerating: $viewModel.isGenerating,
                errorMessage: $viewModel.errorMessage,
                attachedFiles: $viewModel.attachedFiles,
                attachedImages: $viewModel.attachedImages,
                showAttachmentButton: true,
                identifierPrefix: "newchat.composer",
                onSend: { viewModel.sendMessage() },
                onCancel: { viewModel.cancelGeneration() },
                onFileAttachmentRequested: { isFileImporterPresented = true },
                onPhotoAttachmentRequested: { isPhotoPickerPresented = true }
            )
        }
        .navigationTitle("New Chat")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            viewModel.handleFileImport(result)
        }
        .photosPicker(
            isPresented: $isPhotoPickerPresented,
            selection: $selectedPhotoItems,
            maxSelectionCount: 5,
            matching: .images
        )
        .onChange(of: selectedPhotoItems) { _, newItems in
            Task {
                await viewModel.handlePhotoSelection(newItems)
                selectedPhotoItems = []
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button(action: { showModelSelector = true }) {
                    VStack(spacing: 0) {
                        Text("New Chat")
                            .font(.headline)
                        HStack(spacing: 4) {
                            if viewModel.selectedModels.count > 1 {
                                Image(systemName: "square.stack.3d.up.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.blue)
                                Text("\(viewModel.selectedModels.count) models")
                                    .font(.caption)
                                    .foregroundStyle(.blue)
                            } else {
                                Text(viewModel.selectedModel)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(TestIdentifiers.ChatView.modelSelector)
            }
        }
        .sheet(isPresented: $showModelSelector) {
            NavigationStack {
                IOSMultiModelSelector(
                    selectedModels: $viewModel.selectedModels,
                    availableModels: openAIService.usableModels,
                    maxSelection: 4
                )
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            showModelSelector = false
                            // Update primary model if needed
                            if let first = viewModel.selectedModels.first, viewModel.selectedModels.count == 1 {
                                viewModel.selectedModel = first
                                openAIService.selectedModel = first
                            }
                        }
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .onAppear {
            // Configure ViewModel with actual environment object
            viewModel.configure(with: conversationManager)
            viewModel.onConversationCreated = { conversationId in
                conversationManager.selectedConversationId = conversationId
            }

            // Reset state when this view appears (new chat requested)
            viewModel.resetForNewChat()

            DiagnosticsLogger.log(
                .chatView,
                level: .info,
                message: "📱 IOSNewChatView appeared"
            )
        }
    }

    // MARK: - Onboarding View

    @ViewBuilder
    private var onboardingView: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "sparkles")
                .font(.system(size: 60))
                .foregroundStyle(.blue.gradient)

            VStack(spacing: 8) {
                Text("No Models Available")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Please add a model in Settings to start chatting.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                showSettings = true
            } label: {
                Text("Add Model")
                    .font(.headline)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                IOSSettingsView()
            }
        }
    }

    // MARK: - Welcome View

    @ViewBuilder
    private var welcomeView: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "sparkles")
                .font(.system(size: 60))
                .foregroundStyle(.blue.gradient)

            VStack(spacing: 8) {
                Text("How can I help you?")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Type a message below to start chatting")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier(TestIdentifiers.ChatView.emptyState)
    }

    // MARK: - Private Methods

    private func scrollToBottom(proxy: ScrollViewProxy, conversation: Conversation) {
        if let lastId = conversation.messages.last?.id {
            withAnimation {
                proxy.scrollTo(lastId, anchor: .bottom)
            }
        }
    }
}
