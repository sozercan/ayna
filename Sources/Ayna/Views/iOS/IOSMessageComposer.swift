#if os(iOS)
//
//  IOSMessageComposer.swift
//  ayna
//
//  Created on 11/24/25.
//

import ImageIO
import os.log
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A reusable message composer component for iOS chat views.
/// Handles text input, file attachments, sending messages, and generation cancellation.
/// Uses spring animations for smooth height transitions as text expands.
struct IOSMessageComposer: View {
    @Binding var messageText: String
    @Binding var isGenerating: Bool
    @Binding var errorMessage: String?
    @Binding var attachedFiles: [URL]
    @Binding var attachedImages: [UIImage]
    @Binding var pastedImages: [PastedImage]
    @Binding var pasteImportSessionID: UUID
    @Binding var isImportingPastedImages: Bool

    /// Optional recovery suggestion for the current error
    var errorRecoverySuggestion: String?

    /// Optional retry action for failed messages
    var onRetry: (() -> Void)?

    let showAttachmentButton: Bool
    let onSend: () -> Void
    let onCancel: () -> Void
    let onFileAttachmentRequested: () -> Void
    let onPhotoAttachmentRequested: () -> Void

    /// Called when error is dismissed
    var onDismissError: (() -> Void)?

    /// Accessibility identifier prefix for this composer instance
    let identifierPrefix: String

    /// Whether to show the attachment source selection sheet
    @State private var showAttachmentSourceSheet = false

    /// Environment color scheme for theme-aware styling
    @Environment(\.colorScheme) private var colorScheme

    // MARK: - iOS 26 Liquid Glass Backgrounds with Fallback

