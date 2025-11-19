//
//  MessageView.swift
//  ayna
//
//  Created on 11/2/25.
//

import SwiftUI

struct MessageView: View {
    let message: Message
    var modelName: String?
    var onRetry: (() -> Void)?
    var onSwitchModel: ((String) -> Void)?
    @State private var isHovered = false
    @State private var showReasoning = false
    @State private var showModelMenu = false
    @EnvironmentObject var conversationManager: ConversationManager
    @ObservedObject private var openAIService = OpenAIService.shared

    // Performance: Cache parsed content blocks to avoid re-parsing on every render
    @State private var cachedContentBlocks: [ContentBlock] = []
    @State private var cachedReasoningBlocks: [ContentBlock] = []
    @State private var lastContentHash: Int = 0
    @State private var lastReasoningHash: Int = 0

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                // Avatar
                Circle()
                    .fill(message.role == .assistant ? Color.green.opacity(0.15) : Color.blue.opacity(0.15))
                    .frame(width: 30, height: 30)
                    .overlay(
                        Image(systemName: message.role == .assistant ? "sparkles" : "person.fill")
                            .font(.system(size: message.role == .assistant ? 13 : 14, weight: .medium))
                            .foregroundStyle(message.role == .assistant ? Color.green : Color.blue),
                    )

                // Content with markdown support
                VStack(alignment: .leading, spacing: 8) {
                    // Show model name for assistant messages
                    if message.role == .assistant, let model = modelName {
                        Text(model)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 4)
                    }

