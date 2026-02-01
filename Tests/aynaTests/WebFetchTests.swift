//
//  WebFetchTests.swift
//  aynaTests
//
//  Unit tests for web_fetch tool functionality.
//

@testable import Ayna
import Foundation
import Testing

@Suite("WebFetch Tests")
@MainActor
struct WebFetchTests {
    private var sut: BuiltinToolService!
    private var permissionService: PermissionService!

    init() {
        permissionService = PermissionService()
        sut = BuiltinToolService(permissionService: permissionService, projectRoot: nil)
    }

    // MARK: - Private IP Detection Tests

    @Test("Blocks localhost")
    func blocksLocalhost() async {
        await #expect(throws: ToolExecutionError.self) {
            try await sut.webFetch(url: "http://localhost/test", conversationId: UUID())
        }
    }

    @Test("Blocks 127.0.0.1")
    func blocksLoopback() async {
        await #expect(throws: ToolExecutionError.self) {
            try await sut.webFetch(url: "http://127.0.0.1/test", conversationId: UUID())
        }
    }

    @Test("Blocks 10.x.x.x private range")
    func blocksPrivate10() async {
        await #expect(throws: ToolExecutionError.self) {
            try await sut.webFetch(url: "http://10.0.0.1/test", conversationId: UUID())
        }
    }

    @Test("Blocks 192.168.x.x private range")
    func blocksPrivate192() async {
        await #expect(throws: ToolExecutionError.self) {
            try await sut.webFetch(url: "http://192.168.1.1/test", conversationId: UUID())
        }
    }

    @Test("Blocks 172.16-31.x.x private range")
    func blocksPrivate172() async {
        await #expect(throws: ToolExecutionError.self) {
            try await sut.webFetch(url: "http://172.16.0.1/test", conversationId: UUID())
        }
    }

    @Test("Blocks link-local 169.254.x.x")
    func blocksLinkLocal() async {
        await #expect(throws: ToolExecutionError.self) {
            try await sut.webFetch(url: "http://169.254.1.1/test", conversationId: UUID())
        }
    }

    // MARK: - URL Validation Tests

    @Test("Rejects invalid URL")
    func rejectsInvalidURL() async {
        await #expect(throws: ToolExecutionError.self) {
            try await sut.webFetch(url: "not-a-url", conversationId: UUID())
        }
    }

    @Test("Rejects file:// URLs")
    func rejectsFileURL() async {
        await #expect(throws: ToolExecutionError.self) {
            try await sut.webFetch(url: "file:///etc/passwd", conversationId: UUID())
        }
    }

    @Test("Rejects ftp:// URLs")
    func rejectsFtpURL() async {
        await #expect(throws: ToolExecutionError.self) {
            try await sut.webFetch(url: "ftp://example.com/file", conversationId: UUID())
        }
    }

    // MARK: - HTML to Text Conversion Tests

    @Test("Strips HTML tags")
    func stripsHtmlTags() {
        let html = "<html><body><p>Hello <strong>World</strong></p></body></html>"
        let result = sut.htmlToPlainText(html)
        #expect(!result.contains("<"))
        #expect(!result.contains(">"))
        #expect(result.contains("Hello"))
        #expect(result.contains("World"))
    }

    @Test("Removes script tags and content")
    func removesScripts() {
        let html = "<html><script>alert('xss')</script><p>Safe content</p></html>"
        let result = sut.htmlToPlainText(html)
        #expect(!result.contains("alert"))
        #expect(!result.contains("xss"))
        #expect(result.contains("Safe content"))
    }

    @Test("Removes style tags and content")
    func removesStyles() {
        let html = "<html><style>.red { color: red; }</style><p>Styled text</p></html>"
        let result = sut.htmlToPlainText(html)
        #expect(!result.contains("color"))
        #expect(!result.contains(".red"))
        #expect(result.contains("Styled text"))
    }

    @Test("Decodes HTML entities")
    func decodesEntities() {
        let html = "<p>&amp; &lt; &gt; &quot; &#39; &nbsp;</p>"
        let result = sut.htmlToPlainText(html)
        #expect(result.contains("&"))
        #expect(result.contains("<"))
        #expect(result.contains(">"))
        #expect(result.contains("\""))
        #expect(result.contains("'"))
    }

    // MARK: - isPrivateHost Tests

    @Test("isPrivateHost returns true for localhost")
    func isPrivateHostLocalhost() {
        #expect(sut.isPrivateHost("localhost") == true)
        #expect(sut.isPrivateHost("LOCALHOST") == true)
    }

    @Test("isPrivateHost returns true for loopback")
    func isPrivateHostLoopback() {
        #expect(sut.isPrivateHost("127.0.0.1") == true)
        #expect(sut.isPrivateHost("::1") == true)
    }

    @Test("isPrivateHost returns true for private ranges")
    func isPrivateHostPrivateRanges() {
        #expect(sut.isPrivateHost("10.0.0.1") == true)
        #expect(sut.isPrivateHost("10.255.255.255") == true)
        #expect(sut.isPrivateHost("172.16.0.1") == true)
        #expect(sut.isPrivateHost("172.31.255.255") == true)
        #expect(sut.isPrivateHost("192.168.0.1") == true)
        #expect(sut.isPrivateHost("192.168.255.255") == true)
        #expect(sut.isPrivateHost("169.254.1.1") == true)
    }

    @Test("isPrivateHost returns false for public hosts")
    func isPrivateHostPublic() {
        #expect(sut.isPrivateHost("example.com") == false)
        #expect(sut.isPrivateHost("8.8.8.8") == false)
        #expect(sut.isPrivateHost("172.32.0.1") == false)
        #expect(sut.isPrivateHost("192.169.1.1") == false)
    }

    // MARK: - Tool Definition Tests

    @Test("Tool definitions include web_fetch")
    func toolDefinitionsIncludeWebFetch() {
        let definitions = sut.allToolDefinitions()
        let toolNames = definitions.compactMap { def -> String? in
            guard let function = def["function"] as? [String: Any] else { return nil }
            return function["name"] as? String
        }
        #expect(toolNames.contains("web_fetch"))
    }

    @Test("web_fetch is recognized as builtin tool")
    func webFetchIsBuiltinTool() {
        #expect(BuiltinToolService.isBuiltinTool("web_fetch"))
    }

    // MARK: - Permission Tests

    @Test("web_fetch has automatic permission level")
    func webFetchAutomaticPermission() {
        #expect(PermissionService.defaultPermissionLevel(for: "web_fetch") == .automatic)
    }

    // MARK: - Service Disabled Tests

    @Test("Throws when service is disabled")
    func throwsWhenDisabled() async {
        sut.isEnabled = false
        await #expect(throws: ToolExecutionError.self) {
            try await sut.webFetch(url: "https://example.com", conversationId: UUID())
        }
    }
}
