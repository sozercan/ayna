//
//  WindowGlassManager.swift
//  ayna
//
//  Created for macOS 26 Liquid Glass support.
//

#if os(macOS)
    import AppKit
    import Combine
    import Foundation

    /// Manages the Liquid Glass window background effect for macOS 26+.
    ///
    /// This manager handles applying and removing the native `NSGlassEffectView`
    /// to eligible windows. It observes preference changes and automatically
    /// updates all managed windows.
    ///
    /// ## Window Eligibility
    /// - Main content windows: eligible
    /// - Settings windows: excluded
    /// - Floating panels (Spotlight): excluded
    ///
    /// ## Usage
    /// Call `WindowGlassManager.shared.applyGlassIfEnabled(to:)` after configuring
    /// a window's appearance. The manager will handle the rest.
    @MainActor
    final class WindowGlassManager {
        // MARK: - Singleton

        static let shared = WindowGlassManager()

        // MARK: - Properties

        /// Tracks glass effect views inserted into windows, keyed by window's ObjectIdentifier.
        private var glassViews: [ObjectIdentifier: NSView] = [:]

        /// Subscription for preference changes.
        private var preferenceObserver: AnyCancellable?

        /// Subscription for appearance changes.
        private var appearanceObserver: NSObjectProtocol?

        // MARK: - Initialization

        private init() {
            print("🪟 Glass: WindowGlassManager initialized")
            setupObservers()
        }

        // Note: No deinit needed - this is a singleton that lives for the app's lifetime.
        // The observers will be cleaned up automatically when the app terminates.

        // MARK: - Setup

        private func setupObservers() {
            // Observe preference changes
            preferenceObserver = NotificationCenter.default
                .publisher(for: .liquidGlassPreferenceChanged)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    self?.updateAllWindows()
                }

            // Observe system appearance changes (light/dark mode)
            appearanceObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.updateAllWindows()
                }
            }
        }

        // MARK: - Public API

        /// Applies the Liquid Glass effect to a window if enabled and the window is eligible.
        ///
        /// - Parameter window: The window to apply the effect to.
        func applyGlassIfEnabled(to window: NSWindow) {
            print("🪟 Glass: applyGlassIfEnabled called for window: \(window.title), enabled: \(AppPreferences.liquidGlassEnabled)")

            guard isEligibleWindow(window) else {
                print("🪟 Glass: Window not eligible: \(window.title)")
                DiagnosticsLogger.log(
                    .app,
                    level: .debug,
                    message: "🪟 Glass: Window not eligible",
                    metadata: ["windowTitle": window.title, "windowId": "\(window.windowNumber)"]
                )
                return
            }

            guard AppPreferences.liquidGlassEnabled else {
                print("🪟 Glass: Preference disabled, removing glass")
                // Preference is off; ensure any existing glass is removed
                removeGlass(from: window)
                return
            }

            guard isReduceTransparencyDisabled() else {
                print("🪟 Glass: Reduce Transparency is enabled")
                DiagnosticsLogger.log(
                    .app,
                    level: .info,
                    message: "🪟 Glass: Reduce Transparency is enabled; skipping glass effect"
                )
                removeGlass(from: window)
                return
            }

            // Check OS version - NSGlassEffectView requires macOS 26+
            if #available(macOS 26.0, *) {
                print("🪟 Glass: Setting up glass layer for window: \(window.title)")
                setupGlassLayer(for: window)
            } else {
                print("🪟 Glass: macOS 26+ required")
                DiagnosticsLogger.log(
                    .app,
                    level: .debug,
                    message: "🪟 Glass: macOS 26+ required for Liquid Glass effect"
                )
            }
        }

        /// Removes the Liquid Glass effect from a window.
        ///
        /// - Parameter window: The window to remove the effect from.
        func removeGlass(from window: NSWindow) {
            let identifier = ObjectIdentifier(window)

            guard let glassView = glassViews[identifier] else {
                return
            }

            glassView.removeFromSuperview()
            glassViews.removeValue(forKey: identifier)

            // Restore window opacity
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor

            DiagnosticsLogger.log(
                .app,
                level: .info,
                message: "🪟 Glass: Removed glass effect from window",
                metadata: ["windowId": "\(window.windowNumber)"]
            )
        }

        /// Removes glass from all tracked windows and clears state.
        func removeAllGlass() {
            for (identifier, glassView) in glassViews {
                glassView.removeFromSuperview()
            }
            glassViews.removeAll()

            // Restore opacity for all windows
            for window in NSApp.windows where isEligibleWindow(window) {
                window.isOpaque = true
                window.backgroundColor = .windowBackgroundColor
            }

            DiagnosticsLogger.log(
                .app,
                level: .info,
                message: "🪟 Glass: Removed all glass effects"
            )
        }

        // MARK: - Private Implementation

        /// Checks if a window is eligible for the glass effect.
        private func isEligibleWindow(_ window: NSWindow) -> Bool {
            // Exclude panels (including Spotlight-style floating panels)
            if window.isKind(of: NSPanel.self) {
                return false
            }

            // Exclude Settings windows
            if let identifier = window.identifier?.rawValue {
                if identifier.lowercased().contains("settings") ||
                    identifier.lowercased().contains("preferences")
                {
                    return false
                }
            }

            if window.title.contains("Settings") || window.title.contains("Preferences") {
                return false
            }

            // Must have a content view
            guard window.contentView != nil else {
                return false
            }

            return true
        }

        /// Checks if the system "Reduce Transparency" setting is disabled.
        private func isReduceTransparencyDisabled() -> Bool {
            !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        }

        /// Sets up the glass layer for a window (macOS 26+ only).
        @available(macOS 26.0, *)
        private func setupGlassLayer(for window: NSWindow) {
            let identifier = ObjectIdentifier(window)

            // Remove existing glass view if present (idempotency)
            if let existingView = glassViews[identifier] {
                existingView.removeFromSuperview()
                glassViews.removeValue(forKey: identifier)
            }

            guard let contentView = window.contentView,
                  let windowContentView = contentView.superview
            else {
                DiagnosticsLogger.log(
                    .app,
                    level: .error,
                    message: "🪟 Glass: Could not access window content view hierarchy"
                )
                return
            }

            // Configure window for transparency
            window.isOpaque = false
            window.backgroundColor = .clear

            // Ensure titlebar is also transparent
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)

            // Make the SwiftUI hosting view and its layer transparent
            contentView.wantsLayer = true
            contentView.layer?.backgroundColor = .clear

            // Also make the window content view transparent
            windowContentView.wantsLayer = true
            windowContentView.layer?.backgroundColor = .clear

            // Make the titlebar container transparent if it exists
            if let titlebarContainer = windowContentView.superview {
                titlebarContainer.wantsLayer = true
                titlebarContainer.layer?.backgroundColor = .clear
            }

            // Traverse the view hierarchy and make key views transparent
            makeViewHierarchyTransparent(contentView)

            // Also traverse the windowContentView's siblings (toolbar, titlebar, etc.)
            for sibling in windowContentView.subviews {
                makeViewHierarchyTransparent(sibling)
            }

            // Create and configure the glass effect view
            let effectView = NSGlassEffectView()
            effectView.style = .clear  // Use clear style to avoid tinting
            effectView.cornerRadius = 16 // Standard corner radius for hiddenTitleBar style

            // Use the window's full content layout rect to include titlebar area
            if let themeFrame = window.contentView?.superview?.superview {
                effectView.frame = themeFrame.bounds
                themeFrame.addSubview(effectView, positioned: .below, relativeTo: themeFrame.subviews.first)
            } else {
                effectView.frame = windowContentView.bounds
                windowContentView.addSubview(effectView, positioned: .below, relativeTo: contentView)
            }

            effectView.autoresizingMask = [.width, .height]

            // Track the view for later removal
            glassViews[identifier] = effectView

            print("🪟 Glass: Successfully added glass effect view to window \(window.windowNumber)")
            print("🪟 Glass: Glass view frame: \(effectView.frame)")
            print("🪟 Glass: Window contentView superview subviews: \(windowContentView.subviews.count)")

            DiagnosticsLogger.log(
                .app,
                level: .info,
                message: "🪟 Glass: Applied Liquid Glass effect to window",
                metadata: ["windowId": "\(window.windowNumber)", "style": "regular"]
            )
        }

        /// Recursively makes the view hierarchy transparent to allow glass to show through.
        /// Specifically handles NSVisualEffectView which NavigationSplitView uses for sidebar.
        private func makeViewHierarchyTransparent(_ view: NSView) {
            view.wantsLayer = true

            // Handle NSVisualEffectView specially - this is what NavigationSplitView uses
            if let visualEffectView = view as? NSVisualEffectView {
                visualEffectView.state = .inactive
                visualEffectView.material = .underWindowBackground
                visualEffectView.alphaValue = 0
                visualEffectView.isEmphasized = false
                print("🪟 Glass: Made NSVisualEffectView transparent: \(type(of: view))")
            }

            // Clear the layer's background color for all views
            if let layer = view.layer {
                // Check if it's a solid color (not a gradient or image)
                if layer.backgroundColor != nil {
                    layer.backgroundColor = .clear
                }
            }

            // Recursively process ALL subviews - don't skip any
            for subview in view.subviews {
                makeViewHierarchyTransparent(subview)
            }
        }

        /// Updates all eligible windows based on current preferences.
        private func updateAllWindows() {
            print("🪟 Glass: updateAllWindows called, enabled: \(AppPreferences.liquidGlassEnabled), windowCount: \(NSApp.windows.count)")
            for window in NSApp.windows {
                print("🪟 Glass: Checking window: \(window.title)")
                if AppPreferences.liquidGlassEnabled {
                    applyGlassIfEnabled(to: window)
                } else {
                    removeGlass(from: window)
                }
            }

            DiagnosticsLogger.log(
                .app,
                level: .info,
                message: "🪟 Glass: Updated all windows",
                metadata: ["enabled": "\(AppPreferences.liquidGlassEnabled)"]
            )
        }
    }
#endif
