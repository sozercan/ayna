//
//  IOSMessageView.swift
//  ayna
//
//  Created on 11/22/25.
//

import SwiftUI

struct IOSMessageView: View {
    let message: Message
    @State private var contentBlocks: [ContentBlock] = []

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .user {
                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                if contentBlocks.isEmpty {
                    Text(message.content)
                } else {
                    ForEach(contentBlocks) { block in
                        IOSContentBlockView(block: block)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(message.role == .user ? Color.blue : Color(uiColor: .systemGray5))
            .foregroundStyle(message.role == .user ? .white : .primary)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .frame(maxWidth: 300, alignment: message.role == .user ? .trailing : .leading)

            if message.role != .user {
                Spacer()
            }
        }
        .onAppear {
            contentBlocks = MarkdownRenderer.parse(message.content)
        }
        .onChange(of: message.content) { newValue in
            contentBlocks = MarkdownRenderer.parse(newValue)
        }
    }
}

struct IOSContentBlockView: View {
    let block: ContentBlock

    var body: some View {
        switch block.type {
        case .paragraph(let text):
            Text(text)
        case .heading(let level, let text):
            Text(text).font(.system(size: CGFloat(24 - level * 2), weight: .bold))
        case .unorderedList(let items):
            VStack(alignment: .leading) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top) {
                        Text("•")
                        Text(item)
                    }
                }
            }
        case .orderedList(let start, let items):
            VStack(alignment: .leading) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top) {
                        Text("\(start + index).")
                        Text(item)
                    }
                }
            }
        case .blockquote(let text):
            HStack {
                Rectangle().fill(Color.gray).frame(width: 4)
                Text(text).foregroundStyle(.secondary)
            }
        case .code(let code, _):
            ScrollView(.horizontal) {
                Text(code)
                    .font(.monospaced(.body)())
                    .padding()
                    .background(Color.black.opacity(0.1))
                    .cornerRadius(8)
            }
        case .divider:
            Divider()
        case .table:
            Text("[Table]") // Simplified for now
        case .tool(let name, let result):
            VStack(alignment: .leading) {
                Text("Tool: \(name)").font(.caption).bold()
                Text(result).font(.caption).foregroundStyle(.secondary)
            }
            .padding(8)
            .background(Color.orange.opacity(0.1))
            .cornerRadius(8)
        }
    }
}