    /// Background for the plus button - liquid glass on iOS 26+, solid on older
    @ViewBuilder
    private var composerButtonBackground: some View {
        #if compiler(>=6.2)
            if #available(iOS 26.0, *) {
                Circle().fill(.regularMaterial).glassEffect()
            } else {
                Color(uiColor: colorScheme == .dark ? .systemGray5 : .systemGray4)
            }
        #else
            Color(uiColor: colorScheme == .dark ? .systemGray5 : .systemGray4)
        #endif
    }

    /// Background for the text field - liquid glass on iOS 26+, solid on older
    @ViewBuilder
    private var composerFieldBackground: some View {
        #if compiler(>=6.2)
            if #available(iOS 26.0, *) {
                Capsule().fill(.regularMaterial).glassEffect()
            } else {
                Color(uiColor: colorScheme == .dark ? .secondarySystemBackground : .tertiarySystemFill)
            }
        #else
            Color(uiColor: colorScheme == .dark ? .secondarySystemBackground : .tertiarySystemFill)
        #endif
    }

    /// Background for the entire composer bar
    @ViewBuilder
    private var composerBarBackground: some View {
        if #available(iOS 26.0, *) {
            // Transparent on iOS 26 since elements have their own glass effect
            Color.clear
        } else {
            Color(uiColor: .systemBackground)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Color(uiColor: .separator).opacity(0.3))
                        .frame(height: 0.5)
                }
        }
    }

    init(
        messageText: Binding<String>,
        isGenerating: Binding<Bool>,
        errorMessage: Binding<String?>,
        attachedFiles: Binding<[URL]> = .constant([]),
        attachedImages: Binding<[UIImage]> = .constant([]),
        pastedImages: Binding<[PastedImage]> = .constant([]),
        pasteImportSessionID: Binding<UUID>,
        isImportingPastedImages: Binding<Bool>,
        errorRecoverySuggestion: String? = nil,
        onRetry: (() -> Void)? = nil,
        showAttachmentButton: Bool = true,
        identifierPrefix: String = "chat.composer",
        onSend: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onDismissError: (() -> Void)? = nil,
        onFileAttachmentRequested: @escaping () -> Void = {},
        onPhotoAttachmentRequested: @escaping () -> Void = {}
    ) {
        _messageText = messageText
        _isGenerating = isGenerating
        _errorMessage = errorMessage
        _attachedFiles = attachedFiles
        _attachedImages = attachedImages
        _pastedImages = pastedImages
        _pasteImportSessionID = pasteImportSessionID
        _isImportingPastedImages = isImportingPastedImages
        self.errorRecoverySuggestion = errorRecoverySuggestion
        self.onRetry = onRetry
        self.showAttachmentButton = showAttachmentButton
        self.identifierPrefix = identifierPrefix
        self.onSend = onSend
        self.onCancel = onCancel
        self.onDismissError = onDismissError
        self.onFileAttachmentRequested = onFileAttachmentRequested
        self.onPhotoAttachmentRequested = onPhotoAttachmentRequested
    }

    var body: some View {
        VStack(spacing: Spacing.sm) {
            // Error message display using ErrorBannerView
            if let errorMessage {
                ErrorBannerView(
                    message: errorMessage,
                    recoverySuggestion: errorRecoverySuggestion,
                    onRetry: onRetry,
                    onDismiss: {
                        self.errorMessage = nil
                        onDismissError?()
                    },
                    identifierPrefix: "\(identifierPrefix).error"
                )
                .padding(.horizontal)
            }

            // Attached files display
            if !attachedFiles.isEmpty || !attachedImages.isEmpty || !pastedImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.sm) {
                        ForEach(attachedFiles, id: \.self) { url in
                            attachmentChip(for: url)
                        }
                        ForEach(attachedImages.indices, id: \.self) { index in
                            imageAttachmentChip(for: attachedImages[index], at: index)
                        }
                        ForEach(pastedImages) { pastedImage in
                            pastedImageAttachmentChip(for: pastedImage)
                        }
                    }
                    .padding(.horizontal, Spacing.md)
                }
                .accessibilityIdentifier("\(identifierPrefix).attachmentsList")
            }

            // Input bar - iMessage style
            HStack(alignment: .center, spacing: Spacing.sm) {
                // Attachment button - iMessage style circular button
                if showAttachmentButton {
                    Button(action: { showAttachmentSourceSheet = true }) {
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color(uiColor: .label))
                    }
                    .frame(width: 34, height: 34)
                    .background(composerButtonBackground)
                    .clipShape(Circle())
                    .accessibilityLabel("Add attachment")
                    .accessibilityIdentifier("\(identifierPrefix).attachButton")
                    .confirmationDialog("Add Attachment", isPresented: $showAttachmentSourceSheet) {
                        Button {
                            onPhotoAttachmentRequested()
                        } label: {
                            Label("Photo Library", systemImage: "photo.on.rectangle")
                        }
                        .accessibilityIdentifier("\(identifierPrefix).attachPhotoButton")

                        Button {
                            onFileAttachmentRequested()
                        } label: {
                            Label("Choose File", systemImage: "folder")
                        }
                        .accessibilityIdentifier("\(identifierPrefix).attachFileButton")

                        Button("Cancel", role: .cancel) {}
                    }
                }

                // Text field container - iMessage style pill with inline send button
                HStack(alignment: .center, spacing: 0) {
                    IOSPasteAwareTextEditor(
                        text: $messageText,
                        pasteImportSessionID: $pasteImportSessionID,
                        isImportingPastedImages: $isImportingPastedImages,
                        remainingImageCapacity: { remainingImageCapacity },
                        placeholder: "Ask anything",
                        accessibilityIdentifier: "\(identifierPrefix).textEditor",
                        onSubmit: {
                            if canSend, !isGenerating {
                                handleSendOrCancel()
                            }
                        },
                        onPasteImages: { images in
                            pastedImages.append(contentsOf: images)
                        },
                        onPasteFailure: { message in
                            errorMessage = message
                        }
                    )
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("\(identifierPrefix).textEditor")

                    // Send/Stop button inside the text field - iMessage style
                    if hasSendableContent || isGenerating {
                        Button(action: handleSendOrCancel) {
                            Image(systemName: isGenerating ? "stop.circle.fill" : "arrow.up.circle.fill")
                                .font(.system(size: 26))
                                .foregroundStyle(isGenerating ? Theme.statusError : Theme.accent)
                                .symbolEffect(.pulse, options: .repeating, value: isGenerating)
                        }
                        .padding(.trailing, 5)
                        .disabled(!isGenerating && !canSend)
                        .accessibilityLabel(isGenerating ? "Stop generating" : "Send message")
                        .accessibilityIdentifier("\(identifierPrefix).sendButton")
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(minHeight: 34)
                .background(composerFieldBackground)
                .clipShape(Capsule())
                // Smooth spring animation when height changes from multiline text
                .animation(Motion.springSnappy, value: messageText.contains("\n") || messageText.count > 40)
                .animation(Motion.springSnappy, value: hasSendableContent || isGenerating)
            }
            .padding(.horizontal, Spacing.md)
        }
        .padding(.vertical, Spacing.sm)
        .background(composerBarBackground)
    }

    private func attachmentChip(for url: URL) -> some View {
        HStack(spacing: Spacing.xxs) {
            Image(systemName: "doc.fill")
                .font(Typography.caption)
            Text(url.lastPathComponent)
                .font(Typography.caption)
                .lineLimit(1)
            Button {
                attachedFiles.removeAll { $0 == url }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            .accessibilityIdentifier("\(identifierPrefix).attachment.remove.\(url.lastPathComponent)")
        }
        .padding(Spacing.xs)
        .background(Theme.backgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: Spacing.CornerRadius.md))
        .accessibilityIdentifier("\(identifierPrefix).attachment.\(url.lastPathComponent)")
    }

    private func imageAttachmentChip(for image: UIImage, at index: Int) -> some View {
        HStack(spacing: Spacing.xxs) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Text("Image \(index + 1)")
                .font(Typography.caption)
                .lineLimit(1)
            Button {
                attachedImages.remove(at: index)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            .accessibilityIdentifier("\(identifierPrefix).attachment.remove.image\(index)")
        }
        .padding(Spacing.xs)
        .background(Theme.backgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: Spacing.CornerRadius.md))
        .accessibilityIdentifier("\(identifierPrefix).attachment.image\(index)")
    }

    private func pastedImageAttachmentChip(for pastedImage: PastedImage) -> some View {
        HStack(spacing: Spacing.xxs) {
            IOSPastedImageThumbnail(pastedImage: pastedImage)
            Text("Pasted image")
                .font(Typography.caption)
                .lineLimit(1)
            Button {
                pastedImages.removeAll { $0.id == pastedImage.id }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            .accessibilityIdentifier("\(identifierPrefix).attachment.remove.\(pastedImage.id.uuidString)")
            .accessibilityLabel("Remove pasted image")
        }
        .padding(Spacing.xs)
        .background(Theme.backgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: Spacing.CornerRadius.md))
        .accessibilityIdentifier("\(identifierPrefix).attachment.\(pastedImage.id.uuidString)")
    }

    private var hasSendableContent: Bool {
        ChatDraftContent.isSendable(
            text: messageText,
            fileURLs: attachedFiles,
            inMemoryImageCount: attachedImages.count + pastedImages.count
        )
    }

    private var canSend: Bool {
        hasSendableContent && !isImportingPastedImages
    }

    private var remainingImageCapacity: Int {
        ChatDraftContent.remainingImageCapacity(
            fileURLs: attachedFiles,
            inMemoryImageCount: attachedImages.count + pastedImages.count
        )
    }

    private func handleSendOrCancel() {
        if isGenerating {
            // Use centralized haptic engine
            HapticEngine.cancelButtonTap()

            DiagnosticsLogger.log(
                .chatView,
                level: .info,
                message: "🛑 User requested generation cancellation"
            )
            onCancel()
        } else {
            guard canSend else { return }
            // Use centralized haptic engine
            HapticEngine.sendButtonTap()

            DiagnosticsLogger.log(
                .chatView,
                level: .info,
                message: "📤 User sending message",
                metadata: ["textLength": "\(messageText.count)"]
            )
            onSend()
        }
    }
}

