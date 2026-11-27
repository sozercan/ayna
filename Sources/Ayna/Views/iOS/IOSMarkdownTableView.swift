// swiftformat:options --ifdef no-indent
#if os(iOS)

import SwiftUI

struct IOSMarkdownTableView: View {
    let table: MarkdownTable

    private static let minimumColumnWidth: CGFloat = 72

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .leading, horizontalSpacing: Spacing.md, verticalSpacing: 0) {
                headerRow
                    .background(Theme.textSecondary.opacity(0.12))

                Divider()
                    .overlay(Theme.separator)

                ForEach(Array(table.rows.enumerated()), id: \.offset) { rowIndex, row in
                    dataRow(row)
                    if rowIndex < table.rows.count - 1 {
                        Divider()
                            .overlay(Theme.separator)
                    }
                }
            }
        }
        .background(Theme.textSecondary.opacity(0.05))
        .overlay(
            RoundedRectangle(cornerRadius: Spacing.CornerRadius.md)
                .stroke(Theme.border, lineWidth: Spacing.Border.standard)
        )
        .clipShape(.rect(cornerRadius: Spacing.CornerRadius.md))
    }

    private var headerRow: some View {
        GridRow {
            ForEach(Array(table.headers.enumerated()), id: \.offset) { index, cell in
                cellView(cell, columnIndex: index, isHeader: true)
            }
        }
        .padding(.vertical, Spacing.sm)
        .padding(.horizontal, Spacing.md)
    }

    private func dataRow(_ cells: [AttributedString]) -> some View {
        GridRow {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                cellView(cell, columnIndex: index, isHeader: false)
            }
        }
        .padding(.vertical, Spacing.xs)
        .padding(.horizontal, Spacing.md)
    }

    private func cellView(_ cell: AttributedString, columnIndex: Int, isHeader: Bool) -> some View {
        let columnAlignment = table.alignment(forColumn: columnIndex)
        return Text(cell)
            .font(isHeader ? Typography.captionBold : Typography.bodySecondary)
            .multilineTextAlignment(columnAlignment.textAlignment)
            .textSelection(.enabled)
            .frame(minWidth: Self.minimumColumnWidth, alignment: columnAlignment.frameAlignment)
            .gridColumnAlignment(columnAlignment.frameAlignment.horizontal)
    }
}
#endif
