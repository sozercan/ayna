//
//  AppContentPickerView.swift
//  ayna
//
//  App content picker for attaching context from running applications.
//

#if os(macOS)
    import SwiftUI

    /// A sheet/popover for picking app content to attach to a message
    struct AppContentPickerView: View {
        /// Callback when user selects content
        let onSelect: (AppContent) -> Void

        /// Callback to dismiss the picker
        let onDismiss: () -> Void

        /// Available windows grouped by app
        @State private var windowGroups: [AccessibilityService.AppWindowGroup] = []

        /// Expanded apps in the picker
        @State private var expandedApps: Set<String> = []

        /// Loading state for content extraction
        @State private var isExtracting: Bool = false

        /// Selected window being extracted
        @State private var extractingWindow: AccessibilityService.WindowInfo?

        /// Error message to display
        @State private var errorMessage: String?

        /// Whether accessibility is enabled
        @State private var hasAccessibilityPermission: Bool = false

        var body: some View {
            VStack(spacing: 0) {
                // Header
                header

                Divider()

                // Content
                if !hasAccessibilityPermission {
                    accessibilityPrompt
                } else if windowGroups.isEmpty {
                    emptyState
                } else {
                    windowList
                }
            }
            .frame(width: 400, height: 350)
            .onAppear {
                checkAccessibilityAndLoadWindows()
            }
        }

        // MARK: - Header

        @ViewBuilder
        private var header: some View {
            HStack {
                Text("Attach from App")
                    .font(.headline)

                Spacer()

                Button("Cancel") {
                    onDismiss()
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
        }

        // MARK: - Accessibility Prompt

        @ViewBuilder
        private var accessibilityPrompt: some View {
            VStack(spacing: Spacing.md) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 40))
                    .foregroundStyle(Theme.textSecondary)

                Text("Accessibility Permission Required")
                    .font(.headline)

                Text("Ayna needs accessibility access to read content from other apps.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Button("Grant Permission") {
                    let granted = AccessibilityService.shared.checkPermission(prompt: true)
                    hasAccessibilityPermission = granted
                    if granted {
                        loadWindows()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        }

        // MARK: - Empty State

        @ViewBuilder
        private var emptyState: some View {
            VStack(spacing: Spacing.md) {
                Image(systemName: "macwindow.on.rectangle")
                    .font(.system(size: 40))
                    .foregroundStyle(Theme.textSecondary)

                Text("No Windows Found")
                    .font(.headline)

                Text("Open some applications with windows to attach their content.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)

                Button("Refresh") {
                    loadWindows()
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        }

        // MARK: - Window List

        @ViewBuilder
        private var windowList: some View {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(windowGroups) { group in
                        appGroupRow(group)
                    }
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

                        // Window count
                        Text("(\(group.windows.count))")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textTertiary)

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
                    // Indent
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: 20)

                    Image(systemName: "doc")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)

                    Text(window.title)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)

                    Spacer()

                    // Loading indicator for this window
                    if isExtracting, extractingWindow?.id == window.id {
                        ProgressView()
                            .scaleEffect(0.6)
                    }
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.xs)
                .background(Color.clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isExtracting)
        }

        // MARK: - Actions

        private func checkAccessibilityAndLoadWindows() {
            hasAccessibilityPermission = AccessibilityService.shared.checkPermission(prompt: false)

            if hasAccessibilityPermission {
                loadWindows()
            }
        }

        private func loadWindows() {
            windowGroups = AccessibilityService.shared.getAllWindowsGroupedByApp()

            DiagnosticsLogger.log(
                .attachFromApp,
                level: .info,
                message: "AppContentPicker: Loaded windows",
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
            extractingWindow = window
            isExtracting = true

            Task {
                let result = await AccessibilityService.shared.extractContent(from: window)

                await MainActor.run {
                    isExtracting = false
                    extractingWindow = nil

                    switch result {
                    case let .success(content):
                        onSelect(content)
                    case .permissionDenied:
                        errorMessage = "Accessibility permission is required to capture content."
                        DiagnosticsLogger.log(
                            .attachFromApp,
                            level: .error,
                            message: "Permission denied when extracting content"
                        )
                    case .noFocusedApp:
                        errorMessage = "No focused app found."
                        DiagnosticsLogger.log(
                            .attachFromApp,
                            level: .info,
                            message: "No focused app when extracting content"
                        )
                    case .noContentAvailable:
                        errorMessage = "No extractable content found in this window."
                        DiagnosticsLogger.log(
                            .attachFromApp,
                            level: .info,
                            message: "No content available in window"
                        )
                    case let .extractionFailed(reason):
                        errorMessage = reason
                        DiagnosticsLogger.log(
                            .attachFromApp,
                            level: .error,
                            message: "Failed to extract content",
                            metadata: ["reason": reason]
                        )
                    }
                }
            }
        }
    }
#endif