private struct IOSPastedImageThumbnail: View {
    let pastedImage: PastedImage

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: "photo")
            }
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
        .task(id: pastedImage.id) {
            let data = pastedImage.data
            let thumbnail = await Task.detached(priority: .utility) { () -> CGImage? in
                guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                    return nil
                }
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 96,
                    kCGImageSourceShouldCacheImmediately: true,
                ]
                return CGImageSourceCreateThumbnailAtIndex(
                    source,
                    0,
                    options as CFDictionary
                )
            }.value
            guard !Task.isCancelled, let thumbnail else { return }
            image = UIImage(cgImage: thumbnail)
        }
    }
}

private struct IOSPasteAwareTextEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var pasteImportSessionID: UUID
    @Binding var isImportingPastedImages: Bool

    let remainingImageCapacity: () -> Int
    let placeholder: String
    let accessibilityIdentifier: String
    let onSubmit: () -> Void
    let onPasteImages: ([PastedImage]) -> Void
    let onPasteFailure: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> PasteAwareTextView {
        let textView = PasteAwareTextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.returnKeyType = .send
        textView.textContainerInset = UIEdgeInsets(top: 7, left: 16, bottom: 7, right: 8)
        textView.textContainer.lineFragmentPadding = 0
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.accessibilityIdentifier = accessibilityIdentifier
        textView.accessibilityLabel = placeholder
        textView.placeholder = placeholder
        configurePasteHandling(for: textView)
        textView.onPasteFailure = onPasteFailure
        textView.text = text
        textView.updatePlaceholderVisibility()
        return textView
    }

    func updateUIView(_ textView: PasteAwareTextView, context: Context) {
        context.coordinator.parent = self
        configurePasteHandling(for: textView)
        textView.onPasteFailure = onPasteFailure
        textView.placeholder = placeholder
        textView.accessibilityLabel = placeholder
        if textView.text != text {
            textView.text = text
        }
        textView.updatePlaceholderVisibility()
        textView.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: PasteAwareTextView,
        context _: Context
    ) -> CGSize? {
        let width = proposal.width ?? 280
        let fittingSize = uiView.sizeThatFits(CGSize(
            width: width,
            height: CGFloat.greatestFiniteMagnitude
        ))
        let lineHeight = uiView.font?.lineHeight ?? 20
        let insets = uiView.textContainerInset.top + uiView.textContainerInset.bottom
        let maximumHeight = ceil((lineHeight * 5) + insets)
        let height = min(max(fittingSize.height, 34), maximumHeight)
        uiView.isScrollEnabled = fittingSize.height > maximumHeight
        return CGSize(width: width, height: height)
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

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: IOSPasteAwareTextEditor

        init(parent: IOSPasteAwareTextEditor) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            (textView as? PasteAwareTextView)?.updatePlaceholderVisibility()
            textView.invalidateIntrinsicContentSize()
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn _: NSRange,
            replacementText text: String
        ) -> Bool {
            guard text == "\n" else { return true }
            if let pasteAwareTextView = textView as? PasteAwareTextView,
               pasteAwareTextView.isInsertingModifiedNewline
            {
                return true
            }
            parent.onSubmit()
            return false
        }
    }
}

