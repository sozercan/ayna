# Ayna

Native macOS/iOS/watchOS ChatGPT client. Swift 6.0+, macOS 14.0+, iOS 17.0+, watchOS 10.0+.

## Project Structure

```
App/   → Platform entry points
Core/  → Shared logic — MUST compile for all platforms
Views/ → Platform-specific UI (macOS/, iOS/, watchOS/)
Tests/ → aynaTests (unit), aynaUITests (UI)
docs/  → Detailed docs (architecture, testing, platforms, workflow, patterns, performance)
```

## Critical Rules

- **Cross-platform**: Code in `Core/` must build for macOS, iOS, AND watchOS. Use `#if os()` guards for AppKit/UIKit.
- **No third-party deps** without asking first.
- **Swift Concurrency**: Mark `@Observable` classes with `@MainActor`. Never use `DispatchQueue`.
- **Swift Testing** for unit tests, not XCTest. See [docs/testing.md](docs/testing.md).

## Build Commands

```bash
# macOS
xcodebuild -scheme Ayna -destination 'platform=macOS' build

# iOS
xcodebuild -scheme Ayna-iOS -destination 'platform=iOS Simulator,name=iPhone 17' build

# watchOS
xcodebuild -scheme Ayna-watchOS -destination 'platform=watchOS Simulator,name=Apple Watch Ultra 3 (49mm)' build
```

## Test Commands

```bash
# Unit tests only (preferred)
xcodebuild -scheme Ayna -destination 'platform=macOS' test -only-testing:aynaTests

# Never run unit + UI tests together
```

## Linting

```bash
swiftlint --strict && swiftformat .
```

## Style (differs from defaults)

| Avoid                         | Prefer                                       |
| ----------------------------- | -------------------------------------------- |
| `DispatchQueue.main.async`    | `@MainActor` or `await MainActor.run {}`     |
| `NavigationView`              | `NavigationStack`                            |
| `.foregroundColor()`          | `.foregroundStyle()`                         |
| `.cornerRadius()`             | `.clipShape(.rect(cornerRadius:))`           |
| `onTapGesture()`              | `Button`                                     |
| `#available` for new SDK APIs | `#if compiler(>=version)`                    |
| XCTest for unit tests         | Swift Testing (`@Suite`, `@Test`, `#expect`) |

## Key Files

- `Core/Services/AIService.swift` — AI service coordinator
- `Core/ViewModels/ConversationManager.swift` — App state
- `Core/Services/Providers/AIProviderProtocol.swift` — Provider protocol
- `Core/Diagnostics/DiagnosticsLogger.swift` — Use for all logging

## Detailed Docs

For detailed guidance, read the relevant doc before starting:

| Task                                | Read                                         |
| ----------------------------------- | -------------------------------------------- |
| Services, providers, concurrency    | [docs/architecture.md](docs/architecture.md) |
| Writing tests                       | [docs/testing.md](docs/testing.md)           |
| Platform-specific, SwiftUI patterns | [docs/platforms.md](docs/platforms.md)       |
| Architectural changes               | [docs/adr/README.md](docs/adr/README.md)     |
| Task planning, debugging            | [docs/workflow.md](docs/workflow.md)         |
| Bug patterns to avoid               | [docs/patterns.md](docs/patterns.md)         |
| Performance checklist               | [docs/performance.md](docs/performance.md)   |
