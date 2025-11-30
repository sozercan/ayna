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
    
    var body: some View {
        List {
            if connectivityService.availableModels.isEmpty {
                Text("No models available. Sync with iPhone.")
                    .foregroundColor(.secondary)
            } else {
                ForEach(connectivityService.availableModels, id: \.self) { model in
                    Button {
                        connectivityService.selectedModel = model
                        openAIService.selectedModel = model
                        dismiss()
                    } label: {
                        HStack {
                            Text(model)
                                .font(.body)
                            Spacer()
                            if model == connectivityService.selectedModel {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Models")
    }
}

#endif
