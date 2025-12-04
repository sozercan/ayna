# Testing Guide

This document covers testing strategies, commands, and best practices for Ayna.

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

### Test File Template

```swift
import XCTest
@testable import Ayna

final class MyServiceTests: XCTestCase {
    var sut: MyService!

    override func setUp() {
        super.setUp()
        // Use mocks for isolation
        sut = MyService(urlSession: MockURLProtocol.session())
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    func testSomething() async throws {
        // Arrange
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        // Act
        let result = try await sut.doSomething()

        // Assert
        XCTAssertNotNil(result)
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
