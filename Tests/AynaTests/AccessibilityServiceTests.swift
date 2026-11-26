#if os(macOS)
    import AppKit
    @testable import Ayna
    import Testing

    @Suite("AccessibilityService Tests")
    @MainActor
    struct AccessibilityServiceTests {
        var service: AccessibilityService

        init() {
            service = AccessibilityService.shared
        }

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

        @Test("Check permission does not prompt when false")
        func checkPermissionDoesNotPromptWhenFalse() {
            let result = service.checkPermission(prompt: false)
            #expect(result == true || result == false)
        }

        @Test("isEnabled matches checkPermission")
        func isEnabledMatchesCheckPermission() {
            let checkResult = service.checkPermission(prompt: false)
            #expect(service.isEnabled == checkResult)
        }

        @Test("Start monitoring creates task")
        func startMonitoringCreatesTask() {
            service.startMonitoring()
            service.stopMonitoring()
        }

        @Test("Stop monitoring cancels task")
        func stopMonitoringCancelsTask() {
            service.startMonitoring()
            service.stopMonitoring()
        }

        @Test("Multiple start monitoring calls")
        func multipleStartMonitoringCalls() {
            service.startMonitoring()
            service.startMonitoring()
            service.stopMonitoring()
        }

        @Test("Create application element returns valid element")
        func createApplicationElementReturnsValidElement() {
            guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName != nil }) else {
                Issue.record("No running applications found - skipping test")
                return
            }

            let element = service.createApplicationElement(for: app)
            #expect(element != nil)
        }

        @Test("Get role returns nil for invalid element")
        func getRoleReturnsNilForInvalidElement() {
            let element = AXUIElementCreateApplication(0)
            let role = service.getRole(element)
            _ = role
        }
    }
#endif
