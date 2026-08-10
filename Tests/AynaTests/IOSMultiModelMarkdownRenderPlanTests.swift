@testable import Ayna
import Foundation
import Testing

@Suite("iOS Multi-Model Markdown Render Plan Tests", .tags(.fast))
struct IOSMultiModelMarkdownRenderPlanTests {
    @Test
    func `uncached initial markdown parsing is deferred`() {
        let content = "# Uncached \(UUID())\n\nA response with **formatted** content."

        #expect(MarkdownRenderer.cachedBlocks(for: content) == nil)

        let plan = IOSMultiModelMarkdownRenderPlan(content: content)

        #expect(plan.initialBlocks.isEmpty)
        #expect(plan.deferredContent == content)
        #expect(MarkdownRenderer.cachedBlocks(for: content) == nil)
    }

    @Test
    func `cached markdown seeds initial blocks`() {
        let content = "# Cached \(UUID())\n\nStable response content."
        let cachedBlocks = MarkdownRenderer.parse(content)

        let plan = IOSMultiModelMarkdownRenderPlan(content: content)

        #expect(plan.initialBlocks.map(\.id) == cachedBlocks.map(\.id))
        #expect(plan.deferredContent == content)
    }
}
