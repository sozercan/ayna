//
//  GlobalHotkeyServiceTests.swift
//  aynaTests
//
//  Tests for GlobalHotkeyService
//

#if os(macOS)
    @testable import Ayna
    import Carbon.HIToolbox
    import Testing

    @Suite("GlobalHotkeyService Tests")
    @MainActor
    struct GlobalHotkeyServiceTests {
        var service: GlobalHotkeyService

        init() {
            service = GlobalHotkeyService.shared
            service.unregister()
            service.onHotkeyPressed = nil
        }

        // MARK: - Registration Tests

        @Test("Initial state not registered")
        func initialStateNotRegistered() {
            // Fresh service should not be registered
            service.unregister() // Ensure clean state
            #expect(!service.isRegistered)
        }

        @Test("Register sets isRegistered")
        func registerSetsIsRegistered() throws {
            try service.register(
                keyCode: UInt32(kVK_Space),
                modifiers: UInt32(cmdKey | shiftKey)
            )

            #expect(service.isRegistered)
            service.unregister()
        }

        @Test("Unregister clears isRegistered")
        func unregisterClearsIsRegistered() throws {
            try service.register(
                keyCode: UInt32(kVK_Space),
                modifiers: UInt32(cmdKey | shiftKey)
            )

            service.unregister()

            #expect(!service.isRegistered)
        }

        @Test("Register default succeeds")
        func registerDefaultSucceeds() throws {
            try service.registerDefault()

            #expect(service.isRegistered)
            service.unregister()
        }

        @Test("Re-register unregisters first")
        func reRegisterUnregistersFirst() throws {
            try service.register(
                keyCode: UInt32(kVK_Space),
                modifiers: UInt32(cmdKey | shiftKey)
            )

            // Register again with different modifiers
            try service.register(
                keyCode: UInt32(kVK_Space),
                modifiers: UInt32(cmdKey | optionKey)
            )

            #expect(service.isRegistered)
            service.unregister()
        }

        // MARK: - Hotkey String Parsing Tests

        @Test("Register with hotkey string")
        func registerWithHotkeyString() throws {
            try service.register(hotkeyString: "⌘⇧Space")

            #expect(service.isRegistered)
            service.unregister()
        }

        @Test("Register with alternative modifiers")
        func registerWithAlternativeModifiers() throws {
            try service.register(hotkeyString: "cmd+shift+space")

            #expect(service.isRegistered)
            service.unregister()
        }

        // MARK: - Callback Tests

        @Test("Callback can be set")
        func callbackCanBeSet() {
            var callbackInvoked = false

            service.onHotkeyPressed = { _ in
                callbackInvoked = true
            }

            // We can't easily trigger the hotkey in tests,
            // but we can verify the callback is stored
            #expect(service.onHotkeyPressed != nil)
            _ = callbackInvoked // Silence unused variable warning
        }

        @Test("Captured app initially nil")
        func capturedAppInitiallyNil() {
            #expect(service.capturedApp == nil)
        }

        // MARK: - Error Handling Tests

        @Test("Multiple unregister calls safe")
        func multipleUnregisterCallsSafe() {
            service.unregister()
            service.unregister()
            service.unregister()

            // Should not crash
            #expect(!service.isRegistered)
        }
    }

    // MARK: - GlobalHotkeyError Tests

    @Suite("GlobalHotkeyError Tests")
    struct GlobalHotkeyErrorTests {
        @Test("Event handler install failed description")
        func eventHandlerInstallFailedDescription() throws {
            let error = GlobalHotkeyError.eventHandlerInstallFailed(status: -1)

            #expect(error.errorDescription != nil)
            #expect(try #require(error.errorDescription?.contains("event handler") as Bool?))
        }

        @Test("Registration failed description")
        func registrationFailedDescription() throws {
            let error = GlobalHotkeyError.registrationFailed(status: -1)

            #expect(error.errorDescription != nil)
            #expect(try #require(error.errorDescription?.contains("register") as Bool?))
        }
    }
#endif
