# Testing Guide

This document covers testing strategies, commands, and best practices for Ayna.

## Test Framework

**Unit tests use [Swift Testing](https://developer.apple.com/documentation/testing)** (not XCTest).

- `@Suite` for test groupings
- `@Test` for individual tests
- `#expect()` for assertions
- `Issue.record()` for failures
- `confirmation()` for async callback verification

**UI tests remain on XCTest** (Swift Testing does not support `XCUIApplication`).

## Test Commands

### Unit Tests (Logic/Backend)

```bash
xcodebuild -scheme Ayna -destination 'platform=macOS' test -only-testing:aynaTests
```

### UI Tests (Views/Interactions)

```bash
xcodebuild -scheme Ayna -destination 'platform=macOS' test -only-testing:aynaUITests
```

### Full Suite

```bash
xcodebuild -scheme Ayna -destination 'platform=macOS' test
```

## Unit Test Requirements

**New code in `Core/` (Services, Models, ViewModels, Utilities) must include unit tests.**

### Creating a Test File

1. Create test file in `Tests/aynaTests/` matching the source file name
   - Example: `TavilyService.swift` → `TavilyServiceTests.swift`
2. Add the test file to `Ayna.xcodeproj/project.pbxproj`:
   - Add `PBXFileReference` entry
   - Add `PBXBuildFile` entry
   - Add to the `aynaTests` group
3. Run tests to verify: `xcodebuild -scheme Ayna -destination 'platform=macOS' test -only-testing:aynaTests`

### Test File Template (Swift Testing)

```swift
import Foundation
import Testing

@testable import Ayna

@Suite("MyService Tests")
struct MyServiceTests {
    private var sut: MyService
    private let keychain: InMemoryKeychainStorage

    init() {
        keychain = InMemoryKeychainStorage()
        // Use mocks for isolation
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        sut = MyService(keychain: keychain, urlSession: session)
    }

    @Test("Something works correctly")
    func somethingWorksCorrectly() async throws {
        // Arrange
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        // Act
        let result = try await sut.doSomething()

        // Assert
        #expect(result != nil)
    }
}

// MARK: - Mock URL Protocol

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    static func reset() {
        requestHandler = nil
    }

    override static func canInit(with _: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "MockURLProtocol", code: 0))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
```

### MainActor Tests

For tests that need `@MainActor`, annotate the struct:

```swift
@Suite("MyViewModel Tests")
@MainActor
struct MyViewModelTests {
    private var defaults: UserDefaults
    
    init() {
        guard let suite = UserDefaults(suiteName: "MyViewModelTests") else {
            fatalError("Failed to create UserDefaults suite")
        }
        defaults = suite
        defaults.removePersistentDomain(forName: "MyViewModelTests")
        AppPreferences.use(defaults)
    }
    
    @Test("Initial state is correct")
    func initialState() {
        let vm = MyViewModel()
        #expect(vm.isLoading == false)
    }
}
```

### Async Callback Tests

Use `confirmation()` for callback-based APIs:

```swift
@Test("Callback is invoked")
func callbackIsInvoked() async {
    await confirmation { confirm in
        service.doSomethingAsync { result in
            #expect(result != nil)
            confirm()
        }
        try? await Task.sleep(for: .milliseconds(100))
    }
}
```

## Environment Isolation

Tests run with `AYNA_UI_TESTING=1` environment variable, which injects:

| Mock | Purpose |
|------|---------|
| `InMemoryKeychainStorage` | No system keychain access |
| `MockURLProtocol` | Deterministic network responses |
| Temporary storage paths | Isolated file system |

### Using MockURLProtocol

```swift
// In test setup
let config = URLSessionConfiguration.ephemeral
config.protocolClasses = [MockURLProtocol.self]
let session = URLSession(configuration: config)

// Set response handler
MockURLProtocol.requestHandler = { request in
    let json = """
    {"id": "123", "choices": [{"delta": {"content": "Hello"}}]}
    """
    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    return (response, json.data(using: .utf8)!)
}
```

### Using InMemoryKeychainStorage

```swift
let keychain = InMemoryKeychainStorage()
let service = OpenAIService(keychainStorage: keychain)
keychain.set("test-api-key", forKey: "openai_api_key")
```

## UI Testing Guidelines

### Accessibility Identifiers

**Mandatory** on all interactive elements.

- **Naming Convention**: Dot notation (e.g., `sidebar.newConversationButton`)
- **Dynamic Elements**: Append IDs for lists (e.g., `sidebar.conversationRow.{UUID}`)

### Common Identifiers

| Element | Identifier |
|---------|------------|
| New conversation button | `sidebar.newConversationButton` |
| Text composer | `chat.composer.textEditor` |
| Send button | `chat.composer.sendButton` |
| Message copy action | `message.action.copy` |
| Conversation row | `sidebar.conversationRow.{UUID}` |

### UI Test Patterns

```swift
func testCreateNewConversation() {
    let app = XCUIApplication()
    app.launchEnvironment["AYNA_UI_TESTING"] = "1"
    app.launch()

    // Wait for element
    let newButton = app.buttons["sidebar.newConversationButton"]
    XCTAssertTrue(newButton.waitForExistence(timeout: 5))

    // Interact
    newButton.click()

    // Verify
    let composer = app.textViews["chat.composer.textEditor"]
    XCTAssertTrue(composer.waitForExistence(timeout: 3))
}
```

### macOS-Specific: Hover States

On macOS, some buttons only appear on hover. You must explicitly hover:

```swift
// Hover over container to reveal child buttons
let messageRow = app.groups["message.row.{UUID}"]
messageRow.hover()

// Now the button is visible
let copyButton = app.buttons["message.action.copy"]
XCTAssertTrue(copyButton.waitForExistence(timeout: 2))
```

### Async Best Practices

- **Always** use `waitForExistence(timeout:)` for elements that appear asynchronously
- **Never** use `sleep()` or `Thread.sleep()`
- Use reasonable timeouts (3-5 seconds for UI, 10+ for network)
