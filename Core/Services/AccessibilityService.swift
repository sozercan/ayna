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
                .workWithApps,
                level: .info,
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
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

            NSWorkspace.shared.open(url)

            DiagnosticsLogger.log(
                .workWithApps,
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
                .workWithApps,
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
                            .workWithApps,
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
                .workWithApps,
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

            guard result == .success, let element = focusedElement else {
                return nil
            }

            // swiftlint:disable:next force_cast
            return (element as! AXUIElement)
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

            guard result == .success, let window = focusedWindow else {
                return nil
            }

            // swiftlint:disable:next force_cast
            return (window as! AXUIElement)
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
    }

    // MARK: - Notifications

    extension Notification.Name {
        /// Posted when Accessibility permission status changes
        static let accessibilityPermissionChanged = Notification.Name("accessibilityPermissionChanged")
    }
#endif
