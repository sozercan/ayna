#if os(macOS)
    import AppKit
    @testable import Ayna
    import Testing

    @Suite("AccessibilityService Tests")
    @MainActor
    struct AccessibilityServiceTests {
        @Test("Window identity preserves PID and index at signed PID edges")
        func windowIdentityPreservesPIDAndIndexAtSignedPIDEdges() {
            let maximumPID: pid_t = .max
            let minimumPID: pid_t = .min

            let maximumFirst = AccessibilityService.WindowIdentity(
                processIdentifier: maximumPID,
                enumerationIndex: 0
            )
            let maximumFirstCopy = AccessibilityService.WindowIdentity(
                processIdentifier: maximumPID,
                enumerationIndex: 0
            )
            let maximumSecond = AccessibilityService.WindowIdentity(
                processIdentifier: maximumPID,
                enumerationIndex: 1
            )
            let minimumFirst = AccessibilityService.WindowIdentity(
                processIdentifier: minimumPID,
                enumerationIndex: 0
            )

            #expect(maximumFirst.processIdentifier == maximumPID)
            #expect(maximumFirst.enumerationIndex == 0)
            #expect(maximumFirst == maximumFirstCopy)
            #expect(maximumFirst != maximumSecond)
            #expect(maximumFirst != minimumFirst)
            #expect(Set([maximumFirst, maximumFirstCopy, maximumSecond, minimumFirst]).count == 3)
        }

        @Test("Window info equality and hashing use window identity")
        func windowInfoEqualityAndHashingUseWindowIdentity() {
            let processIdentifier: pid_t = .max
            let firstIdentity = AccessibilityService.WindowIdentity(
                processIdentifier: processIdentifier,
                enumerationIndex: 17
            )
            let firstIdentityCopy = AccessibilityService.WindowIdentity(
                processIdentifier: processIdentifier,
                enumerationIndex: 17
            )
            let secondIdentity = AccessibilityService.WindowIdentity(
                processIdentifier: processIdentifier,
                enumerationIndex: 18
            )
            let element = AXUIElementCreateApplication(0)

            let first = AccessibilityService.WindowInfo(
                id: firstIdentity,
                title: "First",
                appPID: processIdentifier,
                appName: "Example",
                appIcon: nil,
                bundleIdentifier: "com.example.first",
                axElement: element
            )
            let equivalent = AccessibilityService.WindowInfo(
                id: firstIdentityCopy,
                title: "Equivalent",
                appPID: processIdentifier,
                appName: "Renamed Example",
                appIcon: nil,
                bundleIdentifier: "com.example.equivalent",
                axElement: element
            )
            let distinct = AccessibilityService.WindowInfo(
                id: secondIdentity,
                title: "First",
                appPID: processIdentifier,
                appName: "Example",
                appIcon: nil,
                bundleIdentifier: "com.example.first",
                axElement: element
            )

            #expect(first == equivalent)
            #expect(first != distinct)
            #expect(Set([first, equivalent, distinct]).count == 2)
        }

        @Test("Check permission forwards prompt flag and updates isEnabled")
        func checkPermissionForwardsPromptAndUpdatesIsEnabled() {
            var receivedPrompts: [Bool] = []
            var trusted = false

            let service = AccessibilityService(
                isProcessTrusted: { prompt in
                    receivedPrompts.append(prompt)
                    return trusted
                }
            )

            #expect(receivedPrompts == [false])
            #expect(!service.isEnabled)

            trusted = true
            let promptedResult = service.checkPermission(prompt: true)
            #expect(promptedResult)
            #expect(service.isEnabled)
            #expect(receivedPrompts == [false, true])

            trusted = false
            let silentResult = service.checkPermission(prompt: false)
            #expect(!silentResult)
            #expect(!service.isEnabled)
            #expect(receivedPrompts == [false, true, false])
        }

        @Test("Start and stop monitoring manage polling task and post permission change notification")
        func monitoringPostsNotificationWhenPermissionChanges() async {
            let notificationCenter = NotificationCenter()
            var trusted = false
            var observedEnabledValues: [Bool] = []

            let observer = notificationCenter.addObserver(
                forName: .accessibilityPermissionChanged,
                object: nil,
                queue: nil
            ) { notification in
                if let enabled = notification.userInfo?["enabled"] as? Bool {
                    observedEnabledValues.append(enabled)
                }
            }
            defer { notificationCenter.removeObserver(observer) }

            let service = AccessibilityService(
                pollingInterval: .milliseconds(10),
                notificationCenter: notificationCenter,
                isProcessTrusted: { _ in trusted }
            )

            #expect(!service.isMonitoring)

            trusted = true
            service.startMonitoring()
            #expect(service.isMonitoring)

            service.startMonitoring()
            #expect(service.isMonitoring)

            for _ in 0 ..< 50 where observedEnabledValues.isEmpty {
                try? await Task.sleep(for: .milliseconds(10))
            }

            service.stopMonitoring()
            #expect(!service.isMonitoring)
            #expect(service.isEnabled)
            #expect(observedEnabledValues == [true])
        }

        @Test("Open accessibility preferences targets Accessibility privacy pane")
        func openAccessibilityPreferencesTargetsPrivacyPane() {
            var openedURL: URL?

            let service = AccessibilityService(
                isProcessTrusted: { _ in true },
                openPreferencesURL: { url in
                    openedURL = url
                    return true
                }
            )

            service.openAccessibilityPreferences()

            #expect(openedURL?.absoluteString == "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        }

        @Test("Create application element forwards process identifier of running application")
        func createApplicationElementMatchesCurrentProcessIdentifier() {
            var capturedPID: pid_t?
            let stubElement = AXUIElementCreateApplication(0)
            let service = AccessibilityService(
                isProcessTrusted: { _ in true },
                applicationElementFactory: { pid in
                    capturedPID = pid
                    return stubElement
                }
            )
            let currentApp = NSRunningApplication.current
            let element = service.createApplicationElement(for: currentApp)

            #expect(capturedPID == currentApp.processIdentifier)
            #expect(CFEqual(element, stubElement))
        }

        @Test("Get role returns role string on success and nil on AX failure or non-string value")
        func getRoleReturnsExpectedValueForAXOutcomes() {
            let element = AXUIElementCreateApplication(42)

            let successService = AccessibilityService(
                isProcessTrusted: { _ in true },
                copyAttributeValue: { _, attribute in
                    #expect(attribute as String == kAXRoleAttribute as String)
                    return (.success, "AXTextArea" as CFString)
                }
            )
            #expect(successService.getRole(element) == "AXTextArea")

            let failureService = AccessibilityService(
                isProcessTrusted: { _ in true },
                copyAttributeValue: { _, _ in (.apiDisabled, nil) }
            )
            #expect(failureService.getRole(element) == nil)

            let nonStringService = AccessibilityService(
                isProcessTrusted: { _ in true },
                copyAttributeValue: { _, _ in (.success, NSNumber(value: 7)) }
            )
            #expect(nonStringService.getRole(element) == nil)
        }

        @Test("Get URL handles URL and String attribute values")
        func getURLHandlesURLAndStringAttributes() {
            let element = AXUIElementCreateApplication(42)

            let urlService = AccessibilityService(
                isProcessTrusted: { _ in true },
                copyAttributeValue: { _, attribute in
                    #expect(attribute as String == kAXURLAttribute as String)
                    return (.success, NSURL(string: "https://example.com/docs"))
                }
            )
            #expect(urlService.getURL(element) == "https://example.com/docs")

            let stringService = AccessibilityService(
                isProcessTrusted: { _ in true },
                copyAttributeValue: { _, _ in (.success, "https://example.org" as CFString) }
            )
            #expect(stringService.getURL(element) == "https://example.org")
        }
    }
#endif
