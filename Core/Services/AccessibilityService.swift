//
//  AccessibilityService.swift
//  ayna
//
//  Manages Accessibility API permissions required for content extraction.
//

#if os(macOS)
    import AppKit
    import ApplicationServices

    /// Service for managing macOS Accessibility API permissions.
    /// Required for extracting content from other applications.
    @MainActor @Observable
    final class AccessibilityService {
        static let shared = AccessibilityService()

        /// Whether Accessibility permission is currently granted
        private(set) var isEnabled: Bool = false

        /// Task for polling permission status
        private var pollingTask: Task<Void, Never>?

        /// Polling interval in seconds
        private let pollingInterval: Duration = .seconds(2)

        private init() {
            // Check initial permission state
            isEnabled = checkPermission(prompt: false)
        }

        // MARK: - Permission Management

        /// Checks if the app has Accessibility permission.
        /// - Parameter prompt: If true, shows the system prompt to grant permission
        /// - Returns: Whether the app is trusted for Accessibility
        @discardableResult
        func checkPermission(prompt: Bool) -> Bool {
            // Use string constant directly to avoid concurrency warning with kAXTrustedCheckOptionPrompt
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

        /// Opens System Settings to the Accessibility pane for granting permission.
        func openAccessibilityPreferences() {
            // Deep link to System Settings > Privacy & Security > Accessibility
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

        // MARK: - Permission Monitoring

        /// Starts polling for permission changes.
        /// Useful when the user may grant permission while the app is running.
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

                        // Post notification for interested parties
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

        /// Stops polling for permission changes.
        func stopMonitoring() {
            pollingTask?.cancel()
            pollingTask = nil

            DiagnosticsLogger.log(
                .attachFromApp,
                level: .info,
                message: "Stopped accessibility permission monitoring"
            )
        }

        // MARK: - AX Element Helpers

        /// Creates an AXUIElement for a running application.
        /// - Parameter app: The running application
        /// - Returns: An AXUIElement for the application
        func createApplicationElement(for app: NSRunningApplication) -> AXUIElement {
            AXUIElementCreateApplication(app.processIdentifier)
        }

        /// Gets the focused element within an application.
        /// - Parameter appElement: The application's AXUIElement
        /// - Returns: The focused UI element, or nil if none
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

            // Safe cast after type check - AXUIElement is a CFTypeRef alias
            return unsafeBitCast(element, to: AXUIElement.self)
        }

        /// Gets an attribute value from an AXUIElement.
        /// - Parameters:
        ///   - element: The UI element
        ///   - attribute: The attribute name (e.g., kAXValueAttribute)
        /// - Returns: The attribute value, or nil if not available
        func getAttributeValue(_ element: AXUIElement, attribute: String) -> CFTypeRef? {
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)

            guard result == .success else {
                return nil
            }

            return value
        }

        /// Gets a string attribute from an AXUIElement.
        /// - Parameters:
        ///   - element: The UI element
        ///   - attribute: The attribute name
        /// - Returns: The string value, or nil if not available or not a string
        func getStringAttribute(_ element: AXUIElement, attribute: String) -> String? {
            guard let value = getAttributeValue(element, attribute: attribute) else {
                return nil
            }

            return value as? String
        }

        /// Gets the role of an AXUIElement.
        /// - Parameter element: The UI element
        /// - Returns: The role string (e.g., "AXTextField", "AXTextArea")
        func getRole(_ element: AXUIElement) -> String? {
            getStringAttribute(element, attribute: kAXRoleAttribute as String)
        }

        /// Gets the selected text from an AXUIElement.
        /// - Parameter element: The UI element
        /// - Returns: The selected text, or nil if none selected
        func getSelectedText(_ element: AXUIElement) -> String? {
            getStringAttribute(element, attribute: kAXSelectedTextAttribute as String)
        }

        /// Gets the full value/content from an AXUIElement.
        /// - Parameter element: The UI element
        /// - Returns: The value text, or nil if not available
        func getValue(_ element: AXUIElement) -> String? {
            getStringAttribute(element, attribute: kAXValueAttribute as String)
        }

        /// Gets the title of an AXUIElement.
        /// - Parameter element: The UI element
        /// - Returns: The title, or nil if not available
        func getTitle(_ element: AXUIElement) -> String? {
            getStringAttribute(element, attribute: kAXTitleAttribute as String)
        }

        /// Gets the focused window from an application element.
        /// - Parameter appElement: The application's AXUIElement
        /// - Returns: The focused window element, or nil if none
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

            // Safe cast after type check - AXUIElement is a CFTypeRef alias
            return unsafeBitCast(window, to: AXUIElement.self)
        }

        /// Gets the window title from an application.
        /// - Parameter appElement: The application's AXUIElement
        /// - Returns: The window title, or nil if not available
        func getWindowTitle(in appElement: AXUIElement) -> String? {
            guard let window = getFocusedWindow(in: appElement) else {
                return nil
            }

            return getTitle(window)
        }

        // MARK: - Window Enumeration

        /// Information about a window
        struct WindowInfo: Identifiable, Hashable {
            let id: CGWindowID
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

        /// Information about an app and its windows
        struct AppWindowGroup: Identifiable {
            let id: String // bundleIdentifier or processIdentifier
            let app: NSRunningApplication
            let appName: String
            let appIcon: NSImage?
            let bundleIdentifier: String?
            var windows: [WindowInfo]
        }

        /// Gets all windows grouped by application.
        /// - Returns: Array of app groups with their windows
        func getAllWindowsGroupedByApp() -> [AppWindowGroup] {
            var appGroups: [String: AppWindowGroup] = [:]

            // Get all running apps that could have windows
            let runningApps = NSWorkspace.shared.runningApplications.filter { app in
                app.activationPolicy == .regular &&
                    app.bundleIdentifier != Bundle.main.bundleIdentifier // Exclude Ayna
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

                // Only include apps that have at least one window
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

            // Sort by app name
            return appGroups.values.sorted { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
        }

        /// Gets all windows for a specific application.
        /// - Parameters:
        ///   - appElement: The application's AXUIElement
        ///   - app: The running application
        /// - Returns: Array of window info
        private func getWindowsForApp(appElement: AXUIElement, app: NSRunningApplication) -> [WindowInfo] {
            var windows: [WindowInfo] = []

            // Get windows array from AX
            var windowsRef: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(
                appElement,
                kAXWindowsAttribute as CFString,
                &windowsRef
            )

            // Log the result for debugging
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
                // Get window title
                let title = getTitle(windowElement) ?? "Window \(index + 1)"

                // Skip windows with empty titles or specific system windows
                if title.isEmpty || title == "Window" {
                    continue
                }

                // Create a unique ID using index since we can't easily get CGWindowID from AXUIElement
                let windowId = CGWindowID(app.processIdentifier * 1000 + Int32(index))

                let windowInfo = WindowInfo(
                    id: windowId,
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

        /// Extracts content from a specific window.
        /// - Parameter window: The window info to extract from
        /// - Returns: The extracted content result
        func extractContent(from window: WindowInfo) async -> AppContentResult {
            guard checkPermission(prompt: false) else {
                return .permissionDenied
            }

            // Get the running app
            guard let app = NSRunningApplication(processIdentifier: window.appPID) else {
                return .extractionFailed(reason: "Application no longer running")
            }

            // Try to get content from the window's focused element or main content
            // First, try to get selected text
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

            // Try to get value from the window or its focused element
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

            // Fall back to using the main extractor for this app
            return await AppContentService.shared.extractContent(from: app)
        }

        /// Gets the focused element within a window.
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
                // Try to get the main content area instead
                return getMainContentElement(windowElement)
            }

            // Safe cast after type check - AXUIElement is a CFTypeRef alias
            return unsafeBitCast(element, to: AXUIElement.self)
        }

        /// Attempts to find the main content element in a window.
        private func getMainContentElement(_ windowElement: AXUIElement) -> AXUIElement? {
            // Try to get AXContents or first child
            var contentsRef: CFTypeRef?
            var result = AXUIElementCopyAttributeValue(
                windowElement,
                "AXContents" as CFString,
                &contentsRef
            )

            if result == .success, let contents = contentsRef as? [AXUIElement], let first = contents.first {
                return first
            }

            // Try children
            result = AXUIElementCopyAttributeValue(
                windowElement,
                kAXChildrenAttribute as CFString,
                &contentsRef
            )

            if result == .success, let children = contentsRef as? [AXUIElement] {
                // Look for text area or text field
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

        /// Determines the content type based on the app.
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

    // MARK: - Notifications

    extension Notification.Name {
        /// Posted when Accessibility permission status changes
        static let accessibilityPermissionChanged = Notification.Name("accessibilityPermissionChanged")
    }
#endif
