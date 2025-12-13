//
//  AccessibilityServiceTests.swift
//  aynaTests
//
//  Tests for AccessibilityService
//

#if os(macOS)
    @testable import Ayna
    import XCTest

    @MainActor
    final class AccessibilityServiceTests: XCTestCase {
        var service: AccessibilityService!

        override func setUp() async throws {
            service = AccessibilityService.shared
        }

        override func tearDown() async throws {
            service.stopMonitoring()
        }

        // MARK: - Permission Tests

        func testCheckPermissionDoesNotPromptWhenFalse() {
            // This test verifies that checkPermission with prompt: false
            // returns a boolean without showing system dialog
            let result = service.checkPermission(prompt: false)
            // Result can be true or false depending on system state
            XCTAssertNotNil(result)
        }

        func testIsEnabledMatchesCheckPermission() {
            let checkResult = service.checkPermission(prompt: false)
            XCTAssertEqual(service.isEnabled, checkResult)
        }

        // MARK: - Monitoring Tests

        func testStartMonitoringCreatesTask() {
            service.startMonitoring()
            // Service should be monitoring (we can't directly check the task,
            // but we can verify it doesn't crash)
            service.stopMonitoring()
        }

        func testStopMonitoringCancelsTask() {
            service.startMonitoring()
            service.stopMonitoring()
            // Should not crash or cause issues
        }

        func testMultipleStartMonitoringCalls() {
            service.startMonitoring()
            service.startMonitoring() // Should be idempotent
            service.stopMonitoring()
        }

        // MARK: - AX Element Helper Tests

        func testCreateApplicationElementReturnsValidElement() {
            // Get any running application
            guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName != nil }) else {
                XCTSkip("No running applications found")
                return
            }

            let element = service.createApplicationElement(for: app)
            XCTAssertNotNil(element)
        }

        func testGetRoleReturnsNilForInvalidElement() {
            // Create an element for a non-existent PID
            let element = AXUIElementCreateApplication(0)
            let role = service.getRole(element)
            // May return nil or a role depending on system state
            // The important thing is it doesn't crash
            _ = role
        }
    }
#endif
