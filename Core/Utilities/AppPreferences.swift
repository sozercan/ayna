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
    private static let workWithAppsEnabledKey = "workWithAppsEnabled"
    private static let workWithAppsHotkeyKey = "workWithAppsHotkey"

    private static var defaultValues: [String: Any] {
        [
            "autoGenerateTitle": true,
            globalSystemPromptKey: "",
            workWithAppsEnabledKey: false,
            workWithAppsHotkeyKey: "⌘⇧Space"
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

    // MARK: - Work with Apps (macOS only)

    /// Whether the "Work with Apps" feature is enabled.
    /// When enabled, a global hotkey can be used to capture context from other apps.
    static var workWithAppsEnabled: Bool {
        get { storage.bool(forKey: workWithAppsEnabledKey) }
        set { storage.set(newValue, forKey: workWithAppsEnabledKey) }
    }

    /// The hotkey string for "Work with Apps" (e.g., "⌘⇧Space").
    static var workWithAppsHotkey: String {
        get { storage.string(forKey: workWithAppsHotkeyKey) ?? "⌘⇧Space" }
        set { storage.set(newValue, forKey: workWithAppsHotkeyKey) }
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
