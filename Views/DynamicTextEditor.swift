//
//  DynamicTextEditor.swift
//  ayna
//
//  Created on 11/20/25.
//

import AppKit
import SwiftUI

// Dynamic Text Editor with auto-sizing and keyboard shortcuts
struct DynamicTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFirstResponder: Bool
    let onSubmit: () -> Void
    let accessibilityIdentifier: String?

    typealias Coordinator = DynamicTextEditorCoordinator

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }

        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 15)
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false

        // Remove default scroll view padding
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.lineFragmentPadding = 0

        // Configure scroll view
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        if let identifier = accessibilityIdentifier {
            textView.setAccessibilityIdentifier(identifier)
            scrollView.setAccessibilityIdentifier("\(identifier).scrollView")
        }

        context.coordinator.onSubmit = onSubmit
        syncFirstResponderState(for: textView)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else {
            return
        }

        if textView.string != text {
            textView.string = text
        }

        context.coordinator.onSubmit = onSubmit
        if let identifier = accessibilityIdentifier {
            textView.setAccessibilityIdentifier(identifier)
            scrollView.setAccessibilityIdentifier("\(identifier).scrollView")
        }

        syncFirstResponderState(for: textView)
    }

    func makeCoordinator() -> Coordinator {
        DynamicTextEditorCoordinator(self)
    }

    private func syncFirstResponderState(for textView: NSTextView, retryCount: Int = 8) {
        let shouldFocus = isFirstResponder
        DispatchQueue.main.async {
            guard let window = textView.window else {
                guard shouldFocus, retryCount > 0 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    syncFirstResponderState(for: textView, retryCount: retryCount - 1)
                }
                return
            }

            if shouldFocus {
                if window.firstResponder !== textView {
                    window.makeFirstResponder(textView)
                }
            } else if window.firstResponder === textView {
                window.makeFirstResponder(nil)
            }
        }
    }
}

final class DynamicTextEditorCoordinator: NSObject, NSTextViewDelegate {
    let parent: DynamicTextEditor
    var onSubmit: (() -> Void)?

    init(_ parent: DynamicTextEditor) {
        self.parent = parent
    }

    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }
        parent.text = textView.string
    }

    func textDidBeginEditing(_ notification: Notification) {
        guard notification.object is NSTextView else { return }
        parent.isFirstResponder = true
    }

    func textDidEndEditing(_ notification: Notification) {
        guard notification.object is NSTextView else { return }
        parent.isFirstResponder = false
    }

    func textView(_: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSTextView.insertNewline(_:)) {
            let event = NSApp.currentEvent
            if event?.modifierFlags.isDisjoint(with: [.shift, .command, .option, .control]) ?? true {
                onSubmit?()
                return true
            }
        }
        return false
    }
}
