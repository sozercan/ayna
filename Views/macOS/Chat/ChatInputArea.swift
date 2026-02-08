//
//  ChatInputArea.swift
//  ayna
//
//  Extracted from MacChatView.swift - Chat input/composer area component
//

import AppKit
import SwiftUI

/// The chat input/composer area including text editor, attachments, and model selector
struct ChatInputArea: View {
    @Binding var messageText: String
    @Binding var isComposerFocused: Bool
    @Binding var attachedFiles: [URL]
    @Binding var attachedAppContent: AppContent?
    @Binding var selectedModels: Set<String>
    @Binding var selectedModel: String
    @Binding var showModelSelector: Bool
    @Binding var isToolSectionExpanded: Bool

    let isGenerating: Bool
    let composerModelLabel: String
    let onSendMessage: () -> Void
    let onAttachFile: () -> Void
    let onShowAppContentPicker: () -> Void
    let onToggleModelSelection: (String) -> Void
    let onClearMultiSelection: () -> Void
    let onRemoveFile: (URL) -> Void
    var onRemoveAppContent: (() -> Void)?

    @ObservedObject private var aiService = AIService.shared

    var body: some View {
        VStack(spacing: Spacing.sm) {
            MCPToolSummaryView(isExpanded: $isToolSectionExpanded)

            // Attached files preview
            if !attachedFiles.isEmpty {
                attachedFilesView
            }

            // Attached app content preview
            if let appContent = attachedAppContent {
                attachedAppContentView(appContent: appContent)
            }

            // Main input row
            HStack(spacing: 0) {
                textEditorWithAttachButton
                modelSelectorButton
                sendButton
            }
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Spacing.CornerRadius.pill + Spacing.CornerRadius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: Spacing.CornerRadius.pill + Spacing.CornerRadius.sm)
                    .stroke(Theme.border, lineWidth: Spacing.Border.hairline)
            )
            .shadow(color: Theme.shadow.opacity(0.35), radius: Spacing.Shadow.radiusStandard, x: 0, y: Spacing.Shadow.offsetY)
            .padding(.horizontal, Spacing.contentPadding)
        }
        .padding(.top, Spacing.sm)
        .padding(.bottom, Spacing.composerBottomPadding)
        .background(.ultraThinMaterial)
    }

    // MARK: - Attached Files View

    private var attachedFilesView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.sm) {
                ForEach(attachedFiles, id: \.self) { fileURL in
                    AttachedFileRow(fileURL: fileURL) {
                        onRemoveFile(fileURL)
                    }
                }
            }
            .padding(.horizontal, Spacing.contentPadding)
        }
    }

    // MARK: - Attached App Content View

    private func attachedAppContentView(appContent: AppContent) -> some View {
        HStack(spacing: Spacing.sm) {
            // App icon
            if let icon = appContent.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 20, height: 20)
            } else {
                Image(systemName: "app.fill")
                    .frame(width: 20, height: 20)
                    .foregroundStyle(Theme.textSecondary)
            }

            // App name and window title
            VStack(alignment: .leading, spacing: 2) {
                Text(appContent.appName)
                    .font(Typography.captionBold)
                    .foregroundStyle(Theme.textPrimary)

                if let windowTitle = appContent.windowTitle, !windowTitle.isEmpty {
                    Text(windowTitle)
                        .font(Typography.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Content type badge
            Text(appContent.contentType.displayName)
                .font(Typography.footnote)
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, Spacing.xs)
                .padding(.vertical, 2)
                .background(Theme.backgroundTertiary)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            // Remove button
            Button {
                if let onRemove = onRemoveAppContent {
                    onRemove()
                } else {
                    attachedAppContent = nil
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: Typography.IconSize.md))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove app content")
        }
        .padding(Spacing.sm)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Spacing.CornerRadius.md))
        .padding(.horizontal, Spacing.contentPadding)
    }

    // MARK: - Text Editor with Attach Button

    private var textEditorWithAttachButton: some View {
        ZStack(alignment: .bottomLeading) {
            DynamicTextEditor(
                text: $messageText,
                isFirstResponder: $isComposerFocused,
                onSubmit: onSendMessage,
                accessibilityIdentifier: TestIdentifiers.ChatComposer.textEditor
            )
            .frame(height: calculateTextHeight())
            .font(Typography.body)
            .scrollContentBackground(.hidden)
            .padding(.leading, 48)
            .padding(.trailing, Spacing.md)
            .padding(.vertical, Spacing.md)
            .background(.clear)

            // Attach menu button
            Menu {
                Button {
                    onAttachFile()
                } label: {
                    Label("Attach Files...", systemImage: "doc")
                }

                Button {
                    onShowAppContentPicker()
                } label: {
                    Label("Attach from App...", systemImage: "macwindow")
                }
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: Typography.IconSize.xl))
                    .foregroundStyle(Theme.textSecondary.opacity(0.7))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Attach")
            .padding(.leading, Spacing.sm)
            .padding(.bottom, Spacing.sm)
        }
    }

    // MARK: - Model Selector Button

    private var modelSelectorButton: some View {
        Button(action: { showModelSelector.toggle() }) {
            HStack(spacing: Spacing.xxs) {
                Divider()
                    .frame(height: 24)
                    .padding(.leading, Spacing.sm)

                if selectedModels.count > 1 {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: Typography.Size.caption))
                        .foregroundStyle(Theme.accent)
                    Text("\(selectedModels.count) models")
                        .font(Typography.modelName)
                        .foregroundStyle(Theme.accent)
                } else {
                    Text(composerModelLabel)
                        .font(Typography.modelName)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: Typography.Size.xs))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, Spacing.md)
            .frame(height: calculateTextHeight() + Spacing.xxl)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .popover(isPresented: $showModelSelector) {
            modelSelectorPopover
        }
    }

    private var modelSelectorPopover: some View {
        ModelSelectorPopover(
            selectedModels: $selectedModels,
            selectedModel: $selectedModel,
            onToggleModel: onToggleModelSelection,
            onClearMultiSelection: onClearMultiSelection
        )
    }

    // MARK: - Send Button

    private var sendButton: some View {
        Button(action: onSendMessage) {
            ZStack {
                if isGenerating {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: Typography.IconSize.xl))
                        .foregroundStyle(Theme.accent)
                        .symbolEffect(.pulse, value: isGenerating)
                } else {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: Typography.IconSize.xl))
                        .foregroundStyle(messageText.isEmpty ? Theme.textSecondary.opacity(0.5) : Theme.accent)
                }
            }
        }
        .buttonStyle(.plain)
        .allowsHitTesting(isGenerating || !messageText.isEmpty)
        .accessibilityIdentifier(TestIdentifiers.ChatComposer.sendButton)
        .padding(.horizontal, Spacing.md)
        .frame(height: calculateTextHeight() + Spacing.xxl)
    }

    // MARK: - Text Height Calculation

    private func calculateTextHeight() -> CGFloat {
        let baseHeight: CGFloat = 22
        let maxHeight: CGFloat = 220

        if messageText.isEmpty {
            return baseHeight
        }

        let availableWidth: CGFloat = 600
        let font = NSFont.systemFont(ofSize: 15)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]

        let boundingRect = (messageText as NSString).boundingRect(
            with: NSSize(width: availableWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )

        let calculatedHeight = ceil(boundingRect.height) + 4
        return min(max(calculatedHeight, baseHeight), maxHeight)
    }
}

/// Row for displaying an attached file
struct AttachedFileRow: View {
    let fileURL: URL
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: Spacing.sm) {
            // Show image thumbnail if it's an image file
            if let image = NSImage(contentsOf: fileURL) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: Spacing.CornerRadius.sm))
            } else {
                Image(systemName: "doc.fill")
                    .font(.system(size: Typography.IconSize.lg))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 48, height: 48)
            }

            VStack(alignment: .leading, spacing: Spacing.xxxs) {
                Text(fileURL.lastPathComponent)
                    .font(Typography.caption)
                    .lineLimit(1)
                if let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file))
                        .font(Typography.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: Typography.IconSize.md))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove attachment")
        }
        .padding(Spacing.sm)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Spacing.CornerRadius.md))
    }
}
