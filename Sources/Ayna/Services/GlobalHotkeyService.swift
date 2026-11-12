//
//  GlobalHotkeyService.swift
//  ayna
//
//  Registers system-wide hotkeys using Carbon Event Manager API.
//

#if os(macOS)
    import AppKit
    import Carbon.HIToolbox

    /// Service for registering and managing global hotkeys.
    /// Uses the Carbon Event Manager API for system-wide hotkey detection.
    @MainActor @Observable
    final class GlobalHotkeyService {
        static let shared = GlobalHotkeyService()

        /// Reference to the registered hotkey
        private var hotkeyRef: EventHotKeyRef?

        /// Reference to the event handler
        private var eventHandlerRef: EventHandlerRef?

        /// The frontmost app at the time the hotkey was pressed
        private(set) var capturedApp: NSRunningApplication?

        /// Callback invoked when the hotkey is pressed
        /// The parameter is the frontmost application at the time of the keypress
        var onHotkeyPressed: ((NSRunningApplication?) -> Void)?

        /// Whether the hotkey is currently registered
        private(set) var isRegistered: Bool = false

        /// Signature for our hotkey (4-character code)
        private let hotkeySignature: OSType = fourCharCode("AYNA")

        /// Hotkey ID
        private let hotkeyID: UInt32 = 1

        private init() {}

        // Note: Since this is a singleton (static let shared), deinit is only called at app termination.
        // The cleanup is handled by applicationWillTerminate calling unregister() explicitly.

        // MARK: - Registration

        /// Registers the global hotkey.
        /// - Parameters:
        ///   - keyCode: The virtual key code (e.g., kVK_Space)
        ///   - modifiers: The modifier flags (e.g., cmdKey | shiftKey)
        /// - Throws: An error if registration fails
        func register(keyCode: UInt32 = UInt32(kVK_Space), modifiers: UInt32 = UInt32(cmdKey | shiftKey)) throws {
            // Unregister existing hotkey if any
            if isRegistered {
                unregister()
            }

            // Create event type spec for hotkey pressed
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )

            // Store a reference to self for the callback
            // We use a pointer to allow the C callback to access our instance
            let selfPtr = Unmanaged.passUnretained(self).toOpaque()

            // Install event handler
            let installStatus = InstallEventHandler(
                GetApplicationEventTarget(),
                { _, event, userData -> OSStatus in
                    // Extract hotkey ID from event
                    var hotKeyID = EventHotKeyID()
                    let getStatus = GetEventParameter(
                        event,
                        EventParamName(kEventParamDirectObject),
                        EventParamType(typeEventHotKeyID),
                        nil,
                        MemoryLayout<EventHotKeyID>.size,
                        nil,
                        &hotKeyID
                    )

                    guard getStatus == noErr else {
                        return OSStatus(eventNotHandledErr)
                    }

                    // Get the service instance from userData
                    guard let userData else {
                        return OSStatus(eventNotHandledErr)
                    }

                    let service = Unmanaged<GlobalHotkeyService>.fromOpaque(userData).takeUnretainedValue()

                    // Verify this is our hotkey
                    guard hotKeyID.signature == service.hotkeySignature,
                          hotKeyID.id == service.hotkeyID
                    else {
                        return OSStatus(eventNotHandledErr)
                    }

                    // Dispatch to main actor
                    Task { @MainActor in
                        service.handleHotkeyPressed()
                    }

                    return noErr
                },
                1,
                &eventType,
                selfPtr,
                &eventHandlerRef
            )

            guard installStatus == noErr else {
                throw GlobalHotkeyError.eventHandlerInstallFailed(status: installStatus)
            }

            // Register the hotkey
            let hotKeyID = EventHotKeyID(signature: hotkeySignature, id: hotkeyID)

            let registerStatus = RegisterEventHotKey(
                keyCode,
                modifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &hotkeyRef
            )

            guard registerStatus == noErr else {
                // Clean up event handler on failure
                if let handler = eventHandlerRef {
                    RemoveEventHandler(handler)
                    eventHandlerRef = nil
                }
                throw GlobalHotkeyError.registrationFailed(status: registerStatus)
            }

            isRegistered = true

            DiagnosticsLogger.log(
                .attachFromApp,
                level: .info,
                message: "Global hotkey registered",
                metadata: [
                    "keyCode": "\(keyCode)",
                    "modifiers": "\(modifiers)"
                ]
            )
        }

        /// Unregisters the global hotkey.
        func unregister() {
            if let hotkey = hotkeyRef {
                UnregisterEventHotKey(hotkey)
                hotkeyRef = nil
            }

            if let handler = eventHandlerRef {
                RemoveEventHandler(handler)
                eventHandlerRef = nil
            }

            isRegistered = false

            DiagnosticsLogger.log(
                .attachFromApp,
                level: .info,
                message: "Global hotkey unregistered"
            )
        }

        // MARK: - Event Handling

        /// Called when our hotkey is pressed
        private func handleHotkeyPressed() {
            // CRITICAL: Capture the frontmost app BEFORE Ayna activates
            // This must happen immediately as our window will steal focus
            capturedApp = NSWorkspace.shared.frontmostApplication

            // Don't capture if Ayna itself is frontmost
            let aynaBundle = Bundle.main.bundleIdentifier
            if capturedApp?.bundleIdentifier == aynaBundle {
                capturedApp = nil
            }

            DiagnosticsLogger.log(
                .attachFromApp,
                level: .info,
                message: "Global hotkey pressed",
                metadata: [
                    "capturedApp": capturedApp?.localizedName ?? "none",
                    "bundleId": capturedApp?.bundleIdentifier ?? "none"
                ]
            )

            // Invoke the callback
            onHotkeyPressed?(capturedApp)
        }

        // MARK: - Hotkey Configuration

        /// Registers the hotkey saved in settings (⌘⇧Space unless the user recorded another).
        func registerSaved() throws {
            try register(HotkeyCombination(storage: AppPreferences.attachFromAppHotkey) ?? .default)
        }

        func register(_ combination: HotkeyCombination) throws {
            try register(keyCode: combination.keyCode, modifiers: combination.modifiers)
        }

        /// Switches to a new hotkey, restoring the previous one if the new one cannot be registered
        /// (for example because another app already owns it).
        func replaceHotkey(with combination: HotkeyCombination, previous: HotkeyCombination) throws {
            do {
                try register(combination)
            } catch {
                try? register(previous)
                throw error
            }
        }
    }

    // MARK: - Errors

    enum GlobalHotkeyError: LocalizedError {
        case eventHandlerInstallFailed(status: OSStatus)
        case registrationFailed(status: OSStatus)

        var errorDescription: String? {
            switch self {
            case let .eventHandlerInstallFailed(status):
                "Failed to install event handler (status: \(status))"
            case let .registrationFailed(status):
                status == OSStatus(eventHotKeyExistsErr)
                    ? "Another app already uses this shortcut"
                    : "Failed to register hotkey (status: \(status))"
            }
        }
    }

    // MARK: - Helpers

    /// Converts a 4-character string to an OSType (FourCharCode)
    private func fourCharCode(_ string: String) -> OSType {
        var result: OSType = 0
        for char in string.utf8.prefix(4) {
            result = (result << 8) + OSType(char)
        }
        return result
    }
#endif
