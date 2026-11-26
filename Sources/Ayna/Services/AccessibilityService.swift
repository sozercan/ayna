#if os(macOS)
    import AppKit
    import ApplicationServices

    @MainActor @Observable
    final class AccessibilityService {
        static let shared = AccessibilityService()

        private(set) var isEnabled: Bool = false

        private var pollingTask: Task<Void, Never>?

        private let pollingInterval: Duration = .seconds(2)

        private init() {
            isEnabled = checkPermission(prompt: false)
        }

        @discardableResult
        func checkPermission(prompt: Bool) -> Bool {
            let options: CFDictionary = [
                "AXTrustedCheckOptionPrompt" as CFString: prompt
            ] as CFDictionary

            let trusted = AXIsProcessTrustedWithOptions(options)
            isEnabled = trusted

            DiagnosticsLogger.log(
                .attachFromApp,
                level: .debug,
                message: "Accessibility permission check",
                metadata: [
                    "trusted": "\(trusted)",
                    "prompted": "\(prompt)"
                ]
            )

            return trusted
        }

        func openAccessibilityPreferences() {
            guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
                DiagnosticsLogger.log(
                    .attachFromApp,
                    level: .error,
                    message: "Failed to create Accessibility preferences URL"
                )
                return
            }

            NSWorkspace.shared.open(url)

            DiagnosticsLogger.log(
                .attachFromApp,
                level: .info,
                message: "Opened Accessibility preferences"
            )
        }

        func startMonitoring() {
            guard pollingTask == nil else { return }

            DiagnosticsLogger.log(
                .attachFromApp,
                level: .info,
                message: "Started accessibility permission monitoring"
            )

            pollingTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { break }

                    let wasEnabled = isEnabled
                    let nowEnabled = checkPermission(prompt: false)

                    if wasEnabled != nowEnabled {
                        DiagnosticsLogger.log(
                            .attachFromApp,
                            level: .info,
                            message: "Accessibility permission changed",
                            metadata: ["enabled": "\(nowEnabled)"]
                        )

                        NotificationCenter.default.post(
                            name: .accessibilityPermissionChanged,
                            object: nil,
                            userInfo: ["enabled": nowEnabled]
                        )
                    }

                    try? await Task.sleep(for: pollingInterval)
                }
            }
        }

        func stopMonitoring() {
            pollingTask?.cancel()
            pollingTask = nil

            DiagnosticsLogger.log(
                .attachFromApp,
                level: .info,
                message: "Stopped accessibility permission monitoring"
            )
        }

        func createApplicationElement(for app: NSRunningApplication) -> AXUIElement {
            AXUIElementCreateApplication(app.processIdentifier)
        }

        func getFocusedElement(in appElement: AXUIElement) -> AXUIElement? {
            var focusedElement: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(
                appElement,
                kAXFocusedUIElementAttribute as CFString,
                &focusedElement
            )

            guard result == .success,
                  let element = focusedElement,
                  CFGetTypeID(element as CFTypeRef) == AXUIElementGetTypeID()
            else {
                return nil
            }

            return unsafeDowncast(element, to: AXUIElement.self)
        }

        func getAttributeValue(_ element: AXUIElement, attribute: String) -> CFTypeRef? {
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)

            guard result == .success else {
                return nil
            }

            return value
        }

        func getStringAttribute(_ element: AXUIElement, attribute: String) -> String? {
            guard let value = getAttributeValue(element, attribute: attribute) else {
                return nil
            }

            return value as? String
        }

        func getRole(_ element: AXUIElement) -> String? {
            getStringAttribute(element, attribute: kAXRoleAttribute as String)
        }

        func getSelectedText(_ element: AXUIElement) -> String? {
            getStringAttribute(element, attribute: kAXSelectedTextAttribute as String)
        }

        func getValue(_ element: AXUIElement) -> String? {
            getStringAttribute(element, attribute: kAXValueAttribute as String)
        }

        func getTitle(_ element: AXUIElement) -> String? {
            getStringAttribute(element, attribute: kAXTitleAttribute as String)
        }

        func getDescription(_ element: AXUIElement) -> String? {
            getStringAttribute(element, attribute: kAXDescriptionAttribute as String)
        }

        func getIdentifier(_ element: AXUIElement) -> String? {
            getStringAttribute(element, attribute: kAXIdentifierAttribute as String)
        }

        func getSubrole(_ element: AXUIElement) -> String? {
            getStringAttribute(element, attribute: kAXSubroleAttribute as String)
        }

        func getDocument(_ element: AXUIElement) -> String? {
            getStringAttribute(element, attribute: kAXDocumentAttribute as String)
        }

        func getURL(_ element: AXUIElement) -> String? {
            guard let value = getAttributeValue(element, attribute: kAXURLAttribute as String) else {
                return nil
            }

            if let url = value as? URL {
                return url.absoluteString
            }

            return value as? String
        }

        func getChildren(_ element: AXUIElement) -> [AXUIElement] {
            guard let value = getAttributeValue(element, attribute: kAXChildrenAttribute as String),
                  let children = value as? [AXUIElement]
            else {
                return []
            }

            return children
        }

        func getFocusedWindow(in appElement: AXUIElement) -> AXUIElement? {
            var focusedWindow: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(
                appElement,
                kAXFocusedWindowAttribute as CFString,
                &focusedWindow
            )

            guard result == .success,
                  let window = focusedWindow,
                  CFGetTypeID(window as CFTypeRef) == AXUIElementGetTypeID()
            else {
                return nil
            }

            return unsafeDowncast(window, to: AXUIElement.self)
        }

        func getWindowTitle(in appElement: AXUIElement) -> String? {
            guard let window = getFocusedWindow(in: appElement) else {
                return nil
            }

            return getTitle(window)
        }

        struct WindowIdentity: Hashable {
            let processIdentifier: pid_t
            let enumerationIndex: Int
        }

        struct WindowInfo: Identifiable, Hashable {
            let id: WindowIdentity
            let title: String
            let appPID: pid_t
            let appName: String
            let appIcon: NSImage?
            let bundleIdentifier: String?
            let axElement: AXUIElement

            func hash(into hasher: inout Hasher) {
                hasher.combine(id)
            }

            static func == (lhs: WindowInfo, rhs: WindowInfo) -> Bool {
                lhs.id == rhs.id
            }
        }

        struct AppWindowGroup: Identifiable {
            let id: String
            let app: NSRunningApplication
            let appName: String
            let appIcon: NSImage?
            let bundleIdentifier: String?
            var windows: [WindowInfo]
        }

        func getAllWindowsGroupedByApp() -> [AppWindowGroup] {
            var appGroups: [String: AppWindowGroup] = [:]

            let runningApps = NSWorkspace.shared.runningApplications.filter { app in
                app.activationPolicy == .regular &&
                    app.bundleIdentifier != Bundle.main.bundleIdentifier
            }

            DiagnosticsLogger.log(
                .attachFromApp,
                level: .info,
                message: "Found running apps",
                metadata: ["count": "\(runningApps.count)"]
            )

            for app in runningApps {
                let appElement = createApplicationElement(for: app)
                let windows = getWindowsForApp(appElement: appElement, app: app)

                DiagnosticsLogger.log(
                    .attachFromApp,
                    level: .debug,
                    message: "App windows",
                    metadata: [
                        "app": app.localizedName ?? "Unknown",
                        "windowCount": "\(windows.count)"
                    ]
                )

                guard !windows.isEmpty else { continue }

                let groupId = app.bundleIdentifier ?? "\(app.processIdentifier)"

                let group = AppWindowGroup(
                    id: groupId,
                    app: app,
                    appName: app.localizedName ?? "Unknown",
                    appIcon: app.icon,
                    bundleIdentifier: app.bundleIdentifier,
                    windows: windows
                )

                appGroups[groupId] = group
            }

            DiagnosticsLogger.log(
                .attachFromApp,
                level: .info,
                message: "Window groups created",
                metadata: ["groupCount": "\(appGroups.count)"]
            )

            return appGroups.values.sorted { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
        }

        private func getWindowsForApp(appElement: AXUIElement, app: NSRunningApplication) -> [WindowInfo] {
            var windows: [WindowInfo] = []

            var windowsRef: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(
                appElement,
                kAXWindowsAttribute as CFString,
                &windowsRef
            )

            if result != .success {
                DiagnosticsLogger.log(
                    .attachFromApp,
                    level: .debug,
                    message: "Failed to get windows for app",
                    metadata: [
                        "app": app.localizedName ?? "Unknown",
                        "axError": "\(result.rawValue)"
                    ]
                )
                return windows
            }

            guard let windowArray = windowsRef as? [AXUIElement] else {
                DiagnosticsLogger.log(
                    .attachFromApp,
                    level: .debug,
                    message: "Windows ref is not array",
                    metadata: ["app": app.localizedName ?? "Unknown"]
                )
                return windows
            }

            for (index, windowElement) in windowArray.enumerated() {
                let title = getTitle(windowElement) ?? "Window \(index + 1)"

                if title.isEmpty || title == "Window" {
                    continue
                }

                let windowIdentity = WindowIdentity(
                    processIdentifier: app.processIdentifier,
                    enumerationIndex: index
                )

                let windowInfo = WindowInfo(
                    id: windowIdentity,
                    title: title,
                    appPID: app.processIdentifier,
                    appName: app.localizedName ?? "Unknown",
                    appIcon: app.icon,
                    bundleIdentifier: app.bundleIdentifier,
                    axElement: windowElement
                )

                windows.append(windowInfo)
            }

            return windows
        }

        func extractContent(from window: WindowInfo) async -> AppContentResult {
            guard checkPermission(prompt: false) else {
                return .permissionDenied
            }

            guard let app = NSRunningApplication(processIdentifier: window.appPID) else {
                return .extractionFailed(reason: "Application no longer running")
            }

            if let selectedText = getSelectedText(window.axElement), !selectedText.isEmpty {
                return .success(AppContent(
                    appName: window.appName,
                    appIcon: window.appIcon,
                    bundleIdentifier: window.bundleIdentifier,
                    windowTitle: window.title,
                    content: selectedText,
                    contentType: .selectedText,
                    isTruncated: false,
                    originalLength: selectedText.count
                ))
            }

            if let focusedElement = getFocusedElementInWindow(window.axElement),
               let value = getValue(focusedElement), !value.isEmpty
            {
                let contentType = determineContentType(for: app)
                return .success(AppContent(
                    appName: window.appName,
                    appIcon: window.appIcon,
                    bundleIdentifier: window.bundleIdentifier,
                    windowTitle: window.title,
                    content: value,
                    contentType: contentType,
                    isTruncated: false,
                    originalLength: value.count
                ))
            }

            return await AppContentService.shared.extractContent(from: app)
        }

        private func getFocusedElementInWindow(_ windowElement: AXUIElement) -> AXUIElement? {
            var focusedElement: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(
                windowElement,
                kAXFocusedUIElementAttribute as CFString,
                &focusedElement
            )

            guard result == .success,
                  let element = focusedElement,
                  CFGetTypeID(element as CFTypeRef) == AXUIElementGetTypeID()
            else {
                return getMainContentElement(windowElement)
            }

            return unsafeDowncast(element, to: AXUIElement.self)
        }

        private func getMainContentElement(_ windowElement: AXUIElement) -> AXUIElement? {
            var contentsRef: CFTypeRef?
            var result = AXUIElementCopyAttributeValue(
                windowElement,
                "AXContents" as CFString,
                &contentsRef
            )

            if result == .success, let contents = contentsRef as? [AXUIElement], let first = contents.first {
                return first
            }

            result = AXUIElementCopyAttributeValue(
                windowElement,
                kAXChildrenAttribute as CFString,
                &contentsRef
            )

            if result == .success, let children = contentsRef as? [AXUIElement] {
                for child in children {
                    if let role = getRole(child),
                       role == "AXTextArea" || role == "AXTextField" || role == "AXScrollArea"
                    {
                        return child
                    }
                }
                return children.first
            }

            return nil
        }

        private func determineContentType(for app: NSRunningApplication) -> AppContent.ContentType {
            guard let bundleId = app.bundleIdentifier else {
                return .generic
            }

            if bundleId.contains("Terminal") || bundleId.contains("iTerm") ||
                bundleId.contains("Warp") || bundleId.contains("ghostty") || bundleId.contains("alacritty")
            {
                return .terminalOutput
            }

            if bundleId.contains("Xcode") || bundleId.contains("VSCode") ||
                bundleId.contains("sublime") || bundleId.contains("jetbrains")
            {
                return .documentContent
            }

            if bundleId.contains("Safari") || bundleId.contains("Chrome") ||
                bundleId.contains("Firefox") || bundleId.contains("Arc") || bundleId.contains("Brave")
            {
                return .browserURL
            }

            return .generic
        }
    }

    extension Notification.Name {
        static let accessibilityPermissionChanged = Notification.Name("accessibilityPermissionChanged")
    }
#endif