                    // Show attached images for user messages
                    if let attachments = message.attachments, !attachments.isEmpty {
                        ForEach(attachments.indices, id: \.self) { index in
                            let attachment = attachments[index]
                            if attachment.mimeType.starts(with: "image/"),
                               let nsImage = NSImage(data: attachment.data)
                            {
                                VStack(alignment: .leading, spacing: 4) {
                                    Image(nsImage: nsImage)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(maxWidth: 400)
                                        .cornerRadius(8)
                                        .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
                                        .contextMenu {
                                            Button("Save Image...") {
                                                saveImage(nsImage)
                                            }
                                            Button("Copy Image") {
                                                copyImage(nsImage)
                                            }
                                        }
                                    Text(attachment.fileName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    // Show generated image if present
                    if message.mediaType == .image {
                        if let imageData = message.imageData, let nsImage = NSImage(data: imageData) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: 512)
                                .cornerRadius(12)
                                .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
                                .contextMenu {
                                    Button("Save Image...") {
                                        saveImage(nsImage)
                                    }
                                    Button("Copy Image") {
                                        copyImage(nsImage)
                                    }
                                }
                        } else {
                            // Show loading animation while generating
                            ImageGeneratingView()
                        }
                    }

                    // Show typing indicator for empty assistant messages
                    if message.role == .assistant, message.content.isEmpty, message.mediaType != .image {
                        TypingIndicatorView()
                    }

                    // Show reasoning toggle if reasoning exists
                    if let reasoning = message.reasoning, !reasoning.isEmpty {
                        Button(action: {
                            withAnimation {
                                showReasoning.toggle()
                            }
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: showReasoning ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 11, weight: .medium))
                                Text("Thinking")
                                    .font(.system(size: 13, weight: .medium))
                                Spacer()
                                Text("\(reasoning.count) chars")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .foregroundStyle(.blue)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 10)
                            .background(Color.blue.opacity(0.08))
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)

                        if showReasoning {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(cachedReasoningBlocks, id: \.id) { block in
                                    block.view
                                }
                            }
                            .padding(12)
                            .background(Color.secondary.opacity(0.05))
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1),
                            )
                        }
                    }

                    ForEach(cachedContentBlocks, id: \.id) { block in
                        block.view
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    Text(
                        verbatim: message.content.isEmpty
                            ? (message.role == .assistant ? "Assistant response" : "User message")
                            : message.content,
                    ),
                )
                .accessibilityIdentifier("chat.message.\(message.id.uuidString)")
            }

            Spacer()

            // Action buttons
            HStack(spacing: 8) {
                // Copy button
                Button(action: {
                    copyToClipboard(message.content)
                }) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .padding(6)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
                }
                .buttonStyle(.plain)
        .accessibilityIdentifier("message.action.copy")

                // Menu button for assistant messages
                if message.role == .assistant {
                    Menu {
                        Section {
                            Text("Used \(modelName ?? message.model ?? "Unknown Model")")
                                .font(.system(size: 12))
                        }

                        Divider()

                        if let onRetry {
                            Button(action: onRetry) {
                                Label("Try Again", systemImage: "arrow.clockwise")
                            }
                        }

                        Menu {
                            ForEach(openAIService.customModels, id: \.self) { model in
                                Button(action: {
                                    onSwitchModel?(model)
                                }) {
                                    HStack {
                                        Text(model)
                                        // Check if this model was used for this message
                                        if model == modelName || model == message.model {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            Label("Switch Model", systemImage: "arrow.left.arrow.right")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .padding(6)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                            .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
            .opacity(isHovered ? 1 : 0)
            .frame(width: message.role == .assistant ? 72 : 32)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(isHovered ? Color.primary.opacity(0.03) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .onAppear {
            updateCachedBlocks()
        }
        .onChange(of: message.content) { _, _ in
            updateCachedBlocks()
        }
        .onChange(of: message.reasoning) { _, _ in
            updateCachedReasoningBlocks()
        }
    }

    private func updateCachedBlocks() {
        let newHash = message.content.hashValue
        if newHash != lastContentHash {
            cachedContentBlocks = MarkdownRenderer.parse(message.content)
            lastContentHash = newHash
        }
    }

    private func updateCachedReasoningBlocks() {
        if let reasoning = message.reasoning {
            let newHash = reasoning.hashValue
            if newHash != lastReasoningHash {
                cachedReasoningBlocks = MarkdownRenderer.parse(reasoning)
                lastReasoningHash = newHash
            }
        }
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func saveImage(_ image: NSImage) {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.png, .jpeg]
        savePanel.nameFieldStringValue = "generated-image.png"

        savePanel.begin { response in
            if response == .OK, let url = savePanel.url {
                if let tiffData = image.tiffRepresentation,
                   let bitmapImage = NSBitmapImageRep(data: tiffData),
                   let pngData = bitmapImage.representation(using: .png, properties: [:])
                {
                    try? pngData.write(to: url)
                }
            }
        }
    }

    private func copyImage(_ image: NSImage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }
}

struct ContentBlock: Identifiable {
    let id = UUID()
    let type: BlockType

    enum BlockType {
        case paragraph(AttributedString)
        case heading(level: Int, text: AttributedString)
        case unorderedList([AttributedString])
        case orderedList(start: Int, items: [AttributedString])
        case blockquote(AttributedString)
        case table(MarkdownTable)
        case divider
        case code(String, String)
        case tool(String, String)
    }

    @ViewBuilder
    var view: some View {
        switch type {
        case let .paragraph(text):
            Text(text)
                .font(.system(size: 15))
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

        case let .heading(level, text):
            let font: Font = switch level {
            case 1:
                .system(size: 22, weight: .bold)
            case 2:
                .system(size: 20, weight: .semibold)
            case 3:
                .system(size: 18, weight: .semibold)
            default:
                .system(size: 16, weight: .semibold)
            }
            Text(text)
                .font(font)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, level == 1 ? 4 : 2)

        case let .unorderedList(items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                            .font(.system(size: 16, weight: .semibold))
                            .accessibilityHidden(true)
                        Text(item)
                            .font(.system(size: 15))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, 2)
                    .accessibilityLabel("Bullet item \(index + 1)")
                }
            }

        case let .orderedList(start, items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: "\(start + offset).")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 32, alignment: .trailing)
                            .accessibilityHidden(true)
                        Text(item)
                            .font(.system(size: 15))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

        case let .blockquote(text):
            HStack(alignment: .top, spacing: 12) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 3)
                    .cornerRadius(3)

                Text(text)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(Color.secondary.opacity(0.08))
            .cornerRadius(10)

        case let .table(table):
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(spacing: 0) {
                    tableRowView(table.headers, alignments: table.alignments, isHeader: true)
                        .background(Color.secondary.opacity(0.12))
                    Divider()
                    ForEach(Array(table.rows.enumerated()), id: \.offset) { rowIndex, row in
                        tableRowView(row, alignments: table.alignments, isHeader: false)
                        if rowIndex < table.rows.count - 1 {
                            Divider()
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .background(Color.secondary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 8))

        case .divider:
            Divider()
                .overlay(Color.secondary.opacity(0.2))

        case let .code(code, language):
            VStack(alignment: .leading, spacing: 0) {
                // Header with language and copy button
                HStack {
                    if !language.isEmpty {
                        Text(language.lowercased())
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.lowercase)
                    }

                    Spacer()

                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.on.doc")
                            Text("Copy code")
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))

                Divider()

                // Code content with syntax highlighting
                ScrollView(.horizontal, showsIndicators: false) {
                    SyntaxHighlightedCodeView(code: code, language: language)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1),
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))

        case let .tool(name, result):
            VStack(alignment: .leading, spacing: 0) {
                // Tool header
                HStack(spacing: 8) {
                    Image(systemName: "wrench.and.screwdriver.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(
                            LinearGradient(
                                colors: [Color.blue, Color.blue.opacity(0.8)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing,
                            ),
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tool")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        Text(name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                    }

                    Spacer()

                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.green)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.blue.opacity(0.08))

                Divider()

                // Tool result
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(result)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
            }
            .background(Color.blue.opacity(0.03))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.blue.opacity(0.2), lineWidth: 1.5),
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(color: Color.blue.opacity(0.1), radius: 4, x: 0, y: 2)
        }
    }

    @ViewBuilder
    private func tableRowView(
        _ cells: [AttributedString],
        alignments: [MarkdownTable.ColumnAlignment],
        isHeader: Bool,
    ) -> some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                let columnAlignment = alignments.indices.contains(index) ? alignments[index] : .leading
                Text(cell)
                    .font(.system(size: 13, weight: isHeader ? .semibold : .regular))
                    .textSelection(.enabled)
                    .frame(minWidth: 80, alignment: horizontalAlignment(for: columnAlignment))
            }
        }
        .padding(.vertical, isHeader ? 10 : 8)
        .padding(.horizontal, 12)
    }

    private func horizontalAlignment(for alignment: MarkdownTable.ColumnAlignment) -> Alignment {
        switch alignment {
        case .leading:
            .leading
        case .center:
            .center
        case .trailing:
            .trailing
        }
    }
}

