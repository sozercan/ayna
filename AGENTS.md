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

## Task Planning: Phases with Exit Criteria

For any non-trivial task, **plan in phases with testable exit criteria** before writing code. This ensures incremental progress and early detection of issues.

### Phase Structure

Every task should be broken into phases. Each phase must have:
1. **Clear deliverable** — What artifact or change is produced
2. **Testable exit criteria** — How to verify the phase is complete
3. **Rollback point** — The phase should leave the codebase in a working state

### Standard Phases

#### Phase 1: Research & Understanding
| Deliverable | Exit Criteria |
|-------------|---------------|
| Identify affected files and dependencies | List all files to modify/create |
| Understand existing patterns | Can explain how similar features work |
| Read relevant docs | Confirmed patterns in `docs/` apply |

**Exit gate**: Can articulate the implementation plan without ambiguity.

#### Phase 2: Interface Design
| Deliverable | Exit Criteria |
|-------------|---------------|
| Define new types/protocols | Type signatures compile |
| Plan public API surface | No breaking changes to existing callers (or changes identified) |
| Identify platform constraints | `#if os()` guards planned where needed |

**Exit gate**: `xcodebuild build` succeeds with stub implementations.

#### Phase 3: Core Implementation
| Deliverable | Exit Criteria |
|-------------|---------------|
| Implement business logic | Unit tests pass for new code |
| Handle error cases | Error paths have test coverage |
| Add logging | `DiagnosticsLogger` calls in place |

**Exit gate**: `xcodebuild test -only-testing:aynaTests` passes.

#### Phase 4: Platform Integration
| Deliverable | Exit Criteria |
|-------------|---------------|
| macOS build succeeds | `xcodebuild -scheme Ayna -destination 'platform=macOS' build` ✅ |
| iOS build succeeds | `xcodebuild -scheme Ayna-iOS -destination 'platform=iOS Simulator,name=iPhone 17' build` ✅ |
| watchOS build succeeds (if applicable) | `xcodebuild -scheme Ayna-watchOS ...` ✅ |

**Exit gate**: All platform builds pass.

#### Phase 5: Quality Assurance
| Deliverable | Exit Criteria |
|-------------|---------------|
| Linting passes | `swiftlint --strict` reports 0 errors |
| Formatting applied | `swiftformat .` makes no changes |
| Full test suite passes | `xcodebuild test` succeeds |

**Exit gate**: CI-equivalent checks pass locally.

### Example: Adding a New Service

```
Phase 1: Research
├── Exit: Understand OpenAIService pattern, confirm no existing solution

Phase 2: Interface
├── Create NewService.swift with protocol + stub
├── Exit: `xcodebuild build` passes on macOS

Phase 3: Implementation
├── Implement methods, add error handling
├── Create NewServiceTests.swift
├── Exit: `xcodebuild test -only-testing:aynaTests/NewServiceTests` passes

Phase 4: Integration
├── Wire into ConversationManager or relevant ViewModel
├── Exit: All 3 platform builds pass

Phase 5: QA
├── Run swiftlint, swiftformat
├── Exit: Full test suite passes, no lint errors
```

### Checkpoint Communication

After each phase, briefly report:
- ✅ What was completed
- 🧪 Test/verification results
- ➡️ Next phase plan

This keeps the human informed and provides natural points to course-correct.

## Critical Rules (Apply to EVERY task)

> ⚠️ **NEVER run `git commit` or `git push`** — Always leave committing and pushing to the human.

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

5. **Use Modern SwiftUI APIs**: See [docs/platforms.md](docs/platforms.md#swiftui-api-best-practices) for details.
   - `.foregroundStyle()` not `.foregroundColor()`
   - `.clipShape(.rect(cornerRadius:))` not `.cornerRadius()`
   - `onChange(of:) { _, newValue in }` (two-param closure)
   - `Task.sleep(for: .seconds())` not `Task.sleep(nanoseconds:)`
   - `NavigationStack` not `NavigationView`
   - `Button` not `onTapGesture()` (unless tap location needed)
   - `Tab` API not `tabItem()`
   - Avoid `AnyView` — use concrete types or `@ViewBuilder`
   - Add `.accessibilityLabel()` to image-only buttons

6. **No Third-Party Frameworks**: Do not introduce third-party dependencies without asking first.

7. **Swift Concurrency**: Always mark `@Observable` classes with `@MainActor`. Never use `DispatchQueue` — use Swift concurrency (`async`/`await`, `MainActor`).

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
| Attach from App                |   ✅   |   ❌   |    ❌    |

## Key Files

- `Core/Services/OpenAIService.swift` — Main AI service coordinator
- `Core/ViewModels/ConversationManager.swift` — App-wide state management
- `Core/Services/ConversationPersistenceCoordinator.swift` — Save/load orchestration
- `Core/Diagnostics/DiagnosticsLogger.swift` — Logging (use this for all logs)
