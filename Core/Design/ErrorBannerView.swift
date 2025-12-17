//
//  ErrorBannerView.swift
//  ayna
//
//  A reusable error banner component following Apple's Human Interface Guidelines.
//  Displays error messages with optional recovery suggestions and action buttons.
//
//  HIG Compliance:
//  - Non-modal, inline display for recoverable errors
//  - Clear, actionable messaging
//  - Accessible touch targets (44pt minimum)
//  - Consistent visual hierarchy across platforms
//

import SwiftUI

/// A cross-platform error banner view for displaying error messages.
///
/// Usage:
/// ```swift
/// if let error = viewModel.errorMessage {
///     ErrorBannerView(
///         message: error,
///         recoverySuggestion: "Check your internet connection",
///         onRetry: { viewModel.retry() },
///         onDismiss: { viewModel.dismissError() }
///     )
/// }
/// ```
public struct ErrorBannerView: View {
    /// The primary error message to display
    let message: String

    /// An optional secondary message with recovery guidance
    let recoverySuggestion: String?

    /// Optional retry action - if provided, shows a retry button
    let onRetry: (() -> Void)?

    /// Optional open-settings action - if provided, shows an "Open Settings" button
    let onOpenSettings: (() -> Void)?

    /// Optional settings destination to open on macOS via `SettingsLink`.
    ///
    /// Stored as `AnyHashable` to keep this view cross-platform; interpreted as `SettingsTab`
    /// only on macOS.
    /// If set on macOS, this takes precedence over `onOpenSettings`.
    let openSettingsTab: AnyHashable?

    /// Dismiss action - always required to clear the error
    let onDismiss: () -> Void

    /// Accessibility identifier prefix for testing
    var identifierPrefix: String = "error.banner"

    /// Creates an error banner view.
    /// - Parameters:
    ///   - message: The primary error message
    ///   - recoverySuggestion: Optional recovery guidance (e.g., "Check your API key in Settings")
    ///   - onRetry: Optional retry action closure
    ///   - onOpenSettings: Optional open-settings action closure
    ///   - openSettingsTab: Optional settings destination (macOS-only behavior)
    ///   - onDismiss: Dismiss action closure (required)
    ///   - identifierPrefix: Accessibility identifier prefix for testing
    public init(
        message: String,
        recoverySuggestion: String? = nil,
        onRetry: (() -> Void)? = nil,
        onOpenSettings: (() -> Void)? = nil,
        openSettingsTab: AnyHashable? = nil,
        onDismiss: @escaping () -> Void,
        identifierPrefix: String = "error.banner"
    ) {
        self.message = message
        self.recoverySuggestion = recoverySuggestion
        self.onRetry = onRetry
        self.onOpenSettings = onOpenSettings
        self.openSettingsTab = openSettingsTab
        self.onDismiss = onDismiss
        self.identifierPrefix = identifierPrefix
    }

    public var body: some View {
        #if os(watchOS)
            watchOSLayout
        #else
            standardLayout
        #endif
    }

    // MARK: - Standard Layout (iOS/macOS)

