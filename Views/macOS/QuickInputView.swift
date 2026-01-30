//
//  QuickInputView.swift
//  ayna
//
//  SwiftUI view displayed inside the floating panel for "Attach from App".
//

#if os(macOS)
    import SwiftUI

    /// The main view displayed in the floating quick input panel.
    struct QuickInputView: View {
        /// The extracted content result
        let contentResult: AppContentResult

        /// Callback when user submits a question
        let onSubmit: (String) -> Void

        /// Callback to dismiss the panel
        let onDismiss: () -> Void

        /// Callback to open main window with question
        let onOpenMainWindow: (String) -> Void

        /// Callback to request accessibility permission
        let onRequestPermission: () -> Void

        /// The user's question input
        @State private var userQuestion: String = ""

        /// Whether content extraction is in progress
        @State private var isLoading: Bool = false

        /// Focus state for the text field
        @FocusState private var isTextFieldFocused: Bool

        var body: some View {
            VStack(alignment: .leading, spacing: Spacing.md) {
                // Header
                headerView

                Divider()

                // Content area based on result
                contentArea

                Divider()

                // Input area
                inputArea
            }
            .padding(Spacing.lg)
            .frame(width: 380, height: 280)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: Spacing.CornerRadius.xl))
            .onAppear {
                isTextFieldFocused = true
            }
        }

        // MARK: - Header

        private var headerView: some View {
            HStack(spacing: Spacing.sm) {
                // App icon
                if let content = contentResult.content {
                    if let icon = content.appIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 32, height: 32)
                            .clipShape(RoundedRectangle(cornerRadius: Spacing.CornerRadius.sm))
                    } else {
                        Image(systemName: "app.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 32, height: 32)
                    }

                    VStack(alignment: .leading, spacing: Spacing.xxxs) {
                        Text(content.appName)
                            .font(Typography.headline)
                            .lineLimit(1)

                        if let windowTitle = content.windowTitle {
                            Text(windowTitle)
                                .font(Typography.caption)
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                        }
                    }
                } else {
                    Image(systemName: "questionmark.app")
                        .font(.system(size: 24))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 32, height: 32)

                    Text("Attach from App")
                        .font(Typography.headline)
                }

                Spacer()

                // Close button
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                .keyboardShortcut(.escape, modifiers: [])
            }
        }

        // MARK: - Content Area

        @ViewBuilder
        private var contentArea: some View {
            switch contentResult {
            case let .success(content):
                successView(content: content)
            case .permissionDenied:
                permissionDeniedView
            case .noFocusedApp:
                noFocusedAppView
            case .noContentAvailable:
                noContentView
            case let .extractionFailed(reason):
                errorView(reason: reason)
            }
        }

        private func successView(content: AppContent) -> some View {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                // Content type badge
                HStack {
                    Label(content.contentType.displayName, systemImage: iconForContentType(content.contentType))
                        .font(Typography.caption)
                        .foregroundStyle(Theme.textSecondary)

                    if content.isTruncated {
                        Text("(\(content.originalLength) chars)")
                            .font(Typography.micro)
                            .foregroundStyle(Theme.textTertiary)
                    }

                    Spacer()
                }

                // Content preview
                ScrollView {
                    Text(content.forPreview.content)
                        .font(Typography.code)
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                .padding(Spacing.sm)
                .background(Theme.codeBackground)
                .clipShape(RoundedRectangle(cornerRadius: Spacing.CornerRadius.sm))
            }
        }

        private var permissionDeniedView: some View {
            VStack(spacing: Spacing.md) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 36))
                    .foregroundStyle(Theme.statusConnecting)

                Text("Accessibility Permission Required")
                    .font(Typography.subheadline)
                    .fontWeight(.medium)

                Text("Ayna needs accessibility access to capture content from other apps.")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)

                Button {
                    onRequestPermission()
                } label: {
                    Label("Grant Permission", systemImage: "gearshape")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.md)
        }

        private var noFocusedAppView: some View {
            VStack(spacing: Spacing.md) {
                Image(systemName: "macwindow")
                    .font(.system(size: 36))
                    .foregroundStyle(Theme.textSecondary)

                Text("No Application Focused")
                    .font(Typography.subheadline)
                    .fontWeight(.medium)

                Text("Focus on an app window and try again.")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.md)
        }

        private var noContentView: some View {
            VStack(spacing: Spacing.md) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 36))
                    .foregroundStyle(Theme.textSecondary)

                Text("No Content Captured")
                    .font(Typography.subheadline)
                    .fontWeight(.medium)

                Text("Try selecting some text in the app, or ask a question without context.")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.md)
        }

        private func errorView(reason: String) -> some View {
            VStack(spacing: Spacing.md) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 36))
                    .foregroundStyle(Theme.statusError)

                Text("Extraction Failed")
                    .font(Typography.subheadline)
                    .fontWeight(.medium)

                Text(reason)
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.md)
        }

        // MARK: - Input Area

        private var inputArea: some View {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                // Text input
                HStack(spacing: Spacing.sm) {
                    TextField("Ask about this content...", text: $userQuestion, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(Typography.body)
                        .lineLimit(1 ... 3)
                        .focused($isTextFieldFocused)
                        .onSubmit {
                            submitQuestion()
                        }

                    // Submit button
                    Button {
                        submitQuestion()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(userQuestion.isEmpty ? Theme.textTertiary : Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .disabled(userQuestion.isEmpty)
                    .accessibilityLabel("Send")
                }
                .padding(Spacing.sm)
                .background(Theme.backgroundSecondary)
                .clipShape(RoundedRectangle(cornerRadius: Spacing.CornerRadius.md))

                // Keyboard hints
                HStack(spacing: Spacing.lg) {
                    keyboardHint("↵", description: "Send")
                    keyboardHint("⌘↵", description: "Send & Open")
                    keyboardHint("⎋", description: "Close")
                }
                .font(Typography.micro)
                .foregroundStyle(Theme.textTertiary)
            }
        }

        private func keyboardHint(_ key: String, description: String) -> some View {
            HStack(spacing: Spacing.xxxs) {
                Text(key)
                    .fontWeight(.medium)
                    .padding(.horizontal, Spacing.xxs)
                    .padding(.vertical, Spacing.xxxs)
                    .background(Theme.backgroundTertiary)
                    .clipShape(RoundedRectangle(cornerRadius: Spacing.CornerRadius.xs))

                Text(description)
            }
        }

        // MARK: - Helpers

        private func iconForContentType(_ type: AppContent.ContentType) -> String {
            switch type {
            case .selectedText: "text.cursor"
            case .documentContent: "doc.text"
            case .terminalOutput: "terminal"
            case .browserURL: "globe"
            case .generic: "doc"
            }
        }

        private func submitQuestion() {
            let trimmed = userQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }

            onSubmit(trimmed)
        }
    }

    // MARK: - Keyboard Shortcuts

    extension QuickInputView {
        /// Handles keyboard shortcuts within the view
        func handleKeyboardShortcut(_ event: NSEvent) -> Bool {
            // ⌘⏎ - Submit and open main window
            if event.modifierFlags.contains(.command), event.keyCode == 36 { // Return
                let trimmed = userQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    onOpenMainWindow(trimmed)
                }
                return true
            }

            return false
        }
    }

    // MARK: - Preview

    #Preview {
        QuickInputView(
            contentResult: .success(AppContent(
                appName: "Terminal",
                appIcon: nil,
                bundleIdentifier: "com.apple.Terminal",
                windowTitle: "~/projects — bash",
                content: "$ git status\nOn branch main\nYour branch is up to date with 'origin/main'.\n\nnothing to commit, working tree clean",
                contentType: .terminalOutput,
                isTruncated: false,
                originalLength: 120
            )),
            onSubmit: { _ in },
            onDismiss: {},
            onOpenMainWindow: { _ in },
            onRequestPermission: {}
        )
    }

    #Preview("Permission Denied") {
        QuickInputView(
            contentResult: .permissionDenied,
            onSubmit: { _ in },
            onDismiss: {},
            onOpenMainWindow: { _ in },
            onRequestPermission: {}
        )
    }

    #Preview("No Content") {
        QuickInputView(
            contentResult: .noContentAvailable,
            onSubmit: { _ in },
            onDismiss: {},
            onOpenMainWindow: { _ in },
            onRequestPermission: {}
        )
    }
#endif