#Preview {
    VStack(spacing: 16) {
        MessageView(message: Message(
            role: .user,
            content: "What is SwiftUI?",
        ))

        MessageView(message: Message(
            role: .assistant,
            content: """
            SwiftUI is Apple's modern framework for building user interfaces across all Apple platforms. Here are some key features:

            - **Declarative Syntax**: Describe what your UI should look like
            - **Cross-Platform**: Works on iOS, macOS, watchOS, and tvOS
            - **Live Preview**: See changes instantly in Xcode
            - **Built-in Animations**: Smooth transitions with minimal code

            ```swift
            struct ContentView: View {
                var body: some View {
                    Text("Hello, SwiftUI!")
                }
            }
            ```
            """,
        ))
    }
    .padding()
    .frame(width: 600)
}

// Loading animation for image generation
struct ImageGeneratingView: View {
    @State private var isAnimating = false
    @State private var dotCount = 0

    let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 16) {
            // Animated sparkles icon
            ZStack {
                ForEach(0 ..< 3) { index in
                    Image(systemName: "sparkle")
                        .font(.system(size: 20))
                        .foregroundStyle(.blue.opacity(0.6))
                        .scaleEffect(isAnimating ? 1.2 : 0.8)
                        .opacity(isAnimating ? 0.3 : 1.0)
                        .rotationEffect(.degrees(Double(index) * 120))
                        .animation(
                            Animation.easeInOut(duration: 1.5)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * 0.2),
                            value: isAnimating,
                        )
                }

                Image(systemName: "photo")
                    .font(.system(size: 24))
                    .foregroundStyle(.blue)
            }
            .frame(width: 60, height: 60)

            // Animated text
            Text("Generating image" + String(repeating: ".", count: dotCount))
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .onReceive(timer) { _ in
                    dotCount = (dotCount + 1) % 4
                }
        }
        .frame(width: 512, height: 200)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(12)
        .onAppear {
            isAnimating = true
        }
    }
}

