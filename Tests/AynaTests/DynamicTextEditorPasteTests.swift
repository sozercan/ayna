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

            let imageData = try #require(Self.imageData)
            let image = try #require(NSImage(data: imageData))
            pasteboard.clearContents()
            #expect(pasteboard.writeObjects([image]))

            let state = EditorState()
            let hostedEditor = try Self.hostEditor(state: state)
            let textView = hostedEditor.textView
            #expect(String(describing: type(of: textView)).contains("PasteAwareTextView"))

            let pasteMenuItem = NSMenuItem(
                title: "Paste",
                action: #selector(NSText.paste(_:)),
                keyEquivalent: "v"
            )
            #expect(textView.validateUserInterfaceItem(pasteMenuItem))
        }

        @Test(.timeLimit(.minutes(1)))
        func `mixed clipboard preserves text and imports its image`() async throws {
            let pasteboard = NSPasteboard.general
            let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
            defer { snapshot.restore(to: pasteboard) }

            let imageData = try #require(Self.imageData)
            let item = NSPasteboardItem()
            item.setString("Clipboard text", forType: .string)
            item.setData(imageData, forType: .init("public.png"))
            pasteboard.clearContents()
            #expect(pasteboard.writeObjects([item]))

            let state = EditorState()
            let hostedEditor = try Self.hostEditor(state: state)
            hostedEditor.textView.paste(nil)

            #expect(state.text == "Clipboard text")
            #expect(await Self.waitUntil {
                !state.isImportingPastedImages && state.pastedImages.count == 1
            })
            #expect(state.pastedImages.first?.mimeType == "image/png")
        }

        @Test(.timeLimit(.minutes(1)))
        func `paste caps image data loading before import`() async throws {
            let pasteboard = NSPasteboard.general
            let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
            defer { snapshot.restore(to: pasteboard) }

            let imageData = try #require(Self.imageData)
            let providers = (0 ... ChatDraftContent.maximumImageCount).map { _ in
                PasteboardImageDataProvider(data: imageData)
            }
            let items = providers.map { provider in
                let item = NSPasteboardItem()
                item.setDataProvider(provider, forTypes: [.init("public.png")])
                return item
            }
            pasteboard.clearContents()
            #expect(pasteboard.writeObjects(items))

            let state = EditorState()
            let hostedEditor = try Self.hostEditor(state: state)
            hostedEditor.textView.paste(nil)

            #expect(await Self.waitUntil {
                !state.isImportingPastedImages
                    && state.pastedImages.count == ChatDraftContent.maximumImageCount
            })
            #expect(providers.reduce(0) { $0 + $1.requestCount } == ChatDraftContent.maximumImageCount)
        }

        @Test(.timeLimit(.minutes(1)))
        func `repeated paste loads only the remaining draft capacity`() async throws {
            let pasteboard = NSPasteboard.general
            let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
            defer { snapshot.restore(to: pasteboard) }

            let imageData = try #require(Self.imageData)
            let state = EditorState()
            let hostedEditor = try Self.hostEditor(state: state)

            let firstProviders = (0 ..< 18).map { _ in
                PasteboardImageDataProvider(data: imageData)
            }
            pasteboard.clearContents()
            #expect(pasteboard.writeObjects(firstProviders.map { Self.pasteboardItem(for: $0) }))
            hostedEditor.textView.paste(nil)
            #expect(await Self.waitUntil {
                !state.isImportingPastedImages && state.pastedImages.count == 18
            })

            let secondProviders = (0 ..< 5).map { _ in
                PasteboardImageDataProvider(data: imageData)
            }
            pasteboard.clearContents()
            #expect(pasteboard.writeObjects(secondProviders.map { Self.pasteboardItem(for: $0) }))
            hostedEditor.textView.paste(nil)
            #expect(await Self.waitUntil {
                !state.isImportingPastedImages
                    && state.pastedImages.count == ChatDraftContent.maximumImageCount
            })

            #expect(firstProviders.reduce(0) { $0 + $1.requestCount } == 18)
            #expect(secondProviders.reduce(0) { $0 + $1.requestCount } == 2)
        }

        @Test(.timeLimit(.minutes(1)))
        func `rapid repeated paste reserves capacity before loading image data`() async throws {
            let pasteboard = NSPasteboard.general
            let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
            defer { snapshot.restore(to: pasteboard) }

            let imageData = try #require(Self.imageData)
            let existingImage = try PastedImage.importing(data: imageData, contentType: .png)
            let state = EditorState()
            state.pastedImages = Array(
                repeating: existingImage,
                count: ChatDraftContent.maximumImageCount - 2
            )
            let hostedEditor = try Self.hostEditor(state: state)
            let providers = (0 ..< 2).map { _ in
                PasteboardImageDataProvider(data: imageData)
            }
            pasteboard.clearContents()
            #expect(pasteboard.writeObjects(providers.map { Self.pasteboardItem(for: $0) }))

            hostedEditor.textView.paste(nil)
            hostedEditor.textView.paste(nil)

            #expect(await Self.waitUntil {
                !state.isImportingPastedImages
                    && state.pastedImages.count == ChatDraftContent.maximumImageCount
            })
            #expect(providers.reduce(0) { $0 + $1.requestCount } == 2)
        }

        @Test(.timeLimit(.minutes(1)))
        func `rotating the paste session discards every queued image import`() async throws {
            let pasteboard = NSPasteboard.general
            let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
            defer { snapshot.restore(to: pasteboard) }

            let imageData = try #require(Self.imageData)
            let item = NSPasteboardItem()
            item.setData(imageData, forType: .init("public.png"))
            pasteboard.clearContents()
            #expect(pasteboard.writeObjects([item]))

            let state = EditorState()
            let hostedEditor = try Self.hostEditor(state: state)
            hostedEditor.textView.paste(nil)
            hostedEditor.textView.paste(nil)
            #expect(state.isImportingPastedImages)

            state.pasteImportSessionID = UUID()
            hostedEditor.host.rootView = Self.editor(state: state)
            hostedEditor.host.layoutSubtreeIfNeeded()

            #expect(await Self.waitUntil { !state.isImportingPastedImages })
            try await Task.sleep(for: .milliseconds(50))
            #expect(state.pastedImages.isEmpty)
        }

        private static var imageData: Data? {
            Data(base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")
        }

        private static func editor(state: EditorState) -> DynamicTextEditor {
            DynamicTextEditor(
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
                remainingImageCapacity: {
                    max(0, ChatDraftContent.maximumImageCount - state.pastedImages.count)
                },
                onSubmit: {},
                onPasteImages: { state.pastedImages.append(contentsOf: $0) },
                accessibilityIdentifier: "test.dynamicTextEditor"
            )
        }

        private static func hostEditor(
            state: EditorState
        ) throws -> HostedEditor {
            let host = NSHostingView(rootView: editor(state: state))
            host.frame = NSRect(x: 0, y: 0, width: 480, height: 120)
            let window = NSWindow(
                contentRect: host.frame,
                styleMask: [],
                backing: .buffered,
                defer: false
            )
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            let textView = try #require(findTextView(in: host))
            return HostedEditor(host: host, window: window, textView: textView)
        }

        private static func waitUntil(
            timeout: Duration = .seconds(2),
            condition: @escaping @MainActor () -> Bool
        ) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while !condition(), clock.now < deadline {
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(10))
            }
            return condition()
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

        private static func pasteboardItem(
            for provider: PasteboardImageDataProvider
        ) -> NSPasteboardItem {
            let item = NSPasteboardItem()
            item.setDataProvider(provider, forTypes: [.init("public.png")])
            return item
        }

        private struct HostedEditor {
            let host: NSHostingView<DynamicTextEditor>
            let window: NSWindow
            let textView: NSTextView
        }
    }

    @MainActor
    private final class EditorState {
        var text = ""
        var isFirstResponder = false
        var pasteImportSessionID = UUID()
        var isImportingPastedImages = false
        var pastedImages: [PastedImage] = []
    }

    private final class PasteboardImageDataProvider: NSObject, NSPasteboardItemDataProvider {
        private let data: Data
        private(set) var requestCount = 0

        init(data: Data) {
            self.data = data
        }

        func pasteboard(
            _: NSPasteboard?,
            item: NSPasteboardItem,
            provideDataForType type: NSPasteboard.PasteboardType
        ) {
            requestCount += 1
            item.setData(data, forType: type)
        }
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
