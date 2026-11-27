#if os(macOS)
    import AppKit
    @testable import Ayna
    import Carbon.HIToolbox
    import Testing

    @MainActor
    private final class MockHotkeyBackend: GlobalHotkeyBackend {
        struct Registration: Equatable {
            let keyCode: UInt32
            let modifiers: UInt32
            let signature: OSType
            let id: UInt32
        }

        var registrations: [Registration] = []
        var unregisterCount = 0
        var nextError: Error?
        var failingKeyCode: UInt32?
        private var pressedHandler: (@MainActor () -> Void)?

        func register(
            keyCode: UInt32,
            modifiers: UInt32,
            signature: OSType,
            id: UInt32,
            onPressed: @escaping @MainActor () -> Void
        ) throws {
            if let failingKeyCode, failingKeyCode == keyCode {
                throw GlobalHotkeyError.registrationFailed(status: OSStatus(eventHotKeyExistsErr))
            }
            if let error = nextError {
                nextError = nil
                throw error
            }
            registrations.append(Registration(keyCode: keyCode, modifiers: modifiers, signature: signature, id: id))
            pressedHandler = onPressed
        }

        func unregister() {
            unregisterCount += 1
            pressedHandler = nil
        }

        func simulatePress() {
            pressedHandler?()
        }
    }

    @Suite("GlobalHotkeyService Tests")
    @MainActor
    struct GlobalHotkeyServiceTests {
        @Test("Initial state is not registered and capturedApp is nil")
        func initialState() {
            let backend = MockHotkeyBackend()
            let service = GlobalHotkeyService(backend: backend)

            #expect(!service.isRegistered)
            #expect(service.capturedApp == nil)
        }

        @Test("Register forwards keyCode and modifiers and sets isRegistered")
        func registerForwardsParametersAndSetsState() throws {
            let backend = MockHotkeyBackend()
            let service = GlobalHotkeyService(backend: backend)

            try service.register(
                keyCode: UInt32(kVK_Space),
                modifiers: UInt32(cmdKey | shiftKey)
            )

            #expect(service.isRegistered)
            #expect(backend.registrations.count == 1)
            #expect(backend.registrations.first?.keyCode == UInt32(kVK_Space))
            #expect(backend.registrations.first?.modifiers == UInt32(cmdKey | shiftKey))
        }

        @Test("Unregister calls backend and clears isRegistered")
        func unregisterClearsState() throws {
            let backend = MockHotkeyBackend()
            let service = GlobalHotkeyService(backend: backend)

            try service.register(.default)
            #expect(service.isRegistered)

            service.unregister()
            #expect(!service.isRegistered)
            #expect(backend.unregisterCount == 1)
        }

        @Test("Re-register unregisters previous hotkey before registering new one")
        func reRegisterUnregistersFirst() throws {
            let backend = MockHotkeyBackend()
            let service = GlobalHotkeyService(backend: backend)

            try service.register(
                keyCode: UInt32(kVK_Space),
                modifiers: UInt32(cmdKey | shiftKey)
            )
            try service.register(
                keyCode: UInt32(kVK_ANSI_A),
                modifiers: UInt32(cmdKey | optionKey)
            )

            #expect(service.isRegistered)
            #expect(backend.unregisterCount == 1)
            #expect(backend.registrations.count == 2)
            #expect(backend.registrations.last?.keyCode == UInt32(kVK_ANSI_A))
            #expect(backend.registrations.last?.modifiers == UInt32(cmdKey | optionKey))
        }

        @Test("Register with hotkey string parses keyCode and modifiers")
        func registerWithHotkeyStrings() throws {
            let backend = MockHotkeyBackend()
            let service = GlobalHotkeyService(backend: backend)

            let symbolCombo = try #require(HotkeyCombination(string: "⌘⇧Space"))
            try service.register(symbolCombo)
            #expect(backend.registrations.last?.keyCode == symbolCombo.keyCode)
            #expect(backend.registrations.last?.modifiers == symbolCombo.modifiers)

            let textCombo = try #require(HotkeyCombination(string: "cmd+shift+space"))
            try service.register(textCombo)
            #expect(backend.registrations.last?.keyCode == textCombo.keyCode)
            #expect(backend.registrations.last?.modifiers == textCombo.modifiers)
        }

        @Test("Hotkey press invokes callback with frontmost app and ignores own bundle")
        func hotkeyPressInvokesCallbackAndFiltersOwnBundle() throws {
            let backend = MockHotkeyBackend()
            let currentApp = NSRunningApplication.current
            var frontmostBundleID: String? = "com.external.editor"
            var receivedApps: [NSRunningApplication?] = []

            let service = GlobalHotkeyService(
                backend: backend,
                frontmostApplicationProvider: { currentApp },
                appBundleIdentifierProvider: { _ in frontmostBundleID },
                ownBundleIdentifierProvider: { "com.sertacozercan.ayna" }
            )
            service.onHotkeyPressed = { app in
                receivedApps.append(app)
            }

            try service.register(.default)
            backend.simulatePress()

            #expect(receivedApps.count == 1)
            #expect(receivedApps.first??.processIdentifier == currentApp.processIdentifier)
            #expect(service.capturedApp?.processIdentifier == currentApp.processIdentifier)

            frontmostBundleID = "com.sertacozercan.ayna"
            backend.simulatePress()

            #expect(receivedApps.count == 2)
            #expect(receivedApps[1] == nil)
            #expect(service.capturedApp == nil)
        }

        @Test("Replace hotkey rolls back to previous combination on failure")
        func replaceHotkeyRollsBackOnFailure() throws {
            let backend = MockHotkeyBackend()
            let service = GlobalHotkeyService(backend: backend)
            let previous = HotkeyCombination(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | shiftKey))
            let failing = HotkeyCombination(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey | optionKey))

            try service.register(previous)
            backend.failingKeyCode = failing.keyCode

            #expect(throws: GlobalHotkeyError.self) {
                try service.replaceHotkey(with: failing, previous: previous)
            }

            #expect(service.isRegistered)
            #expect(backend.registrations.last?.keyCode == previous.keyCode)
            #expect(backend.registrations.last?.modifiers == previous.modifiers)
        }

        @Test("Registration failure leaves service unregistered")
        func registrationFailureLeavesServiceUnregistered() {
            let backend = MockHotkeyBackend()
            backend.nextError = GlobalHotkeyError.eventHandlerInstallFailed(status: -1)
            let service = GlobalHotkeyService(backend: backend)

            #expect(throws: GlobalHotkeyError.self) {
                try service.register(.default)
            }

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

            let conflictError = GlobalHotkeyError.registrationFailed(status: OSStatus(eventHotKeyExistsErr))
            #expect(conflictError.errorDescription == "Another app already uses this shortcut")
        }
    }
#endif
