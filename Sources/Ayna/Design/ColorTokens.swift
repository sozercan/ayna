import SwiftUI

public enum Theme {
    public static var userBubble: Color {
        Color(red: 0.0, green: 0.48, blue: 1.0)
    }

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

    public static var assistantBubble: Color {
        #if os(macOS)
            Color(nsColor: .controlBackgroundColor).opacity(0.8)
        #elseif os(watchOS)
            Color(white: 0.18)
        #else
            Color(uiColor: .systemGray5)
        #endif
    }

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

    public static var toolBubble: Color {
        Color(red: 0.95, green: 0.6, blue: 0.2)
    }

    public static var userBubbleText: Color {
        .white
    }

    public static var assistantBubbleText: Color {
        #if os(watchOS)
            .white
        #else
            .primary
        #endif
    }

    public static var statusConnected: Color {
        .green
    }

    public static var statusConnecting: Color {
        .orange
    }

    public static var statusDisconnected: Color {
        .gray
    }

    public static var statusError: Color {
        .red
    }

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

    public static var background: Color {
        #if os(macOS)
            Color(nsColor: .windowBackgroundColor)
        #elseif os(watchOS)
            Color(white: 0.05)
        #else
            Color(uiColor: .systemBackground)
        #endif
    }

    public static var backgroundSecondary: Color {
        #if os(macOS)
            Color(nsColor: .controlBackgroundColor)
        #elseif os(watchOS)
            Color(white: 0.10)
        #else
            Color(uiColor: .secondarySystemBackground)
        #endif
    }

    public static var backgroundTertiary: Color {
        #if os(macOS)
            Color(nsColor: .underPageBackgroundColor)
        #elseif os(watchOS)
            Color(white: 0.15)
        #else
            Color(uiColor: .tertiarySystemBackground)
        #endif
    }

    public static var accent: Color {
        .accentColor
    }

    public static var destructive: Color {
        .red
    }

    public static var selection: Color {
        Color.accentColor.opacity(0.15)
    }

    public static var hover: Color {
        #if os(macOS)
            Color(nsColor: .controlAccentColor).opacity(0.1)
        #else
            Color.accentColor.opacity(0.1)
        #endif
    }

    public static var border: Color {
        Color.secondary.opacity(0.15)
    }

    public static var separator: Color {
        Color.secondary.opacity(0.2)
    }

    public static var textPrimary: Color {
        .primary
    }

    public static var textSecondary: Color {
        .secondary
    }

    public static var textTertiary: Color {
        #if os(macOS)
            Color(nsColor: .tertiaryLabelColor)
        #elseif os(watchOS)
            Color.secondary.opacity(0.7)
        #else
            Color(uiColor: .tertiaryLabel)
        #endif
    }

    public static var textPlaceholder: Color {
        #if os(macOS)
            Color(nsColor: .placeholderTextColor)
        #elseif os(watchOS)
            Color.secondary.opacity(0.5)
        #else
            Color(uiColor: .placeholderText)
        #endif
    }

    public static var shadow: Color {
        .black.opacity(0.15)
    }

    public static var codeBackground: Color {
        #if os(macOS)
            Color(nsColor: .controlBackgroundColor).opacity(0.5)
        #elseif os(watchOS)
            Color(white: 0.15)
        #else
            Color(uiColor: .secondarySystemBackground)
        #endif
    }

    public static var codeBorder: Color {
        Color.secondary.opacity(0.15)
    }
}

public extension Color {}

#if os(macOS)
    extension Theme {
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
