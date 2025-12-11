//
//  GeneralSettingsSection.swift
//  ayna
//
//  Extracted from MacSettingsView.swift
//

import SwiftUI

/// General app settings including behavior, system prompt, and image generation
struct GeneralSettingsSection: View {
    @AppStorage("autoGenerateTitle") private var autoGenerateTitle = true
    @State private var globalSystemPrompt = AppPreferences.globalSystemPrompt
    @State private var attachFromAppEnabled = AppPreferences.attachFromAppEnabled
    @ObservedObject private var openAIService = OpenAIService.shared
    @EnvironmentObject private var conversationManager: ConversationManager

    var body: some View {
        Form {
            Section {
                Toggle("Auto-Generate Titles", isOn: $autoGenerateTitle)
                    .help("Automatically generate conversation titles from first message")
            } header: {
                Text("Behavior")
            }

            systemPromptSection
            imageGenerationSection
            attachFromAppSection
            dataSection
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - System Prompt Section

    private var systemPromptSection: some View {
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
    }

    // MARK: - Image Generation Section

    private var imageGenerationSection: some View {
        Section {
            Picker("Image Size", selection: $openAIService.imageSize) {
                Text("1024×1024 (Square)").tag("1024x1024")
                Text("1024×1536 (Portrait)").tag("1024x1536")
                Text("1536×1024 (Landscape)").tag("1536x1024")
            }
            .help("Resolution for generated images")

            Picker("Image Quality", selection: $openAIService.imageQuality) {
                Text("Low").tag("low")
                Text("Medium").tag("medium")
                Text("High").tag("high")
            }
            .help("Quality level affects generation time and cost")

            Picker("Output Format", selection: $openAIService.outputFormat) {
                Text("PNG").tag("png")
                Text("JPEG").tag("jpeg")
            }
            .help("Image file format")

            HStack {
                Text("Compression")
                Spacer()
                Slider(value: Binding(
                    get: { Double(openAIService.outputCompression) },
                    set: { openAIService.outputCompression = Int($0) }
                ), in: 0 ... 100, step: 10)
                    .frame(width: 150)
                Text("\(openAIService.outputCompression)%")
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 45, alignment: .trailing)
            }
            .help("Image compression level (100 = no compression)")
        } header: {
            Text("Image Generation")
        } footer: {
            Text("These settings apply when using image generation models")
                .font(Typography.caption)
        }
    }

    // MARK: - Attach from App Section

    private var attachFromAppSection: some View {
        AttachFromAppSettingsSection(isEnabled: $attachFromAppEnabled)
    }

    // MARK: - Data Section

    private var dataSection: some View {
        Section {
            Button("Clear All Conversations") {
                conversationManager.clearAllConversations()
            }
            .foregroundStyle(.red)
        } header: {
            Text("Data")
        }
    }
}
