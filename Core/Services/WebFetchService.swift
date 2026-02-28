//
//  WebFetchService.swift
//  ayna
//

import Foundation

/// Service managing the web fetch tool that allows AI to fetch content from URLs.
@Observable
@MainActor
final class WebFetchService {
    static let shared = WebFetchService()

    private static let enabledKey = "webFetchEnabled"

    /// Whether the web fetch tool is enabled
    var isEnabled: Bool {
        didSet {
            AppPreferences.storage.set(isEnabled, forKey: Self.enabledKey)
        }
    }

    private init() {
        isEnabled = AppPreferences.storage.bool(forKey: Self.enabledKey)
    }
}
