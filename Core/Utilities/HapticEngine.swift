//
//  HapticEngine.swift
//  ayna
//
//  Design System: Haptic Feedback
//  Centralized haptic feedback for consistent tactile responses.
//  Automatically respects system haptic settings.
//

import SwiftUI

// MARK: - HapticEngine

/// Centralized haptic feedback engine for the Ayna design system.
/// Provides consistent tactile feedback across all interactions.
///
/// Usage:
/// ```swift
/// HapticEngine.impact(.light)
/// HapticEngine.notification(.success)
/// HapticEngine.selection()
/// ```
public enum HapticEngine {
    // MARK: - Impact Feedback

    /// Triggers impact feedback with the specified intensity.
    /// Use for button taps, toggles, and other direct interactions.
    ///
    /// - Parameter style: The intensity of the impact (light, medium, heavy, soft, rigid)
    public static func impact(_ style: ImpactStyle) {
        #if os(iOS)
            let generator = switch style {
            case .light:
                UIImpactFeedbackGenerator(style: .light)
            case .medium:
                UIImpactFeedbackGenerator(style: .medium)
            case .heavy:
                UIImpactFeedbackGenerator(style: .heavy)
            case .soft:
                UIImpactFeedbackGenerator(style: .soft)
            case .rigid:
                UIImpactFeedbackGenerator(style: .rigid)
            }
            generator.impactOccurred()
        #elseif os(watchOS)
            // watchOS uses WKInterfaceDevice for haptics
            WKInterfaceDevice.current().play(style.watchOSHapticType)
        #endif
    }

    /// Impact feedback styles
    public enum ImpactStyle {
        /// Light impact - for subtle interactions like hover states
        case light
        /// Medium impact - standard for button taps
        case medium
        /// Heavy impact - for significant actions
        case heavy
        /// Soft impact - for gentle feedback
        case soft
        /// Rigid impact - for firm feedback
        case rigid

        #if os(watchOS)
            var watchOSHapticType: WKHapticType {
                switch self {
                case .light, .soft:
                    .click
                case .medium:
                    .click
                case .heavy, .rigid:
                    .directionUp
                }
            }
        #endif
    }

    // MARK: - Notification Feedback

    /// Triggers notification feedback for status changes.
    /// Use for success, warning, and error states.
    ///
    /// - Parameter type: The type of notification (success, warning, error)
    public static func notification(_ type: NotificationType) {
        #if os(iOS)
            let generator = UINotificationFeedbackGenerator()
            switch type {
            case .success:
                generator.notificationOccurred(.success)
            case .warning:
                generator.notificationOccurred(.warning)
            case .error:
                generator.notificationOccurred(.error)
            }
        #elseif os(watchOS)
            WKInterfaceDevice.current().play(type.watchOSHapticType)
        #endif
    }

    /// Notification feedback types
    public enum NotificationType {
        /// Success - message sent, action completed
        case success
        /// Warning - rate limit approaching, recoverable error
        case warning
        /// Error - message failed, connection lost
        case error

        #if os(watchOS)
            var watchOSHapticType: WKHapticType {
                switch self {
                case .success:
                    .success
                case .warning:
                    .retry
                case .error:
                    .failure
                }
            }
        #endif
    }

    // MARK: - Selection Feedback

    /// Triggers selection feedback for picker/selection changes.
    /// Use for model selection, conversation switching, etc.
    public static func selection() {
        #if os(iOS)
            let generator = UISelectionFeedbackGenerator()
            generator.selectionChanged()
        #elseif os(watchOS)
            WKInterfaceDevice.current().play(.click)
        #endif
    }

    // MARK: - Semantic Haptic Actions

    /// Haptic feedback when a message is sent
    public static func messageSent() {
        notification(.success)
    }

    /// Haptic feedback when a message fails to send
    public static func messageFailed() {
        notification(.error)
    }

    /// Haptic feedback when tapping send button
    public static func sendButtonTap() {
        impact(.medium)
    }

    /// Haptic feedback when tapping cancel/stop button
    public static func cancelButtonTap() {
        impact(.light)
    }

    /// Haptic feedback when model selection changes
    public static func modelChanged() {
        selection()
    }

    /// Haptic feedback when long-pressing to show context menu
    public static func contextMenuAppear() {
        impact(.rigid)
    }

    /// Haptic feedback when pulling to refresh
    public static func pullToRefresh() {
        impact(.soft)
    }

    /// Haptic feedback when reaching a swipe action threshold
    public static func swipeActionThreshold() {
        impact(.medium)
    }

    /// Haptic feedback when AI response starts streaming
    public static func responseStarted() {
        impact(.soft)
    }

    /// Haptic feedback when AI response completes
    public static func responseCompleted() {
        impact(.light)
    }

    /// Haptic feedback for new conversation creation
    public static func newConversation() {
        impact(.light)
    }

    /// Haptic feedback for delete action
    public static func deleteAction() {
        notification(.warning)
    }
}

// MARK: - watchOS Support

#if os(watchOS)
    import WatchKit
#endif