// Syntax highlighted code view
struct SyntaxHighlightedCodeView: View {
    let code: String
    let language: String

    var body: some View {
        Text(AttributedString(highlightedCode()))
            .font(.system(size: 13, design: .monospaced))
            .textSelection(.enabled)
    }

    private func highlightedCode() -> NSAttributedString {
        let attributedString = NSMutableAttributedString(string: code)
        let fullRange = NSRange(location: 0, length: code.utf16.count)

        // Base styling
        let baseFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let baseColor = NSColor.labelColor
        attributedString.addAttribute(.font, value: baseFont, range: fullRange)
        attributedString.addAttribute(.foregroundColor, value: baseColor, range: fullRange)

        // Apply syntax highlighting based on language
        let normalizedLang = language.lowercased()

        switch normalizedLang {
        case "swift":
            highlightSwift(attributedString)
        case "python", "py":
            highlightPython(attributedString)
        case "javascript", "js", "typescript", "ts":
            highlightJavaScript(attributedString)
        case "bash", "sh", "shell", "zsh":
            highlightBash(attributedString)
        case "json":
            highlightJSON(attributedString)
        case "html", "xml":
            highlightHTML(attributedString)
        case "css", "scss", "sass":
            highlightCSS(attributedString)
        case "rust", "rs":
            highlightRust(attributedString)
        case "go":
            highlightGo(attributedString)
        case "java", "kotlin":
            highlightJava(attributedString)
        case "c", "cpp", "c++", "objc":
            highlightC(attributedString)
        case "ruby", "rb":
            highlightRuby(attributedString)
        case "php":
            highlightPHP(attributedString)
        default:
            highlightGeneric(attributedString)
        }

        return attributedString
    }

    private func highlightSwift(_ attributedString: NSMutableAttributedString) {
        let keywords = ["func", "var", "let", "if", "else", "for", "while", "return", "import", "class", "struct", "enum", "protocol", "extension", "public", "private", "internal", "static", "override", "init", "self", "super", "nil", "true", "false", "guard", "switch", "case", "default", "break", "continue", "in", "where", "as", "is", "try", "catch", "throw", "throws", "async", "await", "actor"]
        highlightKeywords(attributedString, keywords: keywords, color: .systemPink)
        highlightStrings(attributedString, color: .systemRed)
        highlightComments(attributedString, color: .systemGreen)
        highlightNumbers(attributedString, color: .systemBlue)
    }

    private func highlightPython(_ attributedString: NSMutableAttributedString) {
        let keywords = ["def", "class", "if", "elif", "else", "for", "while", "return", "import", "from", "as", "try", "except", "finally", "with", "lambda", "yield", "async", "await", "pass", "break", "continue", "and", "or", "not", "in", "is", "None", "True", "False", "self"]
        highlightKeywords(attributedString, keywords: keywords, color: .systemPink)
        highlightStrings(attributedString, color: .systemRed)
        highlightComments(attributedString, color: .systemGreen, pattern: "#.*")
        highlightNumbers(attributedString, color: .systemBlue)
    }

    private func highlightJavaScript(_ attributedString: NSMutableAttributedString) {
        let keywords = ["function", "const", "let", "var", "if", "else", "for", "while", "return", "import", "export", "class", "extends", "constructor", "this", "super", "async", "await", "try", "catch", "throw", "new", "typeof", "instanceof", "null", "undefined", "true", "false", "switch", "case", "default", "break", "continue"]
        highlightKeywords(attributedString, keywords: keywords, color: .systemPink)
        highlightStrings(attributedString, color: .systemRed)
        highlightComments(attributedString, color: .systemGreen)
        highlightNumbers(attributedString, color: .systemBlue)
    }

