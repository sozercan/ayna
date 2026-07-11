#if os(macOS)
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
    @State private var presentedAddModelRequest: AddModelRequest?
    @State private var dismissingAddModelRequestID: UUID?

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
            get: { presentedAddModelRequest != nil },
            set: { newValue in
                guard !newValue else { return }
                if let requestID = dismissingAddModelRequestID {
                    completeAddModelDismissal(requestID)
                } else if let request = presentedAddModelRequest {
                    dismissingAddModelRequestID = request.id
                    presentedAddModelRequest = nil
                    deepLinkManager.cancelAddModel(expectedRequestID: request.id)
                    completeAddModelDismissal(request.id)
                }
            }
        )) {
            if let request = presentedAddModelRequest {
                AddModelConfirmationSheet(
                    request: request,
                    onCancel: { finishPresentedAddModel(request, shouldConfirm: false) },
                    onConfirm: { finishPresentedAddModel(request, shouldConfirm: true) }
                )
            }
        }
        .onAppear {
            if presentedAddModelRequest == nil {
                presentedAddModelRequest = deepLinkManager.pendingAddModel
            }
        }
        // Process pending chat after add-model sheet is dismissed (unified flow)
        .onChange(of: deepLinkManager.pendingAddModel) { oldValue, newValue in
            updatePresentedAddModel(from: oldValue, to: newValue)
            guard oldValue != nil, newValue == nil else { return }

            if let chatRequest = deepLinkManager.consumeNextReadyChat() {
                _ = conversationManager.startConversation(
                    model: chatRequest.model,
                    prompt: chatRequest.prompt,
                    systemPrompt: chatRequest.systemPrompt
                )
            }
        }
    }

    private func finishPresentedAddModel(_ request: AddModelRequest, shouldConfirm: Bool) {
        guard dismissingAddModelRequestID == nil,
              presentedAddModelRequest?.id == request.id
        else { return }

        dismissingAddModelRequestID = request.id
        presentedAddModelRequest = nil
        if shouldConfirm {
            deepLinkManager.confirmAddModel(expectedRequestID: request.id)
        } else {
            deepLinkManager.cancelAddModel(expectedRequestID: request.id)
        }
    }

    private func updatePresentedAddModel(from oldValue: AddModelRequest?, to newValue: AddModelRequest?) {
        if newValue == nil,
           dismissingAddModelRequestID == nil,
           presentedAddModelRequest?.id == oldValue?.id
        {
            dismissingAddModelRequestID = oldValue?.id
            presentedAddModelRequest = nil
        } else if newValue != nil,
                  dismissingAddModelRequestID == nil,
                  presentedAddModelRequest == nil
        {
            presentedAddModelRequest = newValue
        }
    }

    private func completeAddModelDismissal(_ requestID: UUID) {
        guard dismissingAddModelRequestID == requestID else { return }
        presentPendingAddModelAfterDismissal(requestID)
    }

    private func presentPendingAddModelAfterDismissal(_ requestID: UUID) {
        Task { @MainActor in
            await Task.yield()
            guard dismissingAddModelRequestID == requestID else { return }
            dismissingAddModelRequestID = nil
            if presentedAddModelRequest == nil {
                presentedAddModelRequest = deepLinkManager.pendingAddModel
            }
        }
    }
}

// MARK: - Add Model Confirmation Sheet

private struct AddModelConfirmationSheet: View {
    let request: AddModelRequest
    let onCancel: () -> Void
    let onConfirm: () -> Void
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
                    onCancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Add Model") {
                    onConfirm()
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
#endif
