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
Sources/Ayna/  → All source code (single SwiftPM executableTarget)
  App/         → Platform entry points (aynaApp.swift, AynaIOSApp.swift, AynaWatchApp.swift)
  Models/      → Data models (cross-platform)
  Services/    → AI providers, persistence, MCP, etc.
  ViewModels/  → App state management
  Utilities/   → Helpers, extensions
  Design/      → Design tokens, shared UI components
  Diagnostics/ → Logging
  Views/       → Platform-specific UI (macOS/, iOS/, watchOS/)
  Resources/   → App icons
Tests/         → Unit tests (AynaTests/) and UI tests (AynaUITests/)
Scripts/       → Build and signing scripts
docs/          → Detailed documentation for AI agents
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

1. **Cross-Platform Compilation**: Code in `Sources/Ayna/` must build for macOS, iOS, AND watchOS. Never use `AppKit`/`UIKit` without `#if os()` guards.

2. **Verify Builds**: After modifying shared code, verify all platforms (see Build Commands below).

3. **Linting**: Run `swiftlint --strict && swiftformat .` after non-trivial changes.

4. **Unit Tests Required**: New code in `Sources/Ayna/` must include tests in `Tests/AynaTests/`. Use Swift Testing framework (see [docs/testing.md](docs/testing.md)).

5. **Modern SwiftUI APIs**: Follow the API preferences in [docs/platforms.md](docs/platforms.md#swiftui-api-best-practices).

6. **No Third-Party Frameworks**: Do not introduce third-party dependencies without asking first.

7. **Swift Concurrency**: Always mark `@Observable` classes with `@MainActor`. Never use `DispatchQueue` — use Swift concurrency (`async`/`await`, `MainActor`).

## Project-Specific Pitfalls

- Never import `AppKit`/`UIKit` in `Sources/Ayna/` without `#if os()` guards — this breaks cross-platform builds
- Never use `#available` alone for new SDK APIs — wrap in `#if compiler(>=version)` for older Xcode compatibility
- Always cancel background `Task`s in `deinit` — uncancelled tasks cause work after deallocation
- Use `.task { }` instead of `.onAppear { Task { } }` — ensures lifecycle management and auto-cancellation
- Secrets go in Keychain, never `UserDefaults` or hardcoded values

## Build & Test Commands

```bash
# macOS
swift build

# iOS (compile check)
swift build --triple arm64-apple-ios26.0

# watchOS (compile check)
swift build --triple arm64-apple-watchos26.0

# Unit tests
swift test

# Package .app bundle
Scripts/build-app.sh

# Dev loop (build + run)
Scripts/compile_and_run.sh
```

> ⚠️ **NEVER run unit tests and UI tests together** — Always execute them separately to avoid resource conflicts and flaky results.

## Key Files

- `Sources/Ayna/Services/AIService.swift` — Main AI service coordinator
- `Sources/Ayna/Services/Providers/AIProviderProtocol.swift` — Provider abstraction protocol
- `Sources/Ayna/ViewModels/ConversationManager.swift` — App-wide state management
- `Sources/Ayna/Services/ConversationPersistenceCoordinator.swift` — Save/load orchestration
- `Sources/Ayna/Models/AynaError.swift` — Unified error types
- `Sources/Ayna/Utilities/ErrorPresenter.swift` — User-friendly error presentation
- `Sources/Ayna/Diagnostics/DiagnosticsLogger.swift` — Logging (use this for all logs)

## Architecture Decision Records

For significant architectural decisions, document them in `docs/adr/`. See [docs/adr/README.md](docs/adr/README.md) for the format and existing decisions.

Current ADRs:
- [ADR-0001: Multi-Provider Architecture](docs/adr/0001-multi-provider-architecture.md)
- [ADR-0002: Encrypted Conversation Storage](docs/adr/0002-encrypted-conversation-storage.md)
- [ADR-0003: Cross-Platform Core Module](docs/adr/0003-cross-platform-core.md)
- [ADR-0004: Sparkle Auto-Updates](docs/adr/0004-sparkle-auto-updates.md)
- [ADR-0005: Anthropic Provider Architecture](docs/adr/0005-anthropic-provider.md)
