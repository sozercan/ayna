import Foundation
import SwiftUI

enum SettingsTab: Hashable {
    case general
    case models
    case mcp
    case llama
}

@MainActor
final class SettingsRouter: ObservableObject {
    static let shared = SettingsRouter()

    @Published private(set) var requestedTab: SettingsTab?

    private init() {}

    func route(to tab: SettingsTab) {
        updateRequestedTab(tab)
    }

    func consumeRequestedTab() -> SettingsTab? {
        guard let tab = requestedTab else { return nil }
        requestedTab = nil
        return tab
    }

    private func updateRequestedTab(_ tab: SettingsTab) {
        requestedTab = nil
        requestedTab = tab
    }
}

extension View {
    func routeSettings(to tab: SettingsTab) -> some View {
        simultaneousGesture(
            TapGesture().onEnded {
                SettingsRouter.shared.route(to: tab)
            },
        )
    }
}
