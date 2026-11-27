// swiftformat:options --ifdef no-indent
#if os(macOS)

#if os(macOS)
import SwiftUI

enum SpotlightPanelState {
    case quickChat
    case pickingWindow
    case withContext
    case previewExpanded
}

struct SpotlightInputView: View {
    let onSubmit: (String, AppContentResult?) -> Void

    let onDismiss: () -> Void

    @State private var panelState: SpotlightPanelState = .quickChat

    @State private var userQuestion: String = ""

    @State private var attachedContent: AppContentResult?

    @State private var selectedWindow: AccessibilityService.WindowInfo?

    @State private var windowGroups: [AccessibilityService.AppWindowGroup] = []

    @State private var expandedApps: Set<String> = []

    @State private var isExtracting: Bool = false
    @State private var extractionTask: Task<Void, Never>?

    @FocusState private var isTextFieldFocused: Bool

    @State private var errorMessage: String?

    @ObservedObject var panelController: FloatingPanelController

    @State private var hasAccessibilityPermission: Bool = false

    init(
        panelController: FloatingPanelController = .shared,
        onSubmit: @escaping (String, AppContentResult?) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.panelController = panelController
        self.onSubmit = onSubmit
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = errorMessage {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.system(size: 12))
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
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .background(Color.orange.opacity(0.1))
            }

            inputField

            contextArea
        }
        .frame(width: 600)
        .background(
            VisualEffectBlur(material: .popover, blendingMode: .behindWindow)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
        .onAppear {
            isTextFieldFocused = true
            checkAccessibilityAndLoadWindows()
        }
        .onChange(of: panelController.focusRequestID) { _, _ in
            isTextFieldFocused = true
        }
        .onDisappear {
            extractionTask?.cancel()
        }
    }

    private var inputField: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Theme.textSecondary)

            TextField(placeholderText, text: $userQuestion)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .focused($isTextFieldFocused)
                .onSubmit {
                    submitQuestion()
                }

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

    private var attachButton: some View {
        Button {
            let hasPermission = AccessibilityService.shared.checkPermission(prompt: true)
            hasAccessibilityPermission = hasPermission

            withAnimation(.easeOut(duration: 0.2)) {
                panelState = .pickingWindow
            }

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

    private var windowPicker: some View {
        VStack(spacing: 0) {
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
            .frame(minHeight: 32)

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
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 16)

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

    private var emptyWindowsView: some View {
        VStack(spacing: Spacing.sm) {
            if !hasAccessibilityPermission {
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

    @ViewBuilder
    private var attachedContextBar: some View {
        if let content = attachedContent?.content {
            HStack(spacing: Spacing.sm) {
                if let icon = content.appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "app.fill")
                        .frame(width: 16, height: 16)
                        .foregroundStyle(Theme.textSecondary)
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
                        .truncationMode(.middle)
                }

                Spacer()

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

    @ViewBuilder
    private var attachedContextWithPreview: some View {
        if let content = attachedContent?.content {
            VStack(spacing: 0) {
                HStack(spacing: Spacing.sm) {
                    if let icon = content.appIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .scaledToFit()
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

    private func checkAccessibilityAndLoadWindows() {
        hasAccessibilityPermission = AccessibilityService.shared.checkPermission(prompt: false)

        if hasAccessibilityPermission {
            loadWindows()
        } else {
            windowGroups = []
            DiagnosticsLogger.log(
                .attachFromApp,
                level: .info,
                message: "Accessibility permission not granted - cannot list windows"
            )
        }
    }

    private func loadWindows() {
        windowGroups = AccessibilityService.shared.getAllWindowsGroupedByApp()

        DiagnosticsLogger.log(
            .attachFromApp,
            level: .info,
            message: "Loaded windows for picker",
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
        selectedWindow = window
        isExtracting = true
        errorMessage = nil

        extractionTask?.cancel()
        extractionTask = Task {
            let result = await AccessibilityService.shared.extractContent(from: window)
            await MainActor.run {
                isExtracting = false

                switch result {
                case .success:
                    attachedContent = result
                    withAnimation(.easeOut(duration: 0.2)) {
                        panelState = .withContext
                    }
                case .permissionDenied:
                    errorMessage = "Accessibility permission required."
                case .noFocusedApp:
                    errorMessage = "No focused app found."
                case .noContentAvailable:
                    errorMessage = "No extractable content in this window."
                case let .extractionFailed(reason):
                    errorMessage = reason
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
#endif
