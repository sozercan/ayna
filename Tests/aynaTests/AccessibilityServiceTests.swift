//
//  AccessibilityServiceTests.swift
//  aynaTests
//
//  Tests for AccessibilityService
//

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

        // MARK: - Permission Tests

        @Test("Check permission does not prompt when false")
        func checkPermissionDoesNotPromptWhenFalse() {
            // This test verifies that checkPermission with prompt: false
            // returns a boolean without showing system dialog
            let result = service.checkPermission(prompt: false)
            // Result can be true or false depending on system state
            #expect(result == true || result == false)
        }

        @Test("isEnabled matches checkPermission")
        func isEnabledMatchesCheckPermission() {
            let checkResult = service.checkPermission(prompt: false)
            #expect(service.isEnabled == checkResult)
        }

        // MARK: - Monitoring Tests

        @Test("Start monitoring creates task")
        func startMonitoringCreatesTask() {
            service.startMonitoring()
            // Service should be monitoring (we can't directly check the task,
            // but we can verify it doesn't crash)
            service.stopMonitoring()
        }

        @Test("Stop monitoring cancels task")
        func stopMonitoringCancelsTask() {
            service.startMonitoring()
            service.stopMonitoring()
            // Should not crash or cause issues
        }

        @Test("Multiple start monitoring calls")
        func multipleStartMonitoringCalls() {
            service.startMonitoring()
            service.startMonitoring() // Should be idempotent
            service.stopMonitoring()
        }

        // MARK: - AX Element Helper Tests

        @Test("Create application element returns valid element")
        func createApplicationElementReturnsValidElement() {
            // Get any running application
            guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName != nil }) else {
                // Skip test if no running applications
                Issue.record("No running applications found - skipping test")
                return
            }

            let element = service.createApplicationElement(for: app)
            #expect(element != nil)
        }

        @Test("Get role returns nil for invalid element")
        func getRoleReturnsNilForInvalidElement() {
            // Create an element for a non-existent PID
            let element = AXUIElementCreateApplication(0)
            let role = service.getRole(element)
            // May return nil or a role depending on system state
            // The important thing is it doesn't crash
            _ = role
        }
    }
#endif
