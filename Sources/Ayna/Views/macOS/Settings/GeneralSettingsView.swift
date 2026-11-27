// swiftformat:options --ifdef no-indent
#if os(macOS)

import SwiftUI

struct GeneralSettingsView: View {
    @AppStorage("autoGenerateTitle") private var autoGenerateTitle = true
    @State private var globalSystemPrompt = AppPreferences.globalSystemPrompt
    @State private var attachFromAppEnabled = AppPreferences.attachFromAppEnabled
    @State private var multiModelSelectionEnabled = AppPreferences.multiModelSelectionEnabled
    @ObservedObject private var aiService = AIService.shared
    @EnvironmentObject private var conversationManager: ConversationManager

    var body: some View {
        Form {
            Section {
                Toggle("Auto-Generate Titles", isOn: $autoGenerateTitle)
                    .help("Automatically generate conversation titles from first message")

                Toggle("Multi-Model Selection", isOn: $multiModelSelectionEnabled)
                    .help("Allow selecting multiple models to compare responses side-by-side")
                    .onChange(of: multiModelSelectionEnabled) { _, newValue in
                        AppPreferences.multiModelSelectionEnabled = newValue
                    }
            } header: {
                Text("Behavior")
            }

            Section {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("Default System Prompt")
                        .font(Typography.subheadline)
                        .foregroundStyle(Theme.textSecondary)

                    TextEditor(text: $globalSystemPrompt)
                        .font(Typography.body)
                        .frame(minHeight: 80, maxHeight: 120)
                        .scrollContentBackground(.hidden)
                        .padding(Spacing.sm)
                        .background(Theme.background)
                        .clipShape(RoundedRectangle(cornerRadius: Spacing.CornerRadius.sm))
                        .overlay(
                            RoundedRectangle(cornerRadius: Spacing.CornerRadius.sm)
                                .stroke(Theme.separator, lineWidth: Spacing.Border.standard)
                        )
                        .accessibilityIdentifier("settings.globalSystemPrompt.editor")
                        .onChange(of: globalSystemPrompt) { _, newValue in
                            AppPreferences.globalSystemPrompt = newValue
                        }
                }
            } header: {
                Text("System Prompt")
            } footer: {
                Text("This prompt is sent at the start of every conversation unless overridden per-conversation. Leave empty for no default prompt.")
                    .font(.caption)
            }

            Section {
                Picker("Image Size", selection: $aiService.imageSize) {
                    Text("1024×1024 (Square)").tag("1024x1024")
                    Text("1024×1536 (Portrait)").tag("1024x1536")
                    Text("1536×1024 (Landscape)").tag("1536x1024")
                }
                .help("Resolution for generated images")

                Picker("Image Quality", selection: $aiService.imageQuality) {
                    Text("Low").tag("low")
                    Text("Medium").tag("medium")
                    Text("High").tag("high")
                }
                .help("Quality level affects generation time and cost")

                if aiService.hasImageModelWithOutputOptions {
                    Picker("Output Format", selection: $aiService.outputFormat) {
                        Text("PNG").tag("png")
                        Text("JPEG").tag("jpeg")
                    }
                    .help("Image file format (GPT Image models)")

                    if aiService.outputFormat != "png" {
                        HStack {
                            Text("Compression")
                            Spacer()
                            Slider(value: Binding(
                                get: { Double(aiService.outputCompression) },
                                set: { aiService.outputCompression = Int($0) }
                            ), in: 0 ... 100, step: 10)
                                .frame(width: 150)
                            Text("\(aiService.outputCompression)%")
                                .foregroundStyle(Theme.textSecondary)
                                .frame(width: 45, alignment: .trailing)
                        }
                        .help("JPEG compression level (100 = no compression)")
                    }
                }
            } header: {
                Text("Image Generation")
            } footer: {
                Text("These settings apply when using image generation models")
                    .font(Typography.caption)
            }

            AttachFromAppSettingsSection(isEnabled: $attachFromAppEnabled)

            Section {
                Button("Clear All Conversations") {
                    conversationManager.clearAllConversations()
                }
                .foregroundStyle(.red)
            } header: {
                Text("Data")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct WebSearchSettingsSection: View {
    @ObservedObject private var tavilyService = TavilyService.shared
    @State private var showAPIKey = false

    var body: some View {
        Section {
            Toggle("Enable Web Search", isOn: $tavilyService.isEnabled)
                .help("Allow models to search the web for current information")
                .accessibilityIdentifier("settings.webSearch.enableToggle")

            if tavilyService.isEnabled {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: tavilyService.isConfigured ? "bolt.fill" : "magnifyingglass")
                        .foregroundStyle(Theme.accent)
                        .font(Typography.caption)
                    Text("Using: \(tavilyService.isConfigured ? "Tavily" : "DuckDuckGo")")
                        .font(Typography.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }

                VStack(alignment: .leading, spacing: Spacing.sm) {
                    HStack {
                        Text("Tavily API Key")
                            .font(Typography.subheadline)
                        Spacer()
                        if tavilyService.isConfigured {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Theme.statusConnected)
                                .font(Typography.caption)
                        } else {
                            Text("Optional")
                                .font(Typography.micro)
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.horizontal, Spacing.xs)
                                .padding(.vertical, Spacing.xxxs)
                                .background(Color.secondary.opacity(0.1))
                                .clipShape(.rect(cornerRadius: Spacing.CornerRadius.xs))
                        }
                    }

                    HStack(spacing: Spacing.sm) {
                        if showAPIKey {
                            TextField("tvly-...", text: $tavilyService.apiKey)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("settings.webSearch.apiKey.textField")
                        } else {
                            SecureField("tvly-...", text: $tavilyService.apiKey)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("settings.webSearch.apiKey.secureField")
                        }

                        Button(action: {
                            showAPIKey.toggle()
                        }) {
                            Image(systemName: showAPIKey ? "eye.slash.fill" : "eye.fill")
                                .font(.system(size: Typography.Size.sm))
                                .foregroundStyle(Theme.textSecondary)
                                .frame(width: Spacing.Component.avatarSmall, height: Spacing.Component.avatarSmall)
                                .background(Color.secondary.opacity(0.1))
                                .clipShape(.rect(cornerRadius: Spacing.CornerRadius.sm))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(showAPIKey ? "Hide API key" : "Show API key")
                        .accessibilityIdentifier("settings.webSearch.apiKey.toggleVisibility")
                    }

                    HStack(spacing: Spacing.xxs) {
                        Text("Get your API key at")
                            .font(Typography.caption)
                            .foregroundStyle(.tertiary)
                        Link("tavily.com", destination: URL(string: "https://tavily.com")!)
                            .font(Typography.caption)
                    }
                }
                .padding(.top, Spacing.xxs)
            }
        } header: {
            Text("Web Search")
        } footer: {
            Text("Web search works without an API key using DuckDuckGo. For higher quality results with AI-generated answers, configure a Tavily API key.")
                .font(Typography.caption)
        }
    }
}

struct AttachFromAppSettingsSection: View {
    @Binding var isEnabled: Bool
    @State private var accessibilityEnabled = AccessibilityService.shared.isEnabled

