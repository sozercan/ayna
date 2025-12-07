# AGENTS.md

Guidance for AI coding assistants (Claude, GitHub Copilot, Cursor, etc.) working on this repository.

## Role

You are a Senior Swift Engineer specializing in SwiftUI, Swift Concurrency, and cross-platform Apple development. Your code must adhere to Apple's Human Interface Guidelines. Target Swift 6.0+, macOS 14.0+, iOS 17.0+, watchOS 10.0+.

## What is Ayna?

A native **macOS/iOS/watchOS** ChatGPT client built with **Swift** and **SwiftUI**.

- Multi-provider: OpenAI, Azure, GitHub Models, Apple Intelligence, local models (AIKit)
- Multi-model chat: Compare responses from multiple models simultaneously
- Privacy-focused: API keys in Keychain, conversations encrypted on disk

## Project Structure

```
App/        → Platform entry points (aynaApp.swift, AynaIOSApp.swift, AynaWatchApp.swift)
Core/       → Shared logic (Models, ViewModels, Services, Utilities) — MUST compile for all platforms
Views/      → Platform-specific UI (macOS/, iOS/, watchOS/)
Tests/      → Unit tests (aynaTests/) and UI tests (aynaUITests/)
docs/       → Detailed documentation for AI agents
```

## Before You Start: Read the Relevant Docs

**Always consult these docs before making changes.** They contain detailed patterns and examples.

| If your task involves...                       | Read this first                              |
| ---------------------------------------------- | -------------------------------------------- |
| Services, providers, data flow, concurrency    | [docs/architecture.md](docs/architecture.md) |
| Writing or running tests                       | [docs/testing.md](docs/testing.md)           |
| Platform-specific features, SwiftUI patterns   | [docs/platforms.md](docs/platforms.md)       |

## Critical Rules (Apply to EVERY task)

1. **Cross-Platform Compilation**: Code in `Core/` must build for macOS, iOS, AND watchOS. Never use `AppKit`/`UIKit` in `Core/` without `#if os()` guards.

2. **Verify Builds**: After modifying shared code, verify both platforms:
   ```bash
   xcodebuild -scheme Ayna -destination 'platform=macOS' build
   xcodebuild -scheme Ayna-iOS -destination 'platform=iOS Simulator,name=iPhone 17' build
   ```

3. **Linting**: Run after non-trivial changes:
   ```bash
   swiftlint --strict && swiftformat .
   ```

4. **Unit Tests Required**: New code in `Core/` must include tests in `Tests/aynaTests/`.

5. **Never `git push`**: Leave pushing to the human.

6. **Use Modern SwiftUI APIs**: See [docs/platforms.md](docs/platforms.md#swiftui-api-best-practices) for details.
   - `.foregroundStyle()` not `.foregroundColor()`
   - `.clipShape(.rect(cornerRadius:))` not `.cornerRadius()`
   - `onChange(of:) { _, newValue in }` (two-param closure)
   - `Task.sleep(for: .seconds())` not `Task.sleep(nanoseconds:)`
   - `NavigationStack` not `NavigationView`
   - `Button` not `onTapGesture()` (unless tap location needed)
   - `Tab` API not `tabItem()`
   - Avoid `AnyView` — use concrete types or `@ViewBuilder`
   - Add `.accessibilityLabel()` to image-only buttons

7. **No Third-Party Frameworks**: Do not introduce third-party dependencies without asking first.

8. **Swift Concurrency**: Always mark `@Observable` classes with `@MainActor`. Never use `DispatchQueue` — use Swift concurrency (`async`/`await`, `MainActor`).

## Quick Style Rules

| ❌ Avoid | ✅ Prefer |
|----------|-----------|
| `DispatchQueue.main.async` | `await MainActor.run {}` or `@MainActor` |
| `NavigationView` | `NavigationStack` |
| `onTapGesture()` | `Button` (unless tap location needed) |
| `tabItem()` | `Tab` API |
| `AnyView` | Concrete types or `@ViewBuilder` |
| `String(format: "%.2f", n)` | `Text(n, format: .number.precision(...))` |
| `replacingOccurrences(of:with:)` | `replacing(_:with:)` |
| Force unwraps (`!`) | Optional handling or `guard` |

## Quick Reference

### Build Commands

```bash
# macOS
xcodebuild -scheme Ayna -destination 'platform=macOS' build

# iOS
xcodebuild -scheme Ayna-iOS -destination 'platform=iOS Simulator,name=iPhone 17' build

# watchOS
xcodebuild -scheme Ayna-watchOS -destination 'platform=watchOS Simulator,name=Apple Watch Ultra 3 (49mm)' build
```

### Test Commands

```bash
# Unit tests only
xcodebuild -scheme Ayna -destination 'platform=macOS' test -only-testing:aynaTests

# Full suite
xcodebuild -scheme Ayna -destination 'platform=macOS' test
```

### Platform Feature Support

| Feature                        | macOS |  iOS  | watchOS |
| ------------------------------ | :---: | :---: | :-----: |
| OpenAI / Azure / GitHub Models |   ✅   |   ✅   |    ✅    |
| Apple Intelligence             |   ✅   |   ✅   |    ❌    |
| AIKit (Local)                  |   ✅   |   ❌   |    ❌    |
| MCP Tools                      |   ✅   |   ❌   |    ❌    |
| Web Search (Tavily)            |   ✅   |   ✅   |    ✅    |

## Key Files

- `Core/Services/OpenAIService.swift` — Main AI service coordinator
- `Core/ViewModels/ConversationManager.swift` — App-wide state management
- `Core/Services/ConversationPersistenceCoordinator.swift` — Save/load orchestration
- `Core/Diagnostics/DiagnosticsLogger.swift` — Logging (use this for all logs)
