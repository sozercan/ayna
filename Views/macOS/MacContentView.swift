//
//  MacContentView.swift
//  ayna
//
//  Created on 11/2/25.
//

import Combine
import CoreSpotlight
import OSLog
import SwiftUI

extension Notification.Name {
    static let newConversationRequested = Notification.Name("newConversationRequested")
    static let sendPendingMessage = Notification.Name("sendPendingMessage")
}

struct MacContentView: View {
    @EnvironmentObject var conversationManager: ConversationManager
    @ObservedObject private var deepLinkManager = DeepLinkManager.shared

    var body: some View {
        ZStack {
            NavigationSplitView {
                MacSidebarView(selectedConversationId: $conversationManager.selectedConversationId)
                    .navigationSplitViewColumnWidth(min: 260, ideal: 280, max: 320)
            } detail: {
                Group {
                    if let conversationId = conversationManager.selectedConversationId,
                       let conversation = conversationManager.conversations.first(where: {
                           $0.id == conversationId
                       })
                    {
                        MacChatView(conversation: conversation)
                            .id(conversationId)
                    } else {
                        MacNewChatView(
                            selectedConversationId: $conversationManager.selectedConversationId
                        )
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Button(action: {
                            conversationManager.selectedConversationId = nil
                            NotificationCenter.default.post(name: .newConversationRequested, object: nil)
                        }) {
                            Image(systemName: "square.and.pencil")
                        }
                        .accessibilityIdentifier(TestIdentifiers.Sidebar.newConversationButton)
                    }
                }
            }
            .transaction { transaction in
                transaction.disablesAnimations = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .newConversationRequested)) { _ in
                conversationManager.selectedConversationId = nil
            }
            .onContinueUserActivity(CSSearchableItemActionType) { userActivity in
                if let idString = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                   let uuid = UUID(uuidString: idString)
                {
                    DiagnosticsLogger.log(
                        .app,
                        level: .info,
                        message: "🔍 Opening conversation from Spotlight",
                        metadata: ["conversationId": idString]
                    )
                    conversationManager.selectedConversationId = uuid
                }
            }

            // Deep link error banner overlay
            if let errorMessage = deepLinkManager.errorMessage {
                VStack {
                    ErrorBannerView(
                        message: errorMessage,
                        recoverySuggestion: deepLinkManager.errorRecoverySuggestion,
                        onDismiss: { deepLinkManager.dismissError() }
                    )
                    Spacer()
                }
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.easeInOut(duration: 0.3), value: deepLinkManager.errorMessage)
            }
        }
        // Add model confirmation sheet
        .sheet(isPresented: .init(
            get: { deepLinkManager.pendingAddModel != nil },
            set: { newValue in
                // Only cancel if the sheet is being dismissed AND pendingAddModel is still set
                // (i.e., user dismissed without clicking Add - confirmAddModel already clears it)
                if !newValue, deepLinkManager.pendingAddModel != nil {
                    deepLinkManager.cancelAddModel()
                }
            }
        )) {
            if let request = deepLinkManager.pendingAddModel {
                AddModelConfirmationSheet(request: request)
            }
        }
        // Process pending chat after add-model sheet is dismissed (unified flow)
        .onChange(of: deepLinkManager.pendingAddModel) { oldValue, newValue in
            // When pendingAddModel goes from some value to nil AND we have a pending chat
            if oldValue != nil, newValue == nil, let chatRequest = deepLinkManager.pendingChat {
                // Model was added (or cancelled), process the pending chat if model now exists
                if let model = chatRequest.model,
                   AIService.shared.customModels.contains(model)
                {
                    _ = conversationManager.startConversation(
                        model: chatRequest.model,
                        prompt: chatRequest.prompt,
                        systemPrompt: chatRequest.systemPrompt
                    )
                }
                deepLinkManager.clearPendingChat()
            }
        }
    }
}

// MARK: - Add Model Confirmation Sheet

private struct AddModelConfirmationSheet: View {
    let request: AddModelRequest
    @ObservedObject private var deepLinkManager = DeepLinkManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 24) {
            // Header
            VStack(spacing: 12) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.blue)

                Text("Add Model")
                    .font(.title2.weight(.semibold))

                Text("A deep link is requesting to add a new model configuration.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Model details
            VStack(alignment: .leading, spacing: 12) {
                DetailRow(label: "Name", value: request.name)
                DetailRow(label: "Provider", value: request.displayProvider)
                DetailRow(label: "Endpoint Type", value: request.displayEndpointType)

                if let endpoint = request.endpoint, !endpoint.isEmpty {
                    DetailRow(label: "Endpoint", value: endpoint)
                }

                if request.apiKey != nil {
                    DetailRow(label: "API Key", value: "••••••••")
                }
            }
            .padding()
            .background(Color.secondary.opacity(0.1))
            .clipShape(.rect(cornerRadius: 8))

            // Warning
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text("Only add models from sources you trust.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Actions
            HStack(spacing: 16) {
                Button("Cancel") {
                    deepLinkManager.cancelAddModel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Add Model") {
                    deepLinkManager.confirmAddModel()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
        .frame(width: 420)
    }
}

private struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(.subheadline.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

#Preview {
    MacContentView()
        .environmentObject(ConversationManager())
}
