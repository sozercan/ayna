//
//  WatchModelSelectionView.swift
//  Ayna Watch App
//
//  Created on 11/29/25.
//

#if os(watchOS)

    import SwiftUI

    struct WatchModelSelectionView: View {
        @Environment(\.dismiss) private var dismiss
        @EnvironmentObject var connectivityService: WatchConnectivityService
        @ObservedObject private var openAIService = OpenAIService.shared

        /// Filter models to only show those usable on watchOS
        private var watchUsableModels: [String] {
            connectivityService.availableModels.filter { model in
                // Filter out AIKit and Apple Intelligence - they can't run on watchOS
                let provider = openAIService.modelProviders[model]
                return provider != .aikit && provider != .appleIntelligence
            }
        }

        /// Check if a model should show as selected
        private func isModelSelected(_ model: String) -> Bool {
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
                        .foregroundColor(.secondary)
                } else {
                    ForEach(watchUsableModels, id: \.self) { model in
                        Button {
                            connectivityService.selectedModel = model
                            openAIService.selectedModel = model
                            dismiss()
                        } label: {
                            HStack {
                                Text(model)
                                    .font(.body)
                                Spacer()
                                if isModelSelected(model) {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Models")
            .onAppear {
                // Auto-select if only one model available
                if watchUsableModels.count == 1, let onlyModel = watchUsableModels.first {
                    connectivityService.selectedModel = onlyModel
                    openAIService.selectedModel = onlyModel
                }
            }
        }
    }

#endif
