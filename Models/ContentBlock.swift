//
//  ContentBlock.swift
//  ayna
//
//  Created on 11/22/25.
//

import Foundation
import SwiftUI

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
}
