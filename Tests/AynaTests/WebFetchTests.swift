//
//  WebFetchTests.swift
//  aynaTests
//
//  Unit tests for web_fetch tool functionality via WebFetchService.
//

@testable import Ayna
import Foundation
import Testing

@Suite("WebFetch Tests")
@MainActor
struct WebFetchTests {
    private var webFetchService: WebFetchService!

    init() {
        webFetchService = WebFetchService.shared
        webFetchService.isEnabled = true
    }

    // MARK: - Private IP Detection Tests (via fetch errors)

    @Test("Blocks localhost")
    func blocksLocalhost() async {
        await #expect(throws: WebFetchError.self) {
            _ = try await webFetchService.fetch(url: "http://localhost/test")
        }
    }

    @Test("Blocks 127.0.0.1")
    func blocksLoopback() async {
        await #expect(throws: WebFetchError.self) {
            _ = try await webFetchService.fetch(url: "http://127.0.0.1/test")
        }
    }

    @Test("Blocks 10.x.x.x private range")
    func blocksPrivate10() async {
        await #expect(throws: WebFetchError.self) {
            _ = try await webFetchService.fetch(url: "http://10.0.0.1/test")
        }
    }

    @Test("Blocks 192.168.x.x private range")
    func blocksPrivate192() async {
        await #expect(throws: WebFetchError.self) {
            _ = try await webFetchService.fetch(url: "http://192.168.1.1/test")
        }
    }

    @Test("Blocks 172.16-31.x.x private range")
    func blocksPrivate172() async {
        await #expect(throws: WebFetchError.self) {
            _ = try await webFetchService.fetch(url: "http://172.16.0.1/test")
        }
    }

    @Test("Blocks link-local 169.254.x.x")
    func blocksLinkLocal() async {
        await #expect(throws: WebFetchError.self) {
            _ = try await webFetchService.fetch(url: "http://169.254.1.1/test")
        }
    }

    // MARK: - URL Validation Tests

    @Test("Rejects invalid URL")
    func rejectsInvalidURL() async {
        await #expect(throws: WebFetchError.self) {
            _ = try await webFetchService.fetch(url: "not-a-url")
        }
    }

    @Test("Rejects file:// URLs")
    func rejectsFileURL() async {
        await #expect(throws: WebFetchError.self) {
            _ = try await webFetchService.fetch(url: "file:///etc/passwd")
        }
    }

    @Test("Rejects ftp:// URLs")
    func rejectsFtpURL() async {
        await #expect(throws: WebFetchError.self) {
            _ = try await webFetchService.fetch(url: "ftp://example.com/file")
        }
    }

    // MARK: - Tool Definition Tests

    @Test("WebFetchService tool definition has correct name")
    func webFetchToolDefinitionName() {
        let definition = webFetchService.toolDefinition()
        guard let function = definition["function"] as? [String: Any],
              let name = function["name"] as? String
        else {
            Issue.record("Tool definition missing function or name")
            return
        }
        #expect(name == "web_fetch")
    }

    @Test("web_fetch is recognized by WebFetchService")
    func webFetchIsRecognized() {
        #expect(WebFetchService.isWebFetchTool("web_fetch"))
    }

    // MARK: - Permission Tests

    @Test("web_fetch has automatic permission level")
    func webFetchAutomaticPermission() {
        #expect(PermissionService.defaultPermissionLevel(for: "web_fetch") == .automatic)
    }

    // MARK: - Full Loopback Range Tests

    @Test("Blocks 127.0.0.2")
    func blocksLoopback2() async {
        await #expect(throws: WebFetchError.self) {
            _ = try await webFetchService.fetch(url: "http://127.0.0.2/test")
        }
    }

    @Test("Blocks 127.1.2.3")
    func blocksLoopback1_2_3() async {
        await #expect(throws: WebFetchError.self) {
            _ = try await webFetchService.fetch(url: "http://127.1.2.3/test")
        }
    }

    @Test("Blocks 127.255.255.255")
    func blocksLoopbackMax() async {
        await #expect(throws: WebFetchError.self) {
            _ = try await webFetchService.fetch(url: "http://127.255.255.255/test")
        }
    }

    // MARK: - IPv6 False Positive Tests
    // These verify that domains starting with "fd" or "fc" are NOT blocked.
    // The SSRF check should only block IPv6 addresses (containing ":"), not hostnames.
    // Note: These are integration tests — they require network access. The fetch may
    // fail with a network or HTTP error, but must NOT fail with .ssrfBlocked.

    @Test("Does not block fdic.gov (not an IPv6 address)")
    func doesNotBlockFdicGov() async {
        do {
            _ = try await webFetchService.fetch(url: "https://fdic.gov")
        } catch let error as WebFetchError {
            if case .ssrfBlocked = error {
                Issue.record("fdic.gov should not be SSRF-blocked")
            }
            // Other WebFetchErrors (network, HTTP) are acceptable
        } catch {
            // Non-WebFetchError exceptions are acceptable
        }
    }

    @Test("Does not block fcc.gov (not an IPv6 address)")
    func doesNotBlockFccGov() async {
        do {
            _ = try await webFetchService.fetch(url: "https://fcc.gov")
        } catch let error as WebFetchError {
            if case .ssrfBlocked = error {
                Issue.record("fcc.gov should not be SSRF-blocked")
            }
        } catch {
            // Non-WebFetchError exceptions are acceptable
        }
    }

    // MARK: - IPv6 Private Address Tests

    @Test("Blocks fd00::1 (IPv6 unique local)")
    func blocksIPv6UniqueLocal() async {
        await #expect(throws: WebFetchError.self) {
            _ = try await webFetchService.fetch(url: "http://[fd00::1]/test")
        }
    }

    @Test("Blocks fe80::1 (IPv6 link-local)")
    func blocksIPv6LinkLocal() async {
        await #expect(throws: WebFetchError.self) {
            _ = try await webFetchService.fetch(url: "http://[fe80::1]/test")
        }
    }

    @Test("Blocks fc00::1 (IPv6 unique local fc range)")
    func blocksIPv6UniqueLocalFc() async {
        await #expect(throws: WebFetchError.self) {
            _ = try await webFetchService.fetch(url: "http://[fc00::1]/test")
        }
    }

    // MARK: - Service Disabled Tests

    @Test("Throws when service is disabled")
    func throwsWhenDisabled() async {
        webFetchService.isEnabled = false
        defer { webFetchService.isEnabled = true }
        await #expect(throws: WebFetchError.self) {
            _ = try await webFetchService.fetch(url: "https://example.com")
        }
    }
}
