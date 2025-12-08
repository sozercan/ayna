//
//  SpotlightInputView.swift
//  ayna
//
//  Spotlight-style floating command bar for quick AI queries.
//

#if os(macOS)
    import SwiftUI

    /// State of the Spotlight input panel
    enum SpotlightPanelState {
        case quickChat // No context attached
        case pickingWindow // Window picker is expanded
        case withContext // Context attached, picker collapsed
        case previewExpanded // Context attached, preview expanded
    }

    /// The main Spotlight-style input view
    struct SpotlightInputView: View {
        /// Callback when user submits a question
        let onSubmit: (String, AppContentResult?) -> Void

        /// Callback to dismiss the panel
        let onDismiss: () -> Void

        /// State of the panel
        @State private var panelState: SpotlightPanelState = .quickChat

        /// The user's question input
        @State private var userQuestion: String = ""

        /// Attached content (if any)
        @State private var attachedContent: AppContentResult?

        /// Selected window info
        @State private var selectedWindow: AccessibilityService.WindowInfo?

        /// Available windows grouped by app
        @State private var windowGroups: [AccessibilityService.AppWindowGroup] = []

        /// Expanded apps in the picker
        @State private var expandedApps: Set<String> = []

        /// Loading state for content extraction
        @State private var isExtracting: Bool = false

        /// Focus state for the text field
        @FocusState private var isTextFieldFocused: Bool

        /// Error message to display
        @State private var errorMessage: String?

        /// Whether accessibility is enabled
        @State private var hasAccessibilityPermission: Bool = false

        var body: some View {
            VStack(spacing: 0) {
                // Input field
                inputField

                // Context area (picker or attached content)
                contextArea
            }
            .frame(width: 600)
            .background(
                VisualEffectBlur(material: .popover, blendingMode: .behindWindow)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
            .onAppear {
                // Delay focus slightly to ensure panel is ready
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isTextFieldFocused = true
                }
                checkAccessibilityAndLoadWindows()
            }
        }

        // MARK: - Input Field

        @ViewBuilder
        private var inputField: some View {
            HStack(spacing: Spacing.sm) {
                // Search icon
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)

                // Text field
                TextField(placeholderText, text: $userQuestion)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($isTextFieldFocused)
                    .onSubmit {
                        submitQuestion()
                    }

                // Send hint
                if !userQuestion.isEmpty {
                    Text("⏎")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.backgroundTertiary)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.md)
        }

        private var placeholderText: String {
            switch panelState {
            case .quickChat, .pickingWindow:
                "Ask anything..."
            case .withContext, .previewExpanded:
                if let content = attachedContent?.content {
                    "Ask about \(content.appName)..."
                } else {
                    "Ask anything..."
                }
            }
        }

        // MARK: - Context Area

        @ViewBuilder
        private var contextArea: some View {
            switch panelState {
            case .quickChat:
                attachButton
            case .pickingWindow:
                windowPicker
            case .withContext:
                attachedContextBar
            case .previewExpanded:
                attachedContextWithPreview
            }
        }

        // MARK: - Attach Button

        @ViewBuilder
        private var attachButton: some View {
            Button {
                // Check/prompt for accessibility permission when user clicks attach
                let hasPermission = AccessibilityService.shared.checkPermission(prompt: true)
                hasAccessibilityPermission = hasPermission

                withAnimation(.easeOut(duration: 0.2)) {
                    panelState = .pickingWindow
                }

                // Load windows (will show appropriate UI based on permission)
                if hasPermission {
                    loadWindows()
                } else {
                    windowGroups = []
                }
            } label: {
                HStack {
                    Image(systemName: "paperclip")
                        .font(.system(size: 14))
                    Text("Attach context...")
                        .font(.system(size: 13))
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
            }
            .buttonStyle(.plain)
            .background(Theme.backgroundSecondary.opacity(0.5))
        }

        // MARK: - Window Picker

        @ViewBuilder
        private var windowPicker: some View {
            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("Working with")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)

                    Text("(\(windowGroups.count) apps)")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)

                    Spacer()

                    Button("Cancel") {
                        withAnimation(.easeOut(duration: 0.2)) {
                            panelState = attachedContent != nil ? .withContext : .quickChat
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .background(Theme.backgroundSecondary.opacity(0.5))

                Divider()

                // Window list
                if windowGroups.isEmpty {
                    emptyWindowsView
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(windowGroups) { group in
                                appGroupRow(group)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .frame(minHeight: 100, maxHeight: 300)
                }
            }
        }

        @ViewBuilder
        private func appGroupRow(_ group: AccessibilityService.AppWindowGroup) -> some View {
            VStack(spacing: 0) {
                // App header row
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        if expandedApps.contains(group.id) {
                            expandedApps.remove(group.id)
                        } else {
                            expandedApps.insert(group.id)
                        }
                    }
                } label: {
                    HStack(spacing: Spacing.sm) {
                        // App icon
                        if let icon = group.appIcon {
                            Image(nsImage: icon)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 20, height: 20)
                        } else {
                            Image(systemName: "app.fill")
                                .frame(width: 20, height: 20)
                                .foregroundStyle(Theme.textSecondary)
                        }

                        // App name
                        Text(group.appName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)

                        Spacer()

                        // Expand indicator
                        Image(systemName: expandedApps.contains(group.id) ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.sm)
                    .background(
                        expandedApps.contains(group.id)
                            ? Theme.backgroundTertiary.opacity(0.5)
                            : Color.clear
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(minHeight: 32)

                // Windows (when expanded)
                if expandedApps.contains(group.id) {
                    ForEach(group.windows) { window in
                        windowRow(window)
                    }
                }
            }
        }

        @ViewBuilder
        private func windowRow(_ window: AccessibilityService.WindowInfo) -> some View {
            Button {
                selectWindow(window)
            } label: {
                HStack(spacing: Spacing.sm) {
                    // Indent + icon
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: 20)

                    Image(systemName: "doc")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 16)

                    // Window title
                    Text(window.title)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.xs)
                .background(Color.clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(
                Group {
                    if selectedWindow?.id == window.id {
                        Theme.accent.opacity(0.2)
                    }
                }
            )
        }

        @ViewBuilder
        private var emptyWindowsView: some View {
            VStack(spacing: Spacing.sm) {
                if !hasAccessibilityPermission {
                    // No accessibility permission
                    Image(systemName: "lock.shield")
                        .font(.system(size: 24))
                        .foregroundStyle(Theme.textTertiary)

                    Text("Accessibility Permission Required")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)

                    Text("Grant access to read window content")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)

                    Button("Open System Settings") {
                        AccessibilityService.shared.openAccessibilityPreferences()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(.top, Spacing.xs)
                } else {
                    // Has permission but no windows
                    Image(systemName: "macwindow")
                        .font(.system(size: 24))
                        .foregroundStyle(Theme.textTertiary)

                    Text("No windows available")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)

                    Text("Open an app window to attach context")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.xl)
        }

        // MARK: - Attached Context Bar

        @ViewBuilder
        private var attachedContextBar: some View {
            if let content = attachedContent?.content {
                HStack(spacing: Spacing.sm) {
                    // App icon
                    if let icon = content.appIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "app.fill")
                            .frame(width: 16, height: 16)
                            .foregroundStyle(Theme.textSecondary)
                    }

                    // App name and window
                    Text(content.appName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)

                    if let windowTitle = content.windowTitle {
                        Text("·")
                            .foregroundStyle(Theme.textTertiary)
                        Text(windowTitle)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()

                    // Expand button
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) {
                            panelState = .previewExpanded
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)

                    // Remove button
                    Button {
                        removeContext()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .background(Theme.backgroundSecondary.opacity(0.5))
            }
        }

        // MARK: - Attached Context with Preview

        @ViewBuilder
        private var attachedContextWithPreview: some View {
            if let content = attachedContent?.content {
                VStack(spacing: 0) {
                    // Header bar
                    HStack(spacing: Spacing.sm) {
                        // App icon
                        if let icon = content.appIcon {
                            Image(nsImage: icon)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 16, height: 16)
                        }

                        Text(content.appName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)

                        if let windowTitle = content.windowTitle {
                            Text("·")
                                .foregroundStyle(Theme.textTertiary)
                            Text(windowTitle)
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        // Collapse button
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) {
                                panelState = .withContext
                            }
                        } label: {
                            Image(systemName: "chevron.up")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .buttonStyle(.plain)

                        // Remove button
                        Button {
                            removeContext()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.sm)
                    .background(Theme.backgroundSecondary.opacity(0.5))

                    // Content preview
                    ScrollView {
                        Text(content.forPreview.content)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.textPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Spacing.sm)
                    }
                    .frame(maxHeight: 160)
                    .background(Theme.codeBackground)
                }
            }
        }

        // MARK: - Actions

        private func checkAccessibilityAndLoadWindows() {
            hasAccessibilityPermission = AccessibilityService.shared.checkPermission(prompt: false)

            if hasAccessibilityPermission {
                loadWindows()
            } else {
                windowGroups = []
                DiagnosticsLogger.log(
                    .workWithApps,
                    level: .info,
                    message: "Accessibility permission not granted - cannot list windows"
                )
            }
        }

        private func loadWindows() {
            windowGroups = AccessibilityService.shared.getAllWindowsGroupedByApp()

            DiagnosticsLogger.log(
                .workWithApps,
                level: .info,
                message: "Loaded windows for picker",
                metadata: [
                    "appCount": "\(windowGroups.count)",
                    "totalWindows": "\(windowGroups.reduce(0) { $0 + $1.windows.count })"
                ]
            )

            // Auto-expand first app with windows
            if let firstGroup = windowGroups.first {
                expandedApps.insert(firstGroup.id)
            }
        }

        private func selectWindow(_ window: AccessibilityService.WindowInfo) {
            selectedWindow = window
            isExtracting = true

            Task {
                let result = await AccessibilityService.shared.extractContent(from: window)
                await MainActor.run {
                    attachedContent = result
                    isExtracting = false
                    withAnimation(.easeOut(duration: 0.2)) {
                        panelState = .withContext
                    }
                }
            }
        }

        private func removeContext() {
            withAnimation(.easeOut(duration: 0.2)) {
                attachedContent = nil
                selectedWindow = nil
                panelState = .quickChat
            }
        }

        private func submitQuestion() {
            let trimmed = userQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            onSubmit(trimmed, attachedContent)
        }
    }

    // MARK: - Visual Effect Blur

    struct VisualEffectBlur: NSViewRepresentable {
        let material: NSVisualEffectView.Material
        let blendingMode: NSVisualEffectView.BlendingMode

        func makeNSView(context _: Context) -> NSVisualEffectView {
            let view = NSVisualEffectView()
            view.material = material
            view.blendingMode = blendingMode
            view.state = .active
            return view
        }

        func updateNSView(_ nsView: NSVisualEffectView, context _: Context) {
            nsView.material = material
            nsView.blendingMode = blendingMode
        }
    }

    // MARK: - Preview

    #Preview("Quick Chat") {
        SpotlightInputView(
            onSubmit: { _, _ in },
            onDismiss: {}
        )
        .frame(height: 100)
        .padding()
        .background(Color.gray.opacity(0.3))
    }
#endif
