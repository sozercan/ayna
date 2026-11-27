#if os(macOS)
    import AppKit
    import Carbon.HIToolbox

    @MainActor
    protocol GlobalHotkeyBackend {
        func register(
            keyCode: UInt32,
            modifiers: UInt32,
            signature: OSType,
            id: UInt32,
            onPressed: @escaping @MainActor () -> Void
        ) throws

        func unregister()
    }

    @MainActor
    final class CarbonGlobalHotkeyBackend: GlobalHotkeyBackend {
        private var hotkeyRef: EventHotKeyRef?
        private var eventHandlerRef: EventHandlerRef?
        private var expectedSignature: OSType = 0
        private var expectedID: UInt32 = 0
        private var onPressed: (@MainActor () -> Void)?

        func register(
            keyCode: UInt32,
            modifiers: UInt32,
            signature: OSType,
            id: UInt32,
            onPressed: @escaping @MainActor () -> Void
        ) throws {
            unregister()
            expectedSignature = signature
            expectedID = id
            self.onPressed = onPressed

            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )

            let selfPtr = Unmanaged.passUnretained(self).toOpaque()

            let installStatus = InstallEventHandler(
                GetApplicationEventTarget(),
                { _, event, userData -> OSStatus in
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

                    guard let userData else {
                        return OSStatus(eventNotHandledErr)
                    }

                    let backend = Unmanaged<CarbonGlobalHotkeyBackend>.fromOpaque(userData).takeUnretainedValue()

                    guard hotKeyID.signature == backend.expectedSignature,
                          hotKeyID.id == backend.expectedID
                    else {
                        return OSStatus(eventNotHandledErr)
                    }

                    Task { @MainActor in
                        backend.onPressed?()
                    }

                    return noErr
                },
                1,
                &eventType,
                selfPtr,
                &eventHandlerRef
            )

            guard installStatus == noErr else {
                self.onPressed = nil
                throw GlobalHotkeyError.eventHandlerInstallFailed(status: installStatus)
            }

            let hotKeyID = EventHotKeyID(signature: signature, id: id)

            let registerStatus = RegisterEventHotKey(
                keyCode,
                modifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &hotkeyRef
            )

            guard registerStatus == noErr else {
                if let handler = eventHandlerRef {
                    RemoveEventHandler(handler)
                    eventHandlerRef = nil
                }
                self.onPressed = nil
                throw GlobalHotkeyError.registrationFailed(status: registerStatus)
            }
        }

        isolated deinit {
            unregister()
        }

        func unregister() {
            if let hotkey = hotkeyRef {
                UnregisterEventHotKey(hotkey)
                hotkeyRef = nil
            }

            if let handler = eventHandlerRef {
                RemoveEventHandler(handler)
                eventHandlerRef = nil
            }

            onPressed = nil
        }
    }

    @MainActor @Observable
    final class GlobalHotkeyService {
        static let shared = GlobalHotkeyService()

        private let backend: any GlobalHotkeyBackend
        private let frontmostApplicationProvider: () -> NSRunningApplication?
        private let appBundleIdentifierProvider: (NSRunningApplication) -> String?
        private let ownBundleIdentifierProvider: () -> String?

        private(set) var capturedApp: NSRunningApplication?

        var onHotkeyPressed: ((NSRunningApplication?) -> Void)?

        private(set) var isRegistered: Bool = false

        private let hotkeySignature: OSType = fourCharCode("AYNA")

        private let hotkeyID: UInt32 = 1

        init(
            backend: any GlobalHotkeyBackend = CarbonGlobalHotkeyBackend(),
            frontmostApplicationProvider: @escaping () -> NSRunningApplication? = {
                NSWorkspace.shared.frontmostApplication
            },
            appBundleIdentifierProvider: @escaping (NSRunningApplication) -> String? = \.bundleIdentifier,
            ownBundleIdentifierProvider: @escaping () -> String? = {
                Bundle.main.bundleIdentifier
            }
        ) {
            self.backend = backend
            self.frontmostApplicationProvider = frontmostApplicationProvider
            self.appBundleIdentifierProvider = appBundleIdentifierProvider
            self.ownBundleIdentifierProvider = ownBundleIdentifierProvider
        }

        func register(keyCode: UInt32 = UInt32(kVK_Space), modifiers: UInt32 = UInt32(cmdKey | shiftKey)) throws {
            if isRegistered {
                unregister()
            }

            try backend.register(
                keyCode: keyCode,
                modifiers: modifiers,
                signature: hotkeySignature,
                id: hotkeyID
            ) { [weak self] in
                self?.handleHotkeyPressed()
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

        func unregister() {
            backend.unregister()

            isRegistered = false

            DiagnosticsLogger.log(
                .attachFromApp,
                level: .info,
                message: "Global hotkey unregistered"
            )
        }

        private func handleHotkeyPressed() {
            capturedApp = frontmostApplicationProvider()

            if let captured = capturedApp,
               let aynaBundle = ownBundleIdentifierProvider(),
               appBundleIdentifierProvider(captured) == aynaBundle
            {
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

            onHotkeyPressed?(capturedApp)
        }

        func registerSaved() throws {
            try register(HotkeyCombination(storage: AppPreferences.attachFromAppHotkey) ?? .default)
        }

        func register(_ combination: HotkeyCombination) throws {
            try register(keyCode: combination.keyCode, modifiers: combination.modifiers)
        }

        func replaceHotkey(with combination: HotkeyCombination, previous: HotkeyCombination) throws {
            do {
                try register(combination)
            } catch {
                try? register(previous)
                throw error
            }
        }
    }

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

    private func fourCharCode(_ string: String) -> OSType {
        var result: OSType = 0
        for char in string.utf8.prefix(4) {
            result = (result << 8) + OSType(char)
        }
        return result
    }
#endif
