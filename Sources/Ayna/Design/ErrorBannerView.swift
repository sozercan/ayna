import SwiftUI

public struct ErrorBannerView: View {
    let message: String

    let recoverySuggestion: String?

    let onRetry: (() -> Void)?

    let onOpenSettings: (() -> Void)?

    let openSettingsTab: SettingsTab?

    let onDismiss: () -> Void

    var identifierPrefix: String = "error.banner"

    public init(
        message: String,
        recoverySuggestion: String? = nil,
        onRetry: (() -> Void)? = nil,
        onOpenSettings: (() -> Void)? = nil,
        openSettingsTab: SettingsTab? = nil,
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
                    if let tab = openSettingsTab {
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

    private var accessibilityMessage: String {
        if let suggestion = recoverySuggestion {
            return "Error: \(message). \(suggestion)"
        }
        return "Error: \(message)"
    }
}

public extension ErrorBannerView {
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

#if DEBUG
    struct ErrorBannerView_Previews: PreviewProvider {
        static var previews: some View {
            VStack(spacing: 20) {
                ErrorBannerView(
                    message: "Network connection failed",
                    onDismiss: {}
                )

                ErrorBannerView(
                    message: "Invalid API key",
                    recoverySuggestion: "Check your API key in Settings",
                    onDismiss: {}
                )

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
