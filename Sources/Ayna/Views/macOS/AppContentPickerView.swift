// swiftformat:options --ifdef no-indent
#if os(macOS)

#if os(macOS)
import SwiftUI

struct AppContentPickerView: View {
    let onSelect: (AppContent) -> Void

    let onDismiss: () -> Void

    @State private var windowGroups: [AccessibilityService.AppWindowGroup] = []

    @State private var expandedApps: Set<String> = []

    @State private var isExtracting: Bool = false

    @State private var extractingWindow: AccessibilityService.WindowInfo?

    @State private var errorMessage: String?

    @State private var hasAccessibilityPermission: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if let error = errorMessage {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(Typography.caption)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Button {
                        errorMessage = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(Spacing.sm)
                .background(Color.orange.opacity(0.1))
            }

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

    private var windowList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(windowGroups) { group in
                    appGroupRow(group)
                }
            }
        }
    }

    private func appGroupRow(_ group: AccessibilityService.AppWindowGroup) -> some View {
        VStack(spacing: 0) {
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
                    if let icon = group.appIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 20, height: 20)
                    } else {
                        Image(systemName: "app.fill")
                            .frame(width: 20, height: 20)
                            .foregroundStyle(Theme.textSecondary)
                    }

                    Text(group.appName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)

                    Text("(\(group.windows.count))")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)

                    Spacer()

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

            if expandedApps.contains(group.id) {
                ForEach(group.windows) { window in
                    windowRow(window)
                }
            }
        }
    }

    private func windowRow(_ window: AccessibilityService.WindowInfo) -> some View {
        Button {
            selectWindow(window)
        } label: {
            HStack(spacing: Spacing.sm) {
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
#endif