    var body: some View {
        Section {
            Toggle("Enable Attach from App", isOn: $isEnabled)
                .help("Use a global hotkey to capture context from any app and ask questions about it")
                .accessibilityIdentifier("settings.attachFromApp.enableToggle")
                .onChange(of: isEnabled) { _, newValue in
                    AppPreferences.attachFromAppEnabled = newValue

                    if newValue {
                        do {
                            try GlobalHotkeyService.shared.registerSaved()
                            AccessibilityService.shared.startMonitoring()
                        } catch {
                            DiagnosticsLogger.log(
                                .attachFromApp,
                                level: .error,
                                message: "Failed to register hotkey",
                                metadata: ["error": error.localizedDescription]
                            )
                        }
                    } else {
                        GlobalHotkeyService.shared.unregister()
                        AccessibilityService.shared.stopMonitoring()
                    }
                }

            if isEnabled {
                LabeledContent("Hotkey") {
                    HotkeyRecorderView()
                }
                .accessibilityIdentifier("settings.attachFromApp.hotkey")

                LabeledContent("Accessibility") {
                    if accessibilityEnabled {
                        Label("Enabled", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Theme.statusConnected)
                            .font(Typography.caption)
                    } else {
                        Button {
                            AccessibilityService.shared.openAccessibilityPreferences()
                        } label: {
                            Label("Grant Permission", systemImage: "gearshape")
                        }
                        .buttonStyle(.link)
                        .font(Typography.caption)
                    }
                }
                .accessibilityIdentifier("settings.attachFromApp.accessibility")
            }
        } header: {
            Text("Attach from App")
        } footer: {
            Text("Press the hotkey anywhere to capture content from the focused app and ask questions about it. Requires Accessibility permission.")
                .font(Typography.caption)
        }
        .onAppear {
            accessibilityEnabled = AccessibilityService.shared.checkPermission(prompt: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .accessibilityPermissionChanged)) { notification in
            if let enabled = notification.userInfo?["enabled"] as? Bool {
                accessibilityEnabled = enabled
            }
        }
    }
}

#endif