@MainActor
private final class PasteAwareTextView: UITextView {
    private let placeholderLabel = UILabel()
    private var pasteImportTail: Task<Void, Never>?
    private var pasteImportTasks: [UUID: Task<Void, Never>] = [:]
    private var pasteImportSessionID: UUID?
    private var reservedImageCount = 0

    var onPasteImages: (([PastedImage]) -> Void)?
    var onPasteFailure: ((String) -> Void)?
    var onPasteImportStateChange: ((Bool) -> Void)?
    var remainingImageCapacity: (() -> Int)?
    private(set) var isInsertingModifiedNewline = false
    var placeholder = "" {
        didSet { placeholderLabel.text = placeholder }
    }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        configurePlaceholder()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), UIPasteboard.general.hasImages {
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let containsShiftReturn = presses.contains { press in
            guard let key = press.key else { return false }
            return key.keyCode == .keyboardReturnOrEnter
                && key.modifierFlags.contains(.shift)
        }
        guard containsShiftReturn else {
            super.pressesBegan(presses, with: event)
            return
        }

        isInsertingModifiedNewline = true
        insertText("\n")
        isInsertingModifiedNewline = false
    }

    override func paste(_ sender: Any?) {
        let pasteboard = UIPasteboard.general
        let imageProviders = Self.imageProviders(from: pasteboard)
        guard !imageProviders.isEmpty else {
            super.paste(sender)
            return
        }

        if pasteboard.hasStrings {
            super.paste(sender)
        }

        let capacity = max(
            0,
            (remainingImageCapacity?() ?? ChatDraftContent.maximumImageCount)
                - reservedImageCount
        )
        let providers = Array(imageProviders.prefix(capacity))
        let initiallySkippedImageCount = max(0, imageProviders.count - providers.count)
        guard !providers.isEmpty else {
            reportImageLimit()
            return
        }

        let reservationCount = providers.count
        reservedImageCount += reservationCount
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

            var images: [PastedImage] = []
            for provider in providers {
                if let image = await Self.loadImage(from: provider) {
                    images.append(image)
                }
                guard !Task.isCancelled,
                      pasteImportSessionID == expectedSessionID
                else {
                    return
                }
            }

            let finalCapacity = max(
                0,
                remainingImageCapacity?() ?? ChatDraftContent.maximumImageCount
            )
            let acceptedImages = Array(images.prefix(finalCapacity))
            guard !acceptedImages.isEmpty else {
                if finalCapacity == 0 {
                    reportImageLimit()
                    return
                }
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                DiagnosticsLogger.log(
                    .chatView,
                    level: .error,
                    message: "Failed to import pasted clipboard image"
                )
                onPasteFailure?("The pasted image could not be attached.")
                return
            }
            onPasteImages?(acceptedImages)

            let skippedImageCount = initiallySkippedImageCount
                + max(0, images.count - acceptedImages.count)
            if skippedImageCount > 0 {
                reportImageLimit()
            }
        }
        pasteImportTasks[importID] = importTask
        pasteImportTail = importTask
    }

    private static func imageProviders(from pasteboard: UIPasteboard) -> [NSItemProvider] {
        pasteboard.itemProviders.filter { provider in
            provider.registeredContentTypes.contains { $0.conforms(to: .image) }
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            invalidatePasteImports()
        }
    }

    func updatePasteImportSession(_ sessionID: UUID) {
        guard pasteImportSessionID != sessionID else { return }
        invalidatePasteImports()
        pasteImportSessionID = sessionID
    }

    func updatePlaceholderVisibility() {
        placeholderLabel.isHidden = !text.isEmpty
    }

    private func configurePlaceholder() {
        placeholderLabel.font = .preferredFont(forTextStyle: .body)
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.isUserInteractionEnabled = false
        addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            placeholderLabel.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        ])
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

    private func reportImageLimit() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        onPasteFailure?(
            "A draft can contain at most \(ChatDraftContent.maximumImageCount) images. Extra clipboard images were not attached."
        )
    }

    private static func loadImage(from provider: NSItemProvider) async -> PastedImage? {
        let load = ItemProviderImageLoad()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                load.start(provider: provider, continuation: continuation)
            }
        } onCancel: {
            load.cancel()
        }
    }
}

