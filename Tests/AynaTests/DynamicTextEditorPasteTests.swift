#if os(macOS)

    import AppKit
    @testable import Ayna
    import SwiftUI
    import Testing

    @Suite("Dynamic Text Editor Paste Tests", .serialized)
    @MainActor
    struct DynamicTextEditorPasteTests {
        @Test(.timeLimit(.minutes(1)))
        func `image-only clipboard enables the Paste command`() throws {
            let pasteboard = NSPasteboard.general
            let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
            defer { snapshot.restore(to: pasteboard) }

            let imageData = try #require(Data(base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
            let image = try #require(NSImage(data: imageData))
            pasteboard.clearContents()
            #expect(pasteboard.writeObjects([image]))

            let state = EditorState()
            let editor = DynamicTextEditor(
                text: Binding(
                    get: { state.text },
                    set: { state.text = $0 }
                ),
                isFirstResponder: Binding(
                    get: { state.isFirstResponder },
                    set: { state.isFirstResponder = $0 }
                ),
                pasteImportSessionID: Binding(
                    get: { state.pasteImportSessionID },
                    set: { state.pasteImportSessionID = $0 }
                ),
                isImportingPastedImages: Binding(
                    get: { state.isImportingPastedImages },
                    set: { state.isImportingPastedImages = $0 }
                ),
                onSubmit: {},
                onPasteImages: { _ in },
                accessibilityIdentifier: "test.dynamicTextEditor"
            )
            let host = NSHostingView(rootView: editor)
            host.frame = NSRect(x: 0, y: 0, width: 480, height: 120)
            let window = NSWindow(
                contentRect: host.frame,
                styleMask: [],
                backing: .buffered,
                defer: false
            )
            window.contentView = host
            host.layoutSubtreeIfNeeded()

            let textView = try #require(Self.findTextView(in: host))
            #expect(String(describing: type(of: textView)).contains("PasteAwareTextView"))

            let pasteMenuItem = NSMenuItem(
                title: "Paste",
                action: #selector(NSText.paste(_:)),
                keyEquivalent: "v"
            )
            #expect(textView.validateUserInterfaceItem(pasteMenuItem))
        }

        private static func findTextView(in view: NSView) -> NSTextView? {
            if let scrollView = view as? NSScrollView,
               let textView = scrollView.documentView as? NSTextView
            {
                return textView
            }
            for subview in view.subviews {
                if let textView = findTextView(in: subview) {
                    return textView
                }
            }
            return nil
        }
    }

    @MainActor
    private final class EditorState {
        var text = ""
        var isFirstResponder = false
        var pasteImportSessionID = UUID()
        var isImportingPastedImages = false
    }

    private struct PasteboardSnapshot {
        private struct Item {
            let values: [(type: NSPasteboard.PasteboardType, data: Data)]
        }

        private let items: [Item]

        init(pasteboard: NSPasteboard) {
            items = (pasteboard.pasteboardItems ?? []).map { item in
                Item(values: item.types.compactMap { type in
                    item.data(forType: type).map { (type, $0) }
                })
            }
        }

        func restore(to pasteboard: NSPasteboard) {
            pasteboard.clearContents()
            let pasteboardItems = items.compactMap { item -> NSPasteboardItem? in
                guard !item.values.isEmpty else { return nil }
                let pasteboardItem = NSPasteboardItem()
                for value in item.values {
                    pasteboardItem.setData(value.data, forType: value.type)
                }
                return pasteboardItem
            }
            if !pasteboardItems.isEmpty {
                pasteboard.writeObjects(pasteboardItems)
            }
        }
    }

#endif
