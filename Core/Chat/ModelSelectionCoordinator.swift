//
//  ModelSelectionCoordinator.swift
//  ayna
//
//  Extracted from MacChatView/MacNewChatView - handles model selection logic
//

import Foundation

/// Coordinates model selection state and validation across chat views
@MainActor
final class ModelSelectionCoordinator {

    // MARK: - Model Resolution

    /// Resolves the active model to use for sending a message
    /// - Parameters:
    ///   - selectedModel: The currently selected model in the UI
    ///   - conversationModel: The model stored in the conversation
    ///   - globalModel: The globally selected model from AIService
    /// - Returns: The model to use, or nil if none available
    static func resolveModelForSending(
        selectedModel: String,
        conversationModel: String?,
        globalModel: String
    ) -> String? {
        let trimmed = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }

        if let convModel = conversationModel?.trimmingCharacters(in: .whitespacesAndNewlines),
           !convModel.isEmpty {
            return convModel
        }

        let trimmedGlobal = globalModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedGlobal.isEmpty ? nil : trimmedGlobal
    }

    // MARK: - Multi-Model Selection

    /// Toggles a model in the selection set, handling capability type constraints
    /// - Parameters:
    ///   - model: The model to toggle
    ///   - selectedModels: The current set of selected models
    ///   - multiModelEnabled: Whether multi-model selection is enabled
    ///   - getCapability: Closure to get a model's capability type
    /// - Returns: Updated selection set and primary model
    static func toggleModelSelection(
        model: String,
        selectedModels: Set<String>,
        multiModelEnabled: Bool,
        maxModels: Int = 4,
        getCapability: (String) -> AIService.ModelCapability
    ) -> (selectedModels: Set<String>, primaryModel: String?) {
        var updatedSelection = selectedModels

        if !multiModelEnabled {
            // Single-select mode: always replace selection
            return (selectedModels: [model], primaryModel: model)
        }

        // Multi-select mode
        if updatedSelection.contains(model) {
            updatedSelection.remove(model)
        } else {
            // Check capability type compatibility
            if let firstSelected = updatedSelection.first {
                let selectedCapability = getCapability(firstSelected)
                let modelCapability = getCapability(model)
                if modelCapability != selectedCapability {
                    // Clear existing and start fresh with new type
                    updatedSelection.removeAll()
                }
            }

            // Enforce max limit
            if updatedSelection.count < maxModels {
                updatedSelection.insert(model)
            }
        }

        // Determine primary model
        let primaryModel: String?
        if updatedSelection.count == 1 {
            primaryModel = updatedSelection.first
        } else {
            primaryModel = nil
        }

        return (selectedModels: updatedSelection, primaryModel: primaryModel)
    }

    // MARK: - Normalized Model

    /// Returns the normalized (first) model from a selection set
    static func normalizedSelectedModel(from selectedModels: Set<String>) -> String {
        selectedModels.first ?? ""
    }

    /// Returns the display label for the model selector button
    static func composerModelLabel(
        selectedModels: Set<String>,
        selectedModel: String,
        getShortName: (String) -> String
    ) -> String {
        if let first = selectedModels.first {
            return getShortName(first)
        } else if !selectedModel.isEmpty {
            return getShortName(selectedModel)
        }
        return "Select model"
    }
}
