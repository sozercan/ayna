//
//  GlobalHotkeyServiceTests.swift
//  aynaTests
//
//  Tests for GlobalHotkeyService
//

#if os(macOS)
    @testable import Ayna
    import Carbon.HIToolbox
    import XCTest

    @MainActor
    final class GlobalHotkeyServiceTests: XCTestCase {
        var service: GlobalHotkeyService!

    override func setUp() async throws {
      try await super.setUp()
            service = GlobalHotkeyService.shared
        }

    override func tearDown() async throws {
            service.unregister()
            service.onHotkeyPressed = nil
      try await super.tearDown()
        }

        // MARK: - Registration Tests

        func testInitialStateNotRegistered() {
            // Fresh service should not be registered
            service.unregister() // Ensure clean state
            XCTAssertFalse(service.isRegistered)
        }

        func testRegisterSetsIsRegistered() throws {
            try service.register(
                keyCode: UInt32(kVK_Space),
                modifiers: UInt32(cmdKey | shiftKey)
            )

            XCTAssertTrue(service.isRegistered)
        }

        func testUnregisterClearsIsRegistered() throws {
            try service.register(
                keyCode: UInt32(kVK_Space),
                modifiers: UInt32(cmdKey | shiftKey)
            )

            service.unregister()

            XCTAssertFalse(service.isRegistered)
        }

        func testRegisterDefaultSucceeds() throws {
            try service.registerDefault()

            XCTAssertTrue(service.isRegistered)
        }

        func testReRegisterUnregistersFirst() throws {
            try service.register(
                keyCode: UInt32(kVK_Space),
                modifiers: UInt32(cmdKey | shiftKey)
            )

            // Register again with different modifiers
            try service.register(
                keyCode: UInt32(kVK_Space),
                modifiers: UInt32(cmdKey | optionKey)
            )

            XCTAssertTrue(service.isRegistered)
        }

        // MARK: - Hotkey String Parsing Tests

        func testRegisterWithHotkeyString() throws {
            try service.register(hotkeyString: "⌘⇧Space")

            XCTAssertTrue(service.isRegistered)
        }

        func testRegisterWithAlternativeModifiers() throws {
            try service.register(hotkeyString: "cmd+shift+space")

            XCTAssertTrue(service.isRegistered)
        }

        // MARK: - Callback Tests

        func testCallbackCanBeSet() {
            var callbackInvoked = false

            service.onHotkeyPressed = { _ in
                callbackInvoked = true
            }

            // We can't easily trigger the hotkey in tests,
            // but we can verify the callback is stored
            XCTAssertNotNil(service.onHotkeyPressed)
            _ = callbackInvoked // Silence unused variable warning
        }

        func testCapturedAppInitiallyNil() {
            XCTAssertNil(service.capturedApp)
        }

        // MARK: - Error Handling Tests

        func testMultipleUnregisterCallsSafe() {
            service.unregister()
            service.unregister()
            service.unregister()

            // Should not crash
            XCTAssertFalse(service.isRegistered)
        }
    }

    // MARK: - GlobalHotkeyError Tests

    final class GlobalHotkeyErrorTests: XCTestCase {
        func testEventHandlerInstallFailedDescription() {
            let error = GlobalHotkeyError.eventHandlerInstallFailed(status: -1)

            XCTAssertNotNil(error.errorDescription)
            XCTAssertTrue(error.errorDescription!.contains("event handler"))
        }

        func testRegistrationFailedDescription() {
            let error = GlobalHotkeyError.registrationFailed(status: -1)

            XCTAssertNotNil(error.errorDescription)
            XCTAssertTrue(error.errorDescription!.contains("register"))
        }
    }
#endif
