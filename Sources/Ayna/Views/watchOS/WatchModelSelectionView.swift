#if os(watchOS)
//
    //  WatchModelSelectionView.swift
    //  Ayna Watch App
//
    //  Created on 11/29/25.
//

    #if os(watchOS)

        import SwiftUI

        struct WatchModelSelectionView: View {
            let conversationId: UUID?

            @Environment(\.dismiss) private var dismiss
            @EnvironmentObject var connectivityService: WatchConnectivityService
            @EnvironmentObject var conversationStore: WatchConversationStore
            @ObservedObject private var aiService = AIService.shared
            @State private var showsSelectionError = false

            init(conversationId: UUID? = nil) {
                self.conversationId = conversationId
            }

            /// Filter models to only show those usable on watchOS
            private var watchUsableModels: [String] {
                connectivityService.availableModels.filter { model in
                    // Filter out Apple Intelligence - it can't run on watchOS
                    let provider = aiService.modelProviders[model]
                    return provider != .appleIntelligence
                }
            }

            /// Check if a model should show as selected
            private func isModelSelected(_ model: String) -> Bool {
                if let conversationId,
                   let conversation = conversationStore.conversation(for: conversationId)
                {
                    return conversation.model == model
                }

                // If only one model, it's always selected
                if watchUsableModels.count == 1 {
                    return true
                }
                return model == connectivityService.selectedModel
            }

            var body: some View {
                List {
                    if watchUsableModels.isEmpty {
                        Text("No models available. Sync with iPhone.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(watchUsableModels, id: \.self) { model in
                            Button {
                                if selectModel(model) {
                                    dismiss()
                                } else {
                                    showsSelectionError = true
                                }
                            } label: {
                                HStack {
                                    Text(model)
                                        .font(.body)
                                    Spacer()
                                    if isModelSelected(model) {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.blue)
                                    }
                                }
                            }
                        }
                    }
                }
                .navigationTitle("Models")
                .onAppear {
                    // Auto-select if only one model available
                    if WatchModelSelectionCoordinator.shouldAutoSelect(
                        availableModelCount: watchUsableModels.count,
                        conversationID: conversationId
                    ),
                        let onlyModel = watchUsableModels.first,
                        !selectModel(onlyModel)
                    {
                        showsSelectionError = true
                    }
                }
                .alert("Couldn't Change Model", isPresented: $showsSelectionError) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text("The model selection could not be saved. Please try again.")
                }
            }

            private func selectModel(_ model: String) -> Bool {
                WatchModelSelectionCoordinator.select(
                    model: model,
                    conversationID: conversationId,
                    currentConversationModel: { conversationID in
                        conversationStore.conversation(for: conversationID)?.model
                    },
                    persistConversationModel: { model, conversationID in
                        conversationStore.updateModel(model, for: conversationID)
                    },
                    applyGlobalModel: { model in
                        connectivityService.selectedModel = model
                        aiService.selectedModel = model
                    }
                )
            }
        }

    #endif
#endif