private final class ItemProviderImageLoad: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<PastedImage?, Never>?
    private var progress: Progress?
    private var isFinished = false

    func start(
        provider: NSItemProvider,
        continuation: CheckedContinuation<PastedImage?, Never>
    ) {
        let shouldStart = lock.withLock {
            guard !isFinished else { return false }
            self.continuation = continuation
            return true
        }
        guard shouldStart else {
            continuation.resume(returning: nil)
            return
        }

        let progress = provider.loadTransferable(type: PastedImage.self) { [self] result in
            finish(with: try? result.get())
        }
        let shouldCancel = lock.withLock {
            guard !isFinished else { return true }
            self.progress = progress
            return false
        }
        if shouldCancel {
            progress.cancel()
        }
    }

    func cancel() {
        let completion = lock.withLock {
            () -> (Progress?, CheckedContinuation<PastedImage?, Never>?)? in
            guard !isFinished else { return nil }
            isFinished = true
            let completion = (progress, continuation)
            progress = nil
            continuation = nil
            return completion
        }
        guard let completion else { return }
        completion.0?.cancel()
        completion.1?.resume(returning: nil)
    }

    private func finish(with image: PastedImage?) {
        let continuation = lock.withLock { () -> CheckedContinuation<PastedImage?, Never>? in
            guard !isFinished else { return nil }
            isFinished = true
            progress = nil
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: image)
    }
}

