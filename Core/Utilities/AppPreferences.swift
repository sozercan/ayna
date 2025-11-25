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

    private static var defaultValues: [String: Any] {
        [
            "autoGenerateTitle": true,
            globalSystemPromptKey: ""
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