    private func highlightBash(_ attributedString: NSMutableAttributedString) {
        let keywords = ["if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac", "function", "return", "echo", "exit", "export", "source", "cd", "ls", "cp", "mv", "rm", "mkdir", "chmod", "sudo", "apt", "brew", "npm", "pip", "git"]
        highlightKeywords(attributedString, keywords: keywords, color: .systemPink)
        highlightStrings(attributedString, color: .systemRed)
        highlightComments(attributedString, color: .systemGreen, pattern: "#.*")
        highlightPattern(attributedString, pattern: "\\$[a-zA-Z_][a-zA-Z0-9_]*", color: .systemCyan) // Variables
    }

    private func highlightJSON(_ attributedString: NSMutableAttributedString) {
        highlightPattern(attributedString, pattern: "\"[^\"]*\"\\s*:", color: .systemBlue) // Keys
        highlightStrings(attributedString, color: .systemRed)
        highlightPattern(attributedString, pattern: "\\b(true|false|null)\\b", color: .systemPink)
        highlightNumbers(attributedString, color: .systemOrange)
    }

    private func highlightHTML(_ attributedString: NSMutableAttributedString) {
        highlightPattern(attributedString, pattern: "<[^>]+>", color: .systemPink) // Tags
        highlightStrings(attributedString, color: .systemRed)
        highlightComments(attributedString, color: .systemGreen, pattern: "<!--.*?-->")
    }

    private func highlightCSS(_ attributedString: NSMutableAttributedString) {
        highlightPattern(attributedString, pattern: "[.#][a-zA-Z][a-zA-Z0-9_-]*", color: .systemBlue) // Selectors
        highlightPattern(attributedString, pattern: "[a-zA-Z-]+(?=\\s*:)", color: .systemCyan) // Properties
        highlightStrings(attributedString, color: .systemRed)
        highlightComments(attributedString, color: .systemGreen, pattern: "/\\*.*?\\*/")
        highlightNumbers(attributedString, color: .systemOrange)
    }

    private func highlightRust(_ attributedString: NSMutableAttributedString) {
        let keywords = ["fn", "let", "mut", "if", "else", "for", "while", "loop", "return", "use", "mod", "pub", "struct", "enum", "impl", "trait", "type", "where", "match", "self", "Self", "true", "false", "const", "static", "async", "await", "move"]
        highlightKeywords(attributedString, keywords: keywords, color: .systemPink)
        highlightStrings(attributedString, color: .systemRed)
        highlightComments(attributedString, color: .systemGreen)
        highlightNumbers(attributedString, color: .systemBlue)
    }

    private func highlightGo(_ attributedString: NSMutableAttributedString) {
        let keywords = ["func", "var", "const", "if", "else", "for", "range", "return", "import", "package", "type", "struct", "interface", "map", "chan", "go", "defer", "select", "switch", "case", "default", "break", "continue", "nil", "true", "false"]
        highlightKeywords(attributedString, keywords: keywords, color: .systemPink)
        highlightStrings(attributedString, color: .systemRed)
        highlightComments(attributedString, color: .systemGreen)
        highlightNumbers(attributedString, color: .systemBlue)
    }

    private func highlightJava(_ attributedString: NSMutableAttributedString) {
        let keywords = ["public", "private", "protected", "class", "interface", "extends", "implements", "if", "else", "for", "while", "return", "import", "package", "new", "this", "super", "static", "final", "void", "int", "String", "boolean", "true", "false", "null", "try", "catch", "throw", "throws"]
        highlightKeywords(attributedString, keywords: keywords, color: .systemPink)
        highlightStrings(attributedString, color: .systemRed)
        highlightComments(attributedString, color: .systemGreen)
        highlightNumbers(attributedString, color: .systemBlue)
    }

