//
//  IOSMultiModelMarkdownRenderPlan.swift
//  Ayna
//

struct IOSMultiModelMarkdownRenderPlan {
    let initialBlocks: [ContentBlock]
    let deferredContent: String

    init(content: String) {
        initialBlocks = MarkdownRenderer.cachedBlocks(for: content) ?? []
        deferredContent = content
    }
}
