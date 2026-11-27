// swiftformat:options --ifdef no-indent
#if os(macOS)

import SwiftUI

struct MacSettingsView: View {
    @ObservedObject private var aiService = AIService.shared
    @ObservedObject private var settingsRouter = SettingsRouter.shared
    @State private var selectedTab: SettingsTab = SettingsRouter.shared.consumeRequestedTab() ?? .general

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }
                .tag(SettingsTab.general)

            APISettingsView()
                .tabItem {
                    Label("Models", systemImage: "cpu")
                }
                .tag(SettingsTab.models)

            ToolsSettingsView()
                .tabItem {
                    Label("Tools", systemImage: "wrench.and.screwdriver")
                }
                .tag(SettingsTab.mcp)

            AgentsSettingsSection()
                .tabItem {
                    Label("Agents", systemImage: "brain")
                }
                .tag(SettingsTab.agents)

            MemorySettingsSection()
                .tabItem {
                    Label("Memory", systemImage: "memorychip")
                }
                .tag(SettingsTab.memory)
        }
        .frame(width: 650, height: 500)
        .onReceive(settingsRouter.$requestedTab) { tab in
            guard let tab else { return }
            selectedTab = tab
            _ = settingsRouter.consumeRequestedTab()
        }
    }
}

#Preview {
    MacSettingsView()
}

#endif