    private func highlightC(_ attributedString: NSMutableAttributedString) {
        let keywords = ["if", "else", "for", "while", "return", "void", "int", "char", "float", "double", "struct", "typedef", "enum", "union", "static", "const", "sizeof", "break", "continue", "switch", "case", "default", "#include", "#define", "NULL"]
        highlightKeywords(attributedString, keywords: keywords, color: .systemPink)
        highlightStrings(attributedString, color: .systemRed)
        highlightComments(attributedString, color: .systemGreen)
        highlightNumbers(attributedString, color: .systemBlue)
    }

    private func highlightRuby(_ attributedString: NSMutableAttributedString) {
        let keywords = ["def", "end", "class", "module", "if", "elsif", "else", "unless", "case", "when", "for", "while", "until", "do", "return", "yield", "self", "super", "nil", "true", "false", "and", "or", "not", "begin", "rescue", "ensure"]
        highlightKeywords(attributedString, keywords: keywords, color: .systemPink)
        highlightStrings(attributedString, color: .systemRed)
        highlightComments(attributedString, color: .systemGreen, pattern: "#.*")
        highlightNumbers(attributedString, color: .systemBlue)
    }

    private func highlightPHP(_ attributedString: NSMutableAttributedString) {
        let keywords = ["function", "class", "if", "else", "elseif", "for", "foreach", "while", "return", "public", "private", "protected", "static", "new", "this", "self", "parent", "try", "catch", "throw", "null", "true", "false", "echo", "print", "require", "include"]
        highlightKeywords(attributedString, keywords: keywords, color: .systemPink)
        highlightStrings(attributedString, color: .systemRed)
        highlightComments(attributedString, color: .systemGreen)
        highlightPattern(attributedString, pattern: "\\$[a-zA-Z_][a-zA-Z0-9_]*", color: .systemCyan) // Variables
        highlightNumbers(attributedString, color: .systemBlue)
    }

    private func highlightGeneric(_ attributedString: NSMutableAttributedString) {
        highlightStrings(attributedString, color: .systemRed)
        highlightComments(attributedString, color: .systemGreen)
        highlightNumbers(attributedString, color: .systemBlue)
    }

    // Helper methods
    private func highlightKeywords(_ attributedString: NSMutableAttributedString, keywords: [String], color: NSColor) {
        for keyword in keywords {
            let pattern = "\\b\(keyword)\\b"
            highlightPattern(attributedString, pattern: pattern, color: color)
        }
    }

    private func highlightStrings(_ attributedString: NSMutableAttributedString, color: NSColor) {
        // Double quotes
        highlightPattern(attributedString, pattern: "\"(?:[^\"\\\\]|\\\\.)*\"", color: color)
        // Single quotes
        highlightPattern(attributedString, pattern: "'(?:[^'\\\\]|\\\\.)*'", color: color)
        // Backticks (template literals)
        highlightPattern(attributedString, pattern: "`(?:[^`\\\\]|\\\\.)*`", color: color)
    }

    private func highlightComments(_ attributedString: NSMutableAttributedString, color: NSColor, pattern: String = "//.*") {
        highlightPattern(attributedString, pattern: pattern, color: color)
        // Multi-line comments
        highlightPattern(attributedString, pattern: "/\\*[\\s\\S]*?\\*/", color: color)
    }

    private func highlightNumbers(_ attributedString: NSMutableAttributedString, color: NSColor) {
        highlightPattern(attributedString, pattern: "\\b\\d+\\.?\\d*\\b", color: color)
    }

    private func highlightPattern(_ attributedString: NSMutableAttributedString, pattern: String, color: NSColor) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return }
        let range = NSRange(location: 0, length: attributedString.length)
        let matches = regex.matches(in: attributedString.string, options: [], range: range)

        for match in matches {
            attributedString.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }
}

// Typing indicator for text responses
struct TypingIndicatorView: View {
    @State private var animatingDot = 0

    let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0 ..< 3) { index in
                Circle()
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 8, height: 8)
                    .scaleEffect(animatingDot == index ? 1.2 : 0.8)
                    .animation(.easeInOut(duration: 0.4), value: animatingDot)
            }
        }
        .padding(.vertical, 8)
        .onReceive(timer) { _ in
            animatingDot = (animatingDot + 1) % 3
        }
    }
}
