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
                if let attachments = message.attachments, !attachments.isEmpty {
                    ForEach(attachments, id: \.fileName) { attachment in
                        HStack {
                            Image(systemName: "doc.fill")
                                .foregroundStyle(.secondary)
                            Text(attachment.fileName)
                                .font(.caption)
                                .lineLimit(1)
                        }
                        .padding(6)
                        .background(Color.black.opacity(0.1))
                        .cornerRadius(6)
                    }
                }

                if message.mediaType == .image, let imageData = message.imageData, let uiImage = UIImage(data: imageData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 280)
                        .cornerRadius(12)
                }

                if contentBlocks.isEmpty {
                    if !message.content.isEmpty {
                        Text(message.content)
                    }
                } else {
                    ForEach(contentBlocks) { block in
                        IOSContentBlockView(block: block)
                    }
                }
            }
      .padding(.leading, message.role == .user ? 12 : 18)
      .padding(.trailing, message.role == .user ? 18 : 12)
      .padding(.vertical, 10)
      .background(
        MessageBubbleShape(isFromCurrentUser: message.role == .user)
          .fill(message.role == .user ? Color.blue : Color(uiColor: .systemGray5))
      )
      .foregroundStyle(message.role == .user ? .white : .primary)
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

private struct MessageBubbleShape: Shape {
  var isFromCurrentUser: Bool

  func path(in rect: CGRect) -> Path {
    Path { path in
      let tailWidth: CGFloat = 6
      let radius: CGFloat = 18

      if isFromCurrentUser {
        // Right bubble
        let bodyMaxX = rect.maxX - tailWidth

        // Start top-left
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + radius))

        // Top-left corner
        path.addArc(
          center: CGPoint(x: rect.minX + radius, y: rect.minY + radius),
          radius: radius,
          startAngle: Angle(degrees: 180),
          endAngle: Angle(degrees: 270),
          clockwise: false)

        // Top edge
        path.addLine(to: CGPoint(x: bodyMaxX - radius, y: rect.minY))

        // Top-right corner
        path.addArc(
          center: CGPoint(x: bodyMaxX - radius, y: rect.minY + radius),
          radius: radius,
          startAngle: Angle(degrees: 270),
          endAngle: Angle(degrees: 0),
          clockwise: false)

        // Right edge
        path.addLine(to: CGPoint(x: bodyMaxX, y: rect.maxY - radius))

        // Tail (Bottom-Right)
        // Curve out to tip
        path.addCurve(
          to: CGPoint(x: rect.maxX, y: rect.maxY),
          control1: CGPoint(x: bodyMaxX, y: rect.maxY),
          control2: CGPoint(x: rect.maxX, y: rect.maxY))

        // Curve back to bottom
        path.addCurve(
          to: CGPoint(x: bodyMaxX - 4, y: rect.maxY),
          control1: CGPoint(x: rect.maxX - 2, y: rect.maxY),
          control2: CGPoint(x: bodyMaxX + 2, y: rect.maxY))

        // Bottom edge
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))

        // Bottom-left corner
        path.addArc(
          center: CGPoint(x: rect.minX + radius, y: rect.maxY - radius),
          radius: radius,
          startAngle: Angle(degrees: 90),
          endAngle: Angle(degrees: 180),
          clockwise: false)

        path.closeSubpath()

      } else {
        // Left bubble
        let bodyMinX = rect.minX + tailWidth

        // Start top-left (after tail)
        path.move(to: CGPoint(x: bodyMinX, y: rect.minY + radius))

        // Top-left corner
        path.addArc(
          center: CGPoint(x: bodyMinX + radius, y: rect.minY + radius),
          radius: radius,
          startAngle: Angle(degrees: 180),
          endAngle: Angle(degrees: 270),
          clockwise: false)

        // Top edge
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))

        // Top-right corner
        path.addArc(
          center: CGPoint(x: rect.maxX - radius, y: rect.minY + radius),
          radius: radius,
          startAngle: Angle(degrees: 270),
          endAngle: Angle(degrees: 0),
          clockwise: false)

        // Right edge
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))

        // Bottom-right corner
        path.addArc(
          center: CGPoint(x: rect.maxX - radius, y: rect.maxY - radius),
          radius: radius,
          startAngle: Angle(degrees: 0),
          endAngle: Angle(degrees: 90),
          clockwise: false)

        // Bottom edge
        path.addLine(to: CGPoint(x: bodyMinX + 4, y: rect.maxY))

        // Tail (Bottom-Left)
        // Curve out to tip
        path.addCurve(
          to: CGPoint(x: rect.minX, y: rect.maxY),
          control1: CGPoint(x: bodyMinX - 2, y: rect.maxY),
          control2: CGPoint(x: rect.minX + 2, y: rect.maxY))

        // Curve back to side
        path.addCurve(
          to: CGPoint(x: bodyMinX, y: rect.maxY - radius),
          control1: CGPoint(x: rect.minX, y: rect.maxY),
          control2: CGPoint(x: bodyMinX, y: rect.maxY))

        // Left edge
        path.addLine(to: CGPoint(x: bodyMinX, y: rect.minY + radius))

        path.closeSubpath()
      }
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
