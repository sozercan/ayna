import Foundation
import os

extension Notification.Name {
    static let globalSystemPromptDidChange = Notification.Name("globalSystemPromptDidChange")
    static let watchSyncContextDidChange = Notification.Name("watchSyncContextDidChange")
}

private final class DefaultsState: @unchecked Sendable {
    private var overriddenDefaults: UserDefaults?
    private let lock = OSAllocatedUnfairLock()

    func storage() -> UserDefaults {
        lock.lock()
        defer { lock.unlock() }
        return overriddenDefaults ?? .standard
    }

    func use(_ defaults: UserDefaults) {
        lock.lock()
        defer { lock.unlock() }
        overriddenDefaults = defaults
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        overriddenDefaults = nil
    }
}

enum AppPreferences {
    private static let state = DefaultsState()
    private static let globalSystemPromptKey = "globalSystemPrompt"
    private static let attachFromAppEnabledKey = "attachFromAppEnabled"
    private static let attachFromAppHotkeyKey = "attachFromAppHotkey"
    private static let multiModelSelectionEnabledKey = "multiModelSelectionEnabled"

    private static var defaultValues: [String: Any] {
        [
            "autoGenerateTitle": true,
            globalSystemPromptKey: "",
            attachFromAppEnabledKey: false,
            attachFromAppHotkeyKey: "⌘⇧Space",
            multiModelSelectionEnabledKey: true
        ]
    }

    static var storage: UserDefaults {
        state.storage()
    }

    static var globalSystemPrompt: String {
        get { storage.string(forKey: globalSystemPromptKey) ?? "" }
        set {
            guard newValue != globalSystemPrompt else { return }
            storage.set(newValue, forKey: globalSystemPromptKey)
            NotificationCenter.default.post(name: .globalSystemPromptDidChange, object: nil)
        }
    }

    static var attachFromAppEnabled: Bool {
        get { storage.bool(forKey: attachFromAppEnabledKey) }
        set { storage.set(newValue, forKey: attachFromAppEnabledKey) }
    }

    static var attachFromAppHotkey: String {
        get { storage.string(forKey: attachFromAppHotkeyKey) ?? "⌘⇧Space" }
        set { storage.set(newValue, forKey: attachFromAppHotkeyKey) }
    }

    static var multiModelSelectionEnabled: Bool {
        get {
            if storage.object(forKey: multiModelSelectionEnabledKey) == nil {
                return true
            }
            return storage.bool(forKey: multiModelSelectionEnabledKey)
        }
        set { storage.set(newValue, forKey: multiModelSelectionEnabledKey) }
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
