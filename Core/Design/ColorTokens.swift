//
//  ColorTokens.swift
//  ayna
//
//  Design System: Semantic Color Tokens
//  Cross-platform color definitions that adapt to light/dark mode
//  and respect platform idioms (macOS vs iOS vs watchOS).
//
//  Dark Mode Guidelines:
//  - Never use pure black (#000) on OLED - minimum Color(white: 0.05)
//  - Elevated surfaces get LIGHTER in dark mode (Apple's elevation model)
//  - All text must pass WCAG AA contrast (4.5:1 minimum)
//

import SwiftUI

// MARK: - Theme

/// Centralized semantic color tokens for the Ayna design system.
/// Use these instead of hardcoded colors throughout the app.
public enum Theme {
    // MARK: - Message Bubbles

    /// User message bubble background - modern solid blue (not gradient)
    public static var userBubble: Color {
        // Modern iMessage-style vibrant blue
        Color(red: 0.0, green: 0.48, blue: 1.0)
    }

    /// User message bubble gradient (subtle, modern - less aggressive than before)
    public static var userBubbleGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.0, green: 0.48, blue: 1.0),
                Color(red: 0.0, green: 0.44, blue: 0.96)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Assistant message bubble background
    public static var assistantBubble: Color {
        #if os(macOS)
            Color(nsColor: .controlBackgroundColor).opacity(0.8)
        #elseif os(watchOS)
            // Avoid pure black - use elevated dark gray for OLED friendliness
            Color(white: 0.18)
        #else
            Color(uiColor: .systemGray5)
        #endif
    }

    /// Assistant message bubble gradient (macOS) - softer, more neutral
    public static var assistantBubbleGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.28, green: 0.28, blue: 0.30),
                Color(red: 0.22, green: 0.22, blue: 0.24)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Tool/MCP result bubble background - softer amber instead of harsh orange
    public static var toolBubble: Color {
        Color(red: 0.95, green: 0.6, blue: 0.2)
    }

    /// Text color for user bubbles (always white for contrast)
    public static var userBubbleText: Color {
        .white
    }

    /// Text color for assistant bubbles
    public static var assistantBubbleText: Color {
        #if os(watchOS)
            .white
        #else
            .primary
        #endif
    }

    // MARK: - Status Colors

    /// Connected / Success state
    public static var statusConnected: Color {
        .green
    }

    /// Connecting / Warning state
    public static var statusConnecting: Color {
        .orange
    }

    /// Disconnected / Idle state
    public static var statusDisconnected: Color {
        .gray
    }

    /// Error state
    public static var statusError: Color {
        .red
    }

    /// Returns the appropriate status color for a connection state
    public static func statusColor(isConnected: Bool, isConnecting: Bool = false, hasError: Bool = false) -> Color {
        if hasError {
            statusError
        } else if isConnected {
            statusConnected
        } else if isConnecting {
            statusConnecting
        } else {
            statusDisconnected
        }
    }

    // MARK: - Backgrounds

    /// Primary window/view background
    public static var background: Color {
        #if os(macOS)
            Color(nsColor: .windowBackgroundColor)
        #elseif os(watchOS)
            // Never pure black on OLED - use very dark gray
            Color(white: 0.05)
        #else
            Color(uiColor: .systemBackground)
        #endif
    }

    /// Secondary/grouped background - elevated surfaces are LIGHTER in dark mode
    public static var backgroundSecondary: Color {
        #if os(macOS)
            Color(nsColor: .controlBackgroundColor)
        #elseif os(watchOS)
            Color(white: 0.10)
        #else
            Color(uiColor: .secondarySystemBackground)
        #endif
    }

    /// Tertiary/elevated background - highest elevation = lightest in dark mode
    public static var backgroundTertiary: Color {
        #if os(macOS)
            Color(nsColor: .underPageBackgroundColor)
        #elseif os(watchOS)
            Color(white: 0.15)
        #else
            Color(uiColor: .tertiarySystemBackground)
        #endif
    }

    /// Elevated surface background (cards, popovers) - follows Apple's elevation model
    public static var backgroundElevated: Color {
        #if os(macOS)
            Color(nsColor: .controlBackgroundColor)
        #elseif os(watchOS)
            Color(white: 0.12)
        #else
            Color(uiColor: .secondarySystemBackground)
        #endif
    }

    // MARK: - Interactive Elements

    /// Primary action color (buttons, links)
    public static var accent: Color {
        .accentColor
    }

    /// Destructive action color
    public static var destructive: Color {
        .red
    }

    /// Selection highlight
    public static var selection: Color {
        Color.accentColor.opacity(0.15)
    }

    /// Hover state (macOS)
    public static var hover: Color {
        #if os(macOS)
            Color(nsColor: .controlAccentColor).opacity(0.1)
        #else
            Color.accentColor.opacity(0.1)
        #endif
    }

    // MARK: - Borders & Separators

    /// Subtle border color
    public static var border: Color {
        Color.secondary.opacity(0.15)
    }

    /// Separator/divider color
    public static var separator: Color {
        Color.secondary.opacity(0.2)
    }

    /// Focused element border
    public static var borderFocused: Color {
        Color.accentColor.opacity(0.5)
    }

    // MARK: - Text Colors

    /// Primary text
    public static var textPrimary: Color {
        .primary
    }

    /// Secondary/muted text
    public static var textSecondary: Color {
        .secondary
    }

    /// Tertiary/hint text
    public static var textTertiary: Color {
        #if os(macOS)
            Color(nsColor: .tertiaryLabelColor)
        #elseif os(watchOS)
            Color.secondary.opacity(0.7)
        #else
            Color(uiColor: .tertiaryLabel)
        #endif
    }

    /// Placeholder text
    public static var textPlaceholder: Color {
        #if os(macOS)
            Color(nsColor: .placeholderTextColor)
        #elseif os(watchOS)
            Color.secondary.opacity(0.5)
        #else
            Color(uiColor: .placeholderText)
        #endif
    }

    // MARK: - Shadows

    /// Standard shadow color
    public static var shadow: Color {
        .black.opacity(0.15)
    }

    /// Elevated shadow color (for floating elements)
    public static var shadowElevated: Color {
        .black.opacity(0.25)
    }

    // MARK: - Code Blocks

    /// Code block background
    public static var codeBackground: Color {
        #if os(macOS)
            Color(nsColor: .controlBackgroundColor).opacity(0.5)
        #elseif os(watchOS)
            Color(white: 0.15)
        #else
            Color(uiColor: .secondarySystemBackground)
        #endif
    }

    /// Code block border
    public static var codeBorder: Color {
        Color.secondary.opacity(0.15)
    }

    // MARK: - Provider-Specific Colors

    /// OpenAI brand color
    public static var providerOpenAI: Color {
        Color(red: 0.0, green: 0.65, blue: 0.52) // Teal-ish green
    }

    /// Azure brand color
    public static var providerAzure: Color {
        Color(red: 0.0, green: 0.47, blue: 0.84) // Azure blue
    }

    /// GitHub brand color
    public static var providerGitHub: Color {
        #if os(macOS)
            Color(nsColor: .labelColor) // Black/white depending on mode
        #elseif os(iOS)
            Color(uiColor: .label) // Black/white depending on mode
        #else
            .white
        #endif
    }

    /// Apple Intelligence brand color
    public static var providerApple: Color {
        Color.accentColor
    }
}

// MARK: - Convenience Extensions

public extension Color {
    /// Creates a color that adapts between light and dark mode
    /// - Parameters:
    ///   - light: Color to use in light mode
    ///   - dark: Color to use in dark mode
    static func adaptive(light: Color, dark: Color) -> Color {
        #if os(macOS)
            Color(nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    ? NSColor(dark)
                    : NSColor(light)
            })
        #elseif os(watchOS)
            dark // watchOS is always dark
        #else
            Color(uiColor: UIColor { traitCollection in
                traitCollection.userInterfaceStyle == .dark
                    ? UIColor(dark)
                    : UIColor(light)
            })
        #endif
    }
}

// MARK: - Status Color Helper for MCPServerStatus

#if os(macOS)
    extension Theme {
        /// Returns the status color for an MCP server status state
        static func statusColor(for state: MCPServerStatus.State) -> Color {
            switch state {
            case .connected:
                statusConnected
            case .connecting, .reconnecting:
                statusConnecting
            case .disabled, .idle:
                statusDisconnected
            case .error:
                statusError
            }
        }
    }
#endif
