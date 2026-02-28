# AGENTS.md

Guidance for AI coding assistants (Claude, GitHub Copilot, Cursor, etc.) working on this repository.

## Role

You are a Senior Swift Engineer specializing in SwiftUI, Swift Concurrency, and cross-platform Apple development. Your code must adhere to Apple's Human Interface Guidelines. Target Swift 6.0+, macOS 14.0+, iOS 17.0+, watchOS 10.0+.

## What is Ayna?

A native **macOS/iOS/watchOS** ChatGPT client built with **Swift** and **SwiftUI**.

- Multi-provider: OpenAI, Azure, GitHub Models, Apple Intelligence
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

## Before You Start

Read the relevant doc before starting non-trivial tasks:

| If your task involves...                       | Read this first                              |
| ---------------------------------------------- | -------------------------------------------- |
| Services, providers, data flow, concurrency    | [docs/architecture.md](docs/architecture.md) |
| Writing or running tests                       | [docs/testing.md](docs/testing.md)           |
| Platform-specific features, SwiftUI patterns   | [docs/platforms.md](docs/platforms.md)       |
| Significant architectural changes              | [docs/adr/README.md](docs/adr/README.md)     |

## Critical Rules

> 🚨 **NEVER leak secrets, API keys, or tokens** — Use placeholder values like `"REDACTED"`, `"mock-token"`, or `"test-key"` in all code, tests, and docs.

> 🤖 **Document Your Prompts** — When completing a task, summarize the key prompt(s) used so the human can include them in the PR.

1. **Cross-Platform Compilation**: Code in `Core/` must build for macOS, iOS, AND watchOS. Never use `AppKit`/`UIKit` in `Core/` without `#if os()` guards.

2. **Verify Builds**: After modifying shared code, verify all platforms (see Build Commands below).

3. **Linting**: Run `swiftlint --strict && swiftformat .` after non-trivial changes.

4. **Unit Tests Required**: New code in `Core/` must include tests in `Tests/aynaTests/`. Use Swift Testing framework (see [docs/testing.md](docs/testing.md)).

5. **Modern SwiftUI APIs**: Follow the API preferences in [docs/platforms.md](docs/platforms.md#swiftui-api-best-practices).

6. **No Third-Party Frameworks**: Do not introduce third-party dependencies without asking first.

7. **Swift Concurrency**: Always mark `@Observable` classes with `@MainActor`. Never use `DispatchQueue` — use Swift concurrency (`async`/`await`, `MainActor`).

## Project-Specific Pitfalls

- Never import `AppKit`/`UIKit` in `Core/` without `#if os()` guards — this breaks cross-platform builds
- Never use `#available` alone for new SDK APIs — wrap in `#if compiler(>=version)` for older Xcode compatibility
- Always cancel background `Task`s in `deinit` — uncancelled tasks cause work after deallocation
- Use `.task { }` instead of `.onAppear { Task { } }` — ensures lifecycle management and auto-cancellation
- Secrets go in Keychain, never `UserDefaults` or hardcoded values

## Build & Test Commands

```bash
# macOS
xcodebuild -scheme Ayna -destination 'platform=macOS' build

# iOS
xcodebuild -scheme Ayna-iOS -destination 'platform=iOS Simulator,name=iPhone 17' build

# watchOS
xcodebuild -scheme Ayna-watchOS -destination 'platform=watchOS Simulator,name=Apple Watch Ultra 3 (49mm)' build

# Unit tests only (run separately from UI tests)
xcodebuild -scheme Ayna -destination 'platform=macOS' test -only-testing:aynaTests

# UI tests (run separately — launches the app)
xcodebuild -scheme Ayna -destination 'platform=macOS' test -only-testing:aynaUITests
```

> ⚠️ **NEVER run unit tests and UI tests together** — Always execute them separately to avoid resource conflicts and flaky results.

## Key Files

- `Core/Services/AIService.swift` — Main AI service coordinator
- `Core/Services/Providers/AIProviderProtocol.swift` — Provider abstraction protocol
- `Core/ViewModels/ConversationManager.swift` — App-wide state management
- `Core/Services/ConversationPersistenceCoordinator.swift` — Save/load orchestration
- `Core/Models/AynaError.swift` — Unified error types
- `Core/Utilities/ErrorPresenter.swift` — User-friendly error presentation
- `Core/Diagnostics/DiagnosticsLogger.swift` — Logging (use this for all logs)

## Architecture Decision Records

For significant architectural decisions, document them in `docs/adr/`. See [docs/adr/README.md](docs/adr/README.md) for the format and existing decisions.

Current ADRs:
- [ADR-0001: Multi-Provider Architecture](docs/adr/0001-multi-provider-architecture.md)
- [ADR-0002: Encrypted Conversation Storage](docs/adr/0002-encrypted-conversation-storage.md)
- [ADR-0003: Cross-Platform Core Module](docs/adr/0003-cross-platform-core.md)
- [ADR-0004: Sparkle Auto-Updates](docs/adr/0004-sparkle-auto-updates.md)
- [ADR-0005: Anthropic Provider Architecture](docs/adr/0005-anthropic-provider.md)
