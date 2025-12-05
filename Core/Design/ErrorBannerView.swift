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

    /// Dismiss action - always required to clear the error
    let onDismiss: () -> Void

    /// Accessibility identifier prefix for testing
    var identifierPrefix: String = "error.banner"

    /// Creates an error banner view.
    /// - Parameters:
    ///   - message: The primary error message
    ///   - recoverySuggestion: Optional recovery guidance (e.g., "Check your API key in Settings")
    ///   - onRetry: Optional retry action closure
    ///   - onDismiss: Dismiss action closure (required)
    ///   - identifierPrefix: Accessibility identifier prefix for testing
    public init(
        message: String,
        recoverySuggestion: String? = nil,
        onRetry: (() -> Void)? = nil,
        onDismiss: @escaping () -> Void,
        identifierPrefix: String = "error.banner"
    ) {
        self.message = message
        self.recoverySuggestion = recoverySuggestion
        self.onRetry = onRetry
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
        VStack(alignment: .leading, spacing: Spacing.xs) {
            // Primary error row with icon and dismiss
            HStack(alignment: .top, spacing: Spacing.sm) {
                // Warning icon
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: Typography.IconSize.lg))
                    .foregroundStyle(Theme.statusError)
                    .accessibilityHidden(true)

                // Message text
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(message)
                        .font(Typography.body)
                        .foregroundStyle(Theme.statusError)
                        .lineLimit(3)

                    // Recovery suggestion (secondary text)
                    if let suggestion = recoverySuggestion {
                        Text(suggestion)
                            .font(Typography.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: Spacing.sm)

                // Dismiss button
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

            // Retry button row (if retry action provided)
            if let retry = onRetry {
                HStack {
                    Spacer()
                    Button(action: retry) {
                        HStack(spacing: Spacing.xxs) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: Typography.IconSize.sm))
                            Text("Retry")
                                .font(Typography.buttonSmall)
                        }
                        .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: Spacing.minTouchTarget)
                    .accessibilityLabel("Retry")
                    .accessibilityIdentifier("\(identifierPrefix).retry")
                }
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(Theme.statusError.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: Spacing.CornerRadius.sm))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityMessage)
        .accessibilityIdentifier("\(identifierPrefix).container")
    }

    // MARK: - watchOS Layout (Compact)

    private var watchOSLayout: some View {
        VStack(spacing: Spacing.sm) {
            // Error message
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(Theme.statusError)
                .multilineTextAlignment(.center)
                .lineLimit(3)

            // Recovery suggestion
            if let suggestion = recoverySuggestion {
                Text(suggestion)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }

            // Action buttons
            HStack(spacing: Spacing.md) {
                if let retry = onRetry {
                    Button(action: retry) {
                        HStack(spacing: Spacing.xxs) {
                            Image(systemName: "arrow.clockwise")
                            Text("Retry")
                        }
                        .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .accessibilityIdentifier("\(identifierPrefix).retry")
                }

                Button(action: onDismiss) {
                    Text("Dismiss")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("\(identifierPrefix).dismiss")
            }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.sm)
        .background(Theme.statusError.opacity(0.15))
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
        onDismiss: @escaping () -> Void,
        identifierPrefix: String = "error.banner"
    ) {
        self.init(
            message: error.errorDescription ?? error.localizedDescription,
            recoverySuggestion: error.recoverySuggestion,
            onRetry: onRetry,
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
