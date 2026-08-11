//
//  AIService+ModelIdentity.swift
//  ayna
//

import Foundation

enum ModelRenameResult: Equatable {
    case unchanged
    case renamed
    case sourceMissing
    case destinationExists
}

@MainActor
extension AIService {
    @discardableResult
    func renameConfiguredModel(from oldName: String, to newName: String) -> ModelRenameResult {
        guard let modelIndex = customModels.firstIndex(of: oldName) else { return .sourceMissing }
        guard oldName != newName else { return .unchanged }
        guard !customModels.contains(newName) else { return .destinationExists }

        customModels[modelIndex] = newName
        modelProviders = modelProviders.rekeyingValue(from: oldName, to: newName)
        modelEndpoints = modelEndpoints.rekeyingValue(from: oldName, to: newName)
        modelAPIKeys = modelAPIKeys.rekeyingValue(from: oldName, to: newName)
        modelEndpointTypes = modelEndpointTypes.rekeyingValue(from: oldName, to: newName)
        modelReasoningConfigurations = modelReasoningConfigurations.rekeyingValue(
            from: oldName,
            to: newName
        )

        if selectedModel == oldName {
            selectedModel = newName
        }

        return .renamed
    }

    func removeConfiguredModel(_ model: String) {
        customModels.removeAll { $0 == model }
        modelProviders.removeValue(forKey: model)
        modelEndpoints.removeValue(forKey: model)
        modelAPIKeys.removeValue(forKey: model)
        modelEndpointTypes.removeValue(forKey: model)
        modelReasoningConfigurations.removeValue(forKey: model)

        if selectedModel == model {
            selectedModel = customModels.first ?? ""
        }
    }
}

private extension Dictionary where Key == String {
    func rekeyingValue(from oldKey: String, to newKey: String) -> Self {
        var values = self
        let movedValue = values.removeValue(forKey: oldKey)
        values.removeValue(forKey: newKey)
        if let movedValue {
            values[newKey] = movedValue
        }
        return values
    }
}
