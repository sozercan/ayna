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
    @State private var isHovered = false

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
                            .foregroundStyle(message.role == .assistant ? Color.green : Color.blue)
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

                    ForEach(parseMessageContent(message.content), id: \.id) { block in
                        block.view
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()

            // Copy button with fixed space
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
            .opacity(isHovered ? 1 : 0)
            .animation(.easeInOut(duration: 0.15), value: isHovered)
            .frame(width: 32)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(isHovered ? Color.primary.opacity(0.03) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func parseMessageContent(_ content: String) -> [ContentBlock] {
        var blocks: [ContentBlock] = []
        let lines = content.components(separatedBy: .newlines)
        var currentText = ""
        var currentCode = ""
        var currentToolResult = ""
        var inCodeBlock = false
        var inToolBlock = false
        var codeLanguage = ""
        var toolName = ""

        for line in lines {
            // Check for tool call markers
            if line.hasPrefix("[Tool:") && line.hasSuffix("]") {
                // Save any pending text
                if !currentText.isEmpty {
                    blocks.append(ContentBlock(type: .text(currentText.trimmingCharacters(in: .newlines))))
                    currentText = ""
                }
                // Extract tool name
                let toolNameStart = line.index(line.startIndex, offsetBy: 6)
                let toolNameEnd = line.index(line.endIndex, offsetBy: -1)
                toolName = String(line[toolNameStart..<toolNameEnd]).trimmingCharacters(in: .whitespaces)
                inToolBlock = true
            } else if inToolBlock && line.isEmpty {
                // End of tool block (empty line after tool result)
                if !currentToolResult.isEmpty {
                    blocks.append(ContentBlock(type: .tool(toolName, currentToolResult.trimmingCharacters(in: .newlines))))
                    currentToolResult = ""
                    toolName = ""
                }
                inToolBlock = false
            } else if inToolBlock {
                currentToolResult += line + "\n"
            } else if line.hasPrefix("```") {
                if inCodeBlock {
                    // End of code block
                    if !currentCode.isEmpty {
                        blocks.append(ContentBlock(type: .code(currentCode.trimmingCharacters(in: .newlines), codeLanguage)))
                        currentCode = ""
                        codeLanguage = ""
                    }
                    inCodeBlock = false
                } else {
                    // Start of code block
                    if !currentText.isEmpty {
                        blocks.append(ContentBlock(type: .text(currentText.trimmingCharacters(in: .newlines))))
                        currentText = ""
                    }
                    inCodeBlock = true
                    codeLanguage = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
            } else if inCodeBlock {
                currentCode += line + "\n"
            } else {
                currentText += line + "\n"
            }
        }

        // Add remaining content
        if !currentText.isEmpty {
            blocks.append(ContentBlock(type: .text(currentText.trimmingCharacters(in: .newlines))))
        }
        if !currentToolResult.isEmpty {
            blocks.append(ContentBlock(type: .tool(toolName, currentToolResult.trimmingCharacters(in: .newlines))))
        }

        return blocks
    }
}

struct ContentBlock: Identifiable {
    let id = UUID()
    let type: BlockType

    enum BlockType {
        case text(String)
        case code(String, String) // code, language
        case tool(String, String) // tool name, result
    }

    @ViewBuilder
    var view: some View {
        switch type {
        case .text(let text):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(text.components(separatedBy: "\n"), id: \.self) { line in
                    if line.hasPrefix("### ") {
                        Text(line.replacingOccurrences(of: "### ", with: ""))
                            .font(.system(size: 16, weight: .semibold))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if line.hasPrefix("## ") {
                        Text(line.replacingOccurrences(of: "## ", with: ""))
                            .font(.system(size: 17, weight: .semibold))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if line.hasPrefix("# ") {
                        Text(line.replacingOccurrences(of: "# ", with: ""))
                            .font(.system(size: 18, weight: .bold))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if !line.isEmpty {
                        Text(LocalizedStringKey(line))
                            .textSelection(.enabled)
                            .font(.system(size: 15, weight: .regular))
                            .lineSpacing(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .code(let code, let language):
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

                // Code content
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))

        case .tool(let name, let result):
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
                                endPoint: .bottomTrailing
                            )
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
                    .stroke(Color.blue.opacity(0.2), lineWidth: 1.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(color: Color.blue.opacity(0.1), radius: 4, x: 0, y: 2)
        }
    }
}

#Preview {
    VStack(spacing: 16) {
        MessageView(message: Message(
            role: .user,
            content: "What is SwiftUI?"
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
            """
        ))
    }
    .padding()
    .frame(width: 600)
}
