#if os(macOS)
//
//  DynamicTextEditor.swift
//  ayna
//
//  Created on 11/20/25.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Dynamic Text Editor with auto-sizing and keyboard shortcuts
struct DynamicTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFirstResponder: Bool
    @Binding var pasteImportSessionID: UUID
    @Binding var isImportingPastedImages: Bool
    let remainingImageCapacity: () -> Int
    let onSubmit: () -> Void
    let onPasteImages: ([PastedImage]) -> Void
    let accessibilityIdentifier: String?

    typealias Coordinator = DynamicTextEditorCoordinator

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let contentSize = scrollView.contentSize
        let textView = PasteAwareTextView(frame: NSRect(origin: .zero, size: contentSize))
        scrollView.documentView = textView

        context.coordinator.onSubmit = onSubmit
        textView.delegate = context.coordinator
        configurePasteHandling(for: textView)
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
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
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )

        if let identifier = accessibilityIdentifier {
            textView.setAccessibilityIdentifier(identifier)
            scrollView.setAccessibilityIdentifier("\(identifier).scrollView")
        }

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
        if let pasteAwareTextView = textView as? PasteAwareTextView {
            configurePasteHandling(for: pasteAwareTextView)
        }
        if let identifier = accessibilityIdentifier {
            textView.setAccessibilityIdentifier(identifier)
            scrollView.setAccessibilityIdentifier("\(identifier).scrollView")
        }

        syncFirstResponderState(for: textView)
    }

    func makeCoordinator() -> Coordinator {
        DynamicTextEditorCoordinator(self)
    }

    private func configurePasteHandling(for textView: PasteAwareTextView) {
        let expectedSessionID = pasteImportSessionID
        textView.updatePasteImportSession(expectedSessionID)
        textView.remainingImageCapacity = remainingImageCapacity
        textView.onPasteImages = { images in
            guard pasteImportSessionID == expectedSessionID else { return }
            onPasteImages(images)
        }
        textView.onPasteImportStateChange = { isImporting in
            isImportingPastedImages = isImporting
        }
    }

    private func syncFirstResponderState(for textView: NSTextView, retryCount: Int = 8) {
        let shouldFocus = isFirstResponder
        Task { @MainActor in
            guard let window = textView.window else {
                guard shouldFocus, retryCount > 0 else { return }
                try? await Task.sleep(for: .milliseconds(50))
                syncFirstResponderState(for: textView, retryCount: retryCount - 1)
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

@MainActor
private final class PasteAwareTextView: NSTextView {
    private struct Candidate: Sendable {
        let data: Data
        let contentTypeIdentifier: String
    }

    private enum CandidateSource {
        case item(NSPasteboardItem)
        case preloaded(Candidate)
    }

    private struct CandidateSelection {
        let sources: [CandidateSource]
        let skippedImageCount: Int
        let hasImageCandidates: Bool
    }

    private static let supportedImageTypes: [(
        pasteboardType: NSPasteboard.PasteboardType,
        contentType: UTType
    )] = [
        (.init(UTType.png.identifier), .png),
        (.init(UTType.jpeg.identifier), .jpeg),
        (.init(UTType.gif.identifier), .gif),
        (.init(UTType.webP.identifier), .webP),
        (.init(UTType.tiff.identifier), .tiff),
        (.init(UTType.heic.identifier), .heic),
    ]

    var onPasteImages: (([PastedImage]) -> Void)?
    var onPasteImportStateChange: ((Bool) -> Void)?
    var remainingImageCapacity: (() -> Int)?
    private var pasteImportTail: Task<Void, Never>?
    private var pasteImportTasks: [UUID: Task<Void, Never>] = [:]
    private var pasteImportSessionID: UUID?
    private var reservedImageCount = 0

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), Self.hasImageCandidates(in: .general) {
            return true
        }
        return super.validateUserInterfaceItem(item)
    }

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        let capacity = max(
            0,
            (remainingImageCapacity?() ?? ChatDraftContent.maximumImageCount)
                - reservedImageCount
        )
        let selection = Self.imageCandidateSelection(
            from: pasteboard,
            limit: capacity
        )
        guard selection.hasImageCandidates else {
            super.paste(sender)
            return
        }

        if pasteboard.string(forType: .string) != nil {
            super.paste(sender)
        }

        guard !selection.sources.isEmpty else {
            reportImageLimit(skippedImageCount: selection.skippedImageCount)
            return
        }

        let selectedSourceCount = selection.sources.count
        reservedImageCount += selectedSourceCount
        let candidates = selection.sources.compactMap(Self.loadCandidate)
        let failedCandidateCount = selectedSourceCount - candidates.count
        reservedImageCount -= failedCandidateCount
        let reservationCount = candidates.count
        guard reservationCount > 0 else {
            NSSound.beep()
            DiagnosticsLogger.log(
                .chatView,
                level: .error,
                message: "Failed to load pasted clipboard image data"
            )
            return
        }

        let previousTask = pasteImportTail
        let expectedSessionID = pasteImportSessionID
        let importID = UUID()
        onPasteImportStateChange?(true)
        let importTask = Task { @MainActor [weak self] in
            await previousTask?.value
            guard let self else { return }
            defer {
                self.releaseImageReservation(
                    reservationCount,
                    sessionID: expectedSessionID
                )
                self.finishPasteImport(importID, sessionID: expectedSessionID)
            }
            guard !Task.isCancelled,
                  pasteImportSessionID == expectedSessionID
            else {
                return
            }

            let conversionTask = Task.detached(priority: .userInitiated) {
                var images: [PastedImage] = []
                for candidate in candidates {
                    guard !Task.isCancelled else { break }
                    guard let contentType = UTType(candidate.contentTypeIdentifier) else {
                        continue
                    }
                    if let image = try? PastedImage.importing(
                        data: candidate.data,
                        contentType: contentType
                    ) {
                        images.append(image)
                    }
                }
                return images
            }
            let images = await withTaskCancellationHandler {
                await conversionTask.value
            } onCancel: {
                conversionTask.cancel()
            }

            guard !Task.isCancelled,
                  pasteImportSessionID == expectedSessionID
            else {
                return
            }

            let finalCapacity = max(
                0,
                remainingImageCapacity?() ?? ChatDraftContent.maximumImageCount
            )
            let acceptedImages = Array(images.prefix(finalCapacity))
            guard !acceptedImages.isEmpty else {
                if finalCapacity == 0 {
                    reportImageLimit(
                        skippedImageCount: selection.skippedImageCount + images.count
                    )
                    return
                }
                NSSound.beep()
                DiagnosticsLogger.log(
                    .chatView,
                    level: .error,
                    message: "Failed to import pasted clipboard image"
                )
                return
            }
            onPasteImages?(acceptedImages)

            let skippedImageCount = selection.skippedImageCount
                + max(0, images.count - acceptedImages.count)
            if skippedImageCount > 0 {
                reportImageLimit(skippedImageCount: skippedImageCount)
            }
        }
        pasteImportTasks[importID] = importTask
        pasteImportTail = importTask
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            invalidatePasteImports()
        }
    }

    func updatePasteImportSession(_ sessionID: UUID) {
        guard pasteImportSessionID != sessionID else { return }
        invalidatePasteImports()
        pasteImportSessionID = sessionID
    }

    private static func imageCandidateSelection(
        from pasteboard: NSPasteboard,
        limit: Int
    ) -> CandidateSelection {
        if let pasteboardItems = pasteboard.pasteboardItems, !pasteboardItems.isEmpty {
            let supportedTypes = Set(supportedImageTypes.map(\.pasteboardType))
            var selectedItems: [CandidateSource] = []
            var imageItemCount = 0
            for item in pasteboardItems where !supportedTypes.isDisjoint(with: item.types) {
                imageItemCount += 1
                if selectedItems.count < limit {
                    selectedItems.append(.item(item))
                }
            }
            return CandidateSelection(
                sources: selectedItems,
                skippedImageCount: max(0, imageItemCount - selectedItems.count),
                hasImageCandidates: imageItemCount > 0
            )
        }

        for supportedType in supportedImageTypes {
            if limit == 0,
               pasteboard.availableType(from: [supportedType.pasteboardType]) != nil
            {
                return CandidateSelection(
                    sources: [],
                    skippedImageCount: 1,
                    hasImageCandidates: true
                )
            }
            if let data = pasteboard.data(forType: supportedType.pasteboardType) {
                return CandidateSelection(
                    sources: [
                        .preloaded(Candidate(
                            data: data,
                            contentTypeIdentifier: supportedType.contentType.identifier
                        )),
                    ],
                    skippedImageCount: 0,
                    hasImageCandidates: true
                )
            }
        }
        return CandidateSelection(
            sources: [],
            skippedImageCount: 0,
            hasImageCandidates: false
        )
    }

    private static func loadCandidate(_ source: CandidateSource) -> Candidate? {
        switch source {
        case let .item(item):
            for supportedType in supportedImageTypes {
                if let data = item.data(forType: supportedType.pasteboardType) {
                    return Candidate(
                        data: data,
                        contentTypeIdentifier: supportedType.contentType.identifier
                    )
                }
            }
            return nil
        case let .preloaded(candidate):
            return candidate
        }
    }

    private static func hasImageCandidates(in pasteboard: NSPasteboard) -> Bool {
        let supportedTypes = Set(supportedImageTypes.map(\.pasteboardType))

        if let pasteboardItems = pasteboard.pasteboardItems, !pasteboardItems.isEmpty {
            return pasteboardItems.contains { item in
                !supportedTypes.isDisjoint(with: item.types)
            }
        }

        return pasteboard.availableType(from: Array(supportedTypes)) != nil
    }

    private func invalidatePasteImports() {
        let hadActiveImports = !pasteImportTasks.isEmpty
        for task in pasteImportTasks.values {
            task.cancel()
        }
        pasteImportTasks.removeAll()
        pasteImportTail = nil
        reservedImageCount = 0
        if hadActiveImports {
            onPasteImportStateChange?(false)
        }
        pasteImportSessionID = nil
    }

    private func finishPasteImport(_ importID: UUID, sessionID: UUID?) {
        guard pasteImportSessionID == sessionID else { return }
        pasteImportTasks[importID] = nil
        if pasteImportTasks.isEmpty {
            pasteImportTail = nil
            onPasteImportStateChange?(false)
        }
    }

    private func releaseImageReservation(_ count: Int, sessionID: UUID?) {
        guard pasteImportSessionID == sessionID else { return }
        reservedImageCount = max(0, reservedImageCount - count)
    }

    private func reportImageLimit(skippedImageCount: Int) {
        NSSound.beep()
        DiagnosticsLogger.log(
            .chatView,
            level: .default,
            message: "Skipped clipboard images above the draft limit",
            metadata: ["skippedImageCount": "\(skippedImageCount)"]
        )
    }
}
#endif
