import Foundation

/// Centralizes access to UserDefaults so tests can swap in isolated suites
/// without mutating the real application preferences.
enum AppPreferences {
  private static var customDefaults: UserDefaults?

  static var storage: UserDefaults {
    customDefaults ?? .standard
  }

  static func use(_ defaults: UserDefaults) {
    customDefaults = defaults
  }

  static func reset() {
    customDefaults = nil
  }
}
