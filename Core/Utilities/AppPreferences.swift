import Foundation
import os

/// Centralizes access to UserDefaults so tests can swap in isolated suites
/// without mutating the real application preferences.
private final class DefaultsState: @unchecked Sendable {
    private var overriddenDefaults: UserDefaults?
    private let queue = DispatchQueue(label: "com.ayna.appPreferences")

    func storage() -> UserDefaults {
        queue.sync { overriddenDefaults ?? .standard }
    }

    func use(_ defaults: UserDefaults) {
        queue.sync { overriddenDefaults = defaults }
    }

    func reset() {
        queue.sync { overriddenDefaults = nil }
    }
}

enum AppPreferences {
    private static let state = DefaultsState()
    private static let globalSystemPromptKey = "globalSystemPrompt"
    private static let attachFromAppEnabledKey = "attachFromAppEnabled"
    private static let attachFromAppHotkeyKey = "attachFromAppHotkey"

    private static var defaultValues: [String: Any] {
        [
            "autoGenerateTitle": true,
            globalSystemPromptKey: "",
            attachFromAppEnabledKey: false,
            attachFromAppHotkeyKey: "⌘⇧Space"
        ]
    }

    static var storage: UserDefaults {
        state.storage()
    }

    /// The global system prompt used by conversations with `.inheritGlobal` mode.
    /// Returns an empty string by default (no system prompt).
    static var globalSystemPrompt: String {
        get { storage.string(forKey: globalSystemPromptKey) ?? "" }
        set { storage.set(newValue, forKey: globalSystemPromptKey) }
    }

    // MARK: - Attach from App (macOS only)

    /// Whether the "Attach from App" feature is enabled.
    /// When enabled, a global hotkey can be used to capture context from other apps.
    static var attachFromAppEnabled: Bool {
        get { storage.bool(forKey: attachFromAppEnabledKey) }
        set { storage.set(newValue, forKey: attachFromAppEnabledKey) }
    }

    /// The hotkey string for "Attach from App" (e.g., "⌘⇧Space").
    static var attachFromAppHotkey: String {
        get { storage.string(forKey: attachFromAppHotkeyKey) ?? "⌘⇧Space" }
        set { storage.set(newValue, forKey: attachFromAppHotkeyKey) }
    }

    static func registerDefaults() {
        storage.register(defaults: defaultValues)
    }

    static func use(_ defaults: UserDefaults) {
        defaults.register(defaults: defaultValues)
        state.use(defaults)
    }

    static func reset() {
        state.reset()
        registerDefaults()
    }
}