    private var standardLayout: some View {
        HStack(alignment: .center, spacing: Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: Typography.IconSize.md, weight: .semibold))
                .foregroundStyle(Theme.statusError)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Spacing.xxxs) {
                Text(message)
                    .font(Typography.body)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)

                if let suggestion = recoverySuggestion {
                    Text(suggestion)
                        .font(Typography.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: Spacing.sm)

            HStack(spacing: Spacing.xs) {
                #if os(macOS)
                    if let tab = openSettingsTab as? SettingsTab {
                        SettingsLink {
                            Text("Open Settings")
                                .font(Typography.buttonSmall)
                                .foregroundStyle(Theme.accent)
                        }
                        .routeSettings(to: tab)
                        .buttonStyle(.plain)
                        .frame(minHeight: Spacing.minTouchTarget)
                        .accessibilityIdentifier("\(identifierPrefix).openSettings")
                    } else if let openSettings = onOpenSettings {
                        Button("Open Settings", action: openSettings)
                            .font(Typography.buttonSmall)
                            .foregroundStyle(Theme.accent)
                            .buttonStyle(.plain)
                            .frame(minHeight: Spacing.minTouchTarget)
                            .accessibilityIdentifier("\(identifierPrefix).openSettings")
                    }
                #else
                    if let openSettings = onOpenSettings {
                        Button("Open Settings", action: openSettings)
                            .font(Typography.buttonSmall)
                            .foregroundStyle(Theme.accent)
                            .buttonStyle(.plain)
                            .frame(minHeight: Spacing.minTouchTarget)
                            .accessibilityIdentifier("\(identifierPrefix).openSettings")
                    }
                #endif
                if let retry = onRetry {
                    Button(action: retry) {
                        HStack(spacing: Spacing.xxs) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: Typography.IconSize.sm))
                            Text("Retry")
                                .font(Typography.buttonSmall)
                        }
                    }
                    .foregroundStyle(Theme.accent)
                    .buttonStyle(.plain)
                    .frame(minHeight: Spacing.minTouchTarget)
                    .accessibilityLabel("Retry")
                    .accessibilityIdentifier("\(identifierPrefix).retry")
                }

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: Typography.IconSize.md, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .frame(minWidth: Spacing.minTouchTarget, minHeight: Spacing.minTouchTarget)
                .contentShape(Rectangle())
                .accessibilityLabel("Dismiss error")
                .accessibilityIdentifier("\(identifierPrefix).dismiss")
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: Spacing.CornerRadius.lg)
                    .fill(Theme.statusError.opacity(0.10))
                Rectangle()
                    .fill(Theme.statusError)
                    .frame(width: 3)
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: Spacing.CornerRadius.lg)
                .stroke(Theme.border, lineWidth: Spacing.Border.standard)
        )
        .clipShape(RoundedRectangle(cornerRadius: Spacing.CornerRadius.lg))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityMessage)
        .accessibilityIdentifier("\(identifierPrefix).container")
    }

    // MARK: - watchOS Layout (Compact)

    private var watchOSLayout: some View {
        VStack(spacing: Spacing.sm) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.statusError)
                    .accessibilityHidden(true)

                Text(message)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)

                Spacer(minLength: 0)
            }

            if let suggestion = recoverySuggestion {
                Text(suggestion)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
            }

            HStack(spacing: Spacing.sm) {
                if let retry = onRetry {
                    Button("Retry", action: retry)
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                        .accessibilityIdentifier("\(identifierPrefix).retry")
                }

                Button("Dismiss", action: onDismiss)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("\(identifierPrefix).dismiss")
            }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.sm)
        .background(Theme.statusError.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: Spacing.CornerRadius.lg))
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityMessage)
        .accessibilityIdentifier("\(identifierPrefix).container")
    }

    // MARK: - Accessibility

    private var accessibilityMessage: String {
        if let suggestion = recoverySuggestion {
            return "Error: \(message). \(suggestion)"
        }
        return "Error: \(message)"
    }
}

// MARK: - Convenience Initializers

public extension ErrorBannerView {
    /// Creates an error banner from a LocalizedError with automatic recovery suggestion extraction.
    init(
        error: some LocalizedError,
        onRetry: (() -> Void)? = nil,
        onOpenSettings: (() -> Void)? = nil,
        onDismiss: @escaping () -> Void,
        identifierPrefix: String = "error.banner"
    ) {
        self.init(
            message: error.errorDescription ?? error.localizedDescription,
            recoverySuggestion: error.recoverySuggestion,
            onRetry: onRetry,
            onOpenSettings: onOpenSettings,
            onDismiss: onDismiss,
            identifierPrefix: identifierPrefix
        )
    }
}

// MARK: - Preview

#if DEBUG
    struct ErrorBannerView_Previews: PreviewProvider {
        static var previews: some View {
            VStack(spacing: 20) {
                // Simple error
                ErrorBannerView(
                    message: "Network connection failed",
                    onDismiss: {}
                )

                // Error with recovery suggestion
                ErrorBannerView(
                    message: "Invalid API key",
                    recoverySuggestion: "Check your API key in Settings",
                    onDismiss: {}
                )

                // Error with retry
                ErrorBannerView(
                    message: "Request timed out",
                    recoverySuggestion: "The server took too long to respond",
                    onRetry: {},
                    onDismiss: {}
                )
            }
            .padding()
        }
    }
#endif
