import SwiftUI

public enum HapticEngine {
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
            WKInterfaceDevice.current().play(style.watchOSHapticType)
        #endif
    }

    public enum ImpactStyle {
        case light
        case medium
        case heavy
        case soft
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

    public enum NotificationType {
        case success
        case warning
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

    public static func selection() {
        #if os(iOS)
            let generator = UISelectionFeedbackGenerator()
            generator.selectionChanged()
        #elseif os(watchOS)
            WKInterfaceDevice.current().play(.click)
        #endif
    }

    public static func messageSent() {
        notification(.success)
    }

    public static func messageFailed() {
        notification(.error)
    }

    public static func sendButtonTap() {
        impact(.medium)
    }

    public static func cancelButtonTap() {
        impact(.light)
    }

    public static func modelChanged() {
        selection()
    }

    public static func contextMenuAppear() {
        impact(.rigid)
    }

    public static func pullToRefresh() {
        impact(.soft)
    }

    public static func swipeActionThreshold() {
        impact(.medium)
    }

    public static func responseStarted() {
        impact(.soft)
    }

    public static func responseCompleted() {
        impact(.light)
    }

    public static func newConversation() {
        impact(.light)
    }

    public static func deleteAction() {
        notification(.warning)
    }
}

#if os(watchOS)
    import WatchKit
#endif
