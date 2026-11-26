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

        @Test("Initial state not registered")
        func initialStateNotRegistered() {
            service.unregister()
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
            try service.register(.default)

            #expect(service.isRegistered)
            service.unregister()
        }

        @Test("Re-register unregisters first")
        func reRegisterUnregistersFirst() throws {
            try service.register(
                keyCode: UInt32(kVK_Space),
                modifiers: UInt32(cmdKey | shiftKey)
            )

            try service.register(
                keyCode: UInt32(kVK_Space),
                modifiers: UInt32(cmdKey | optionKey)
            )

            #expect(service.isRegistered)
            service.unregister()
        }

        @Test("Register with hotkey string")
        func registerWithHotkeyString() throws {
            try service.register(#require(HotkeyCombination(string: "⌘⇧Space")))

            #expect(service.isRegistered)
            service.unregister()
        }

        @Test("Register with alternative modifiers")
        func registerWithAlternativeModifiers() throws {
            try service.register(#require(HotkeyCombination(string: "cmd+shift+space")))

            #expect(service.isRegistered)
            service.unregister()
        }

        @Test("Callback can be set")
        func callbackCanBeSet() {
            var callbackInvoked = false

            service.onHotkeyPressed = { _ in
                callbackInvoked = true
            }

            #expect(service.onHotkeyPressed != nil)
            _ = callbackInvoked
        }

        @Test("Captured app initially nil")
        func capturedAppInitiallyNil() {
            #expect(service.capturedApp == nil)
        }

        @Test("Multiple unregister calls safe")
        func multipleUnregisterCallsSafe() {
            service.unregister()
            service.unregister()
            service.unregister()

            #expect(!service.isRegistered)
        }
    }

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