// MARK: - File Attachment Utilities

enum IOSFileAttachmentUtils {
    /// Returns the MIME type for a given file URL based on its extension.
    static func getMimeType(for url: URL) -> String {
        let pathExtension = url.pathExtension.lowercased()
        switch pathExtension {
        case "jpg", "jpeg":
            return "image/jpeg"
        case "png":
            return "image/png"
        case "gif":
            return "image/gif"
        case "webp":
            return "image/webp"
        case "pdf":
            return "application/pdf"
        case "txt", "md":
            return "text/plain"
        case "json":
            return "application/json"
        default:
            return "application/octet-stream"
        }
    }

    /// Processes attached files into Message.FileAttachment array.
    /// Properly handles security-scoped resources with defer to prevent leaks.
    static func processAttachments(from urls: [URL]) -> (attachments: [Message.FileAttachment], errors: [String]) {
        var attachments: [Message.FileAttachment] = []
        var errors: [String] = []

        for url in urls {
            let didStart = url.startAccessingSecurityScopedResource()
            // Use defer to ensure resource is always released
            defer {
                if didStart {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let data = try Data(contentsOf: url)
                attachments.append(Message.FileAttachment(
                    fileName: url.lastPathComponent,
                    mimeType: getMimeType(for: url),
                    data: data
                ))
                DiagnosticsLogger.log(
                    .chatView,
                    level: .info,
                    message: "📎 Processed attachment: \(url.lastPathComponent)",
                    metadata: ["size": "\(data.count)"]
                )
            } catch {
                let errorMsg = "Failed to read \(url.lastPathComponent): \(error.localizedDescription)"
                errors.append(errorMsg)
                DiagnosticsLogger.log(
                    .chatView,
                    level: .error,
                    message: "❌ \(errorMsg)"
                )
            }
        }

        return (attachments, errors)
    }

    /// Processes UIImage attachments from the photo library into Message.FileAttachment array.
    /// Compresses images to JPEG format for API compatibility.
    static func processImageAttachments(from images: [UIImage]) -> [Message.FileAttachment] {
        var attachments: [Message.FileAttachment] = []

        for (index, image) in images.enumerated() {
            // Compress to JPEG with reasonable quality for API upload
            // OpenAI recommends images under 20MB and low detail mode for smaller sizes
            guard let imageData = image.jpegData(compressionQuality: 0.8) else {
                DiagnosticsLogger.log(
                    .chatView,
                    level: .error,
                    message: "❌ Failed to convert image \(index + 1) to JPEG data"
                )
                continue
            }

            let fileName = "photo_\(index + 1).jpg"
            attachments.append(Message.FileAttachment(
                fileName: fileName,
                mimeType: "image/jpeg",
                data: imageData
            ))

            DiagnosticsLogger.log(
                .chatView,
                level: .info,
                message: "📷 Processed image attachment: \(fileName)",
                metadata: ["size": "\(imageData.count)", "originalSize": "\(image.size)"]
            )
        }

        return attachments
    }
}
#endif
