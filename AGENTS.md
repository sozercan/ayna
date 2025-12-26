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

## Before You Start: Context Loading

**Before starting any non-trivial task, load context systematically:**

1. **Read core docs** based on your task:

| If your task involves...                       | Read this first                              |
| ---------------------------------------------- | -------------------------------------------- |
| Services, providers, data flow, concurrency    | [docs/architecture.md](docs/architecture.md) |
| Writing or running tests                       | [docs/testing.md](docs/testing.md)           |
| Platform-specific features, SwiftUI patterns   | [docs/platforms.md](docs/platforms.md)       |
| Significant architectural changes              | [docs/adr/README.md](docs/adr/README.md)     |

2. **Understand recent changes**: `git log --oneline -10`
3. **Identify affected subsystem**: Which Services/ViewModels/Views are involved?
4. **Review related tests**: Find existing tests for similar functionality
5. **Check for prior art**: Search codebase for similar patterns

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

## Debugging: Five Whys Technique

Before implementing a fix, ask "Why?" five times to find the root cause:

**Example:**
1. Why did the crash occur? → Memory pressure
2. Why memory pressure? → Array growing unbounded
3. Why unbounded? → No pagination in conversation loading
4. Why no pagination? → Original spec assumed small conversations
5. Why that assumption? → Requirements didn't consider power users

**Root Cause**: Missing pagination in `EncryptedConversationStore`  
**Solution**: Add lazy loading + paginate large conversations

**Best Practices:**
- Focus on process/code, not blame
- Look for systemic issues (missing tests, unclear requirements)
- Document the analysis in commit messages
- Verify the fix addresses the root cause, not just the symptom

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

8. **Use Swift Testing for Unit Tests**: Unit tests use [Swift Testing](https://developer.apple.com/documentation/testing), not XCTest. UI tests remain on XCTest.
   ```swift
   import Foundation
   import Testing
   @testable import Ayna

   @Suite("MyService Tests")
   @MainActor  // Add if testing @MainActor types
   struct MyServiceTests {
       private var sut: MyService
       
       init() {
           // Setup - runs before each test
           sut = MyService()
       }
       
       @Test("Something works correctly")
       func somethingWorksCorrectly() {
           #expect(sut.value == expectedValue)
       }
   }
   ```
   Key differences from XCTest:
   - `@Suite` struct instead of `XCTestCase` class
   - `init()` instead of `setUp()`
   - `@Test("description")` instead of `func testXxx()`
   - `#expect(condition)` instead of `XCTAssert*()`
   - `Issue.record()` instead of `XCTFail()`
   - `confirmation { confirm in ... }` instead of `XCTestExpectation`

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
| XCTest for unit tests | Swift Testing (`@Suite`, `@Test`, `#expect`) |

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
- `Core/Services/Providers/AIProviderProtocol.swift` — Provider abstraction protocol
- `Core/ViewModels/ConversationManager.swift` — App-wide state management
- `Core/Services/ConversationPersistenceCoordinator.swift` — Save/load orchestration
- `Core/Models/AynaError.swift` — Unified error types
- `Core/Utilities/ErrorPresenter.swift` — User-friendly error presentation
- `Core/Diagnostics/DiagnosticsLogger.swift` — Logging (use this for all logs)

## Performance Checklist

Before completing non-trivial features, verify these patterns are followed:

### Streaming & Network

- [ ] **Streaming responses handled incrementally** — Never buffer entire response before displaying
- [ ] **Network requests are cancellable** — Use `Task` with proper cancellation, not fire-and-forget
- [ ] **Retry logic uses exponential backoff** — See `OpenAIRetryPolicy` for the pattern
- [ ] **Large payloads are chunked** — Don't send/receive massive JSON in one request

### UI Performance

- [ ] **Conversation lists use `LazyVStack`** — Not `VStack` for potentially long lists
- [ ] **Message views avoid re-renders** — Extract expensive markdown rendering to subviews
- [ ] **No `await` calls inside `ForEach`** — Fetch data before iteration
- [ ] **Images/attachments use async loading** — Never block UI thread for file I/O

### Memory Management

- [ ] **Streaming chunks are processed, not accumulated** — `StreamingChunkBuffer` clears after processing
- [ ] **Attachments cleaned up on conversation delete** — `AttachmentStorage` handles orphan cleanup
- [ ] **Long conversations paginate** — Don't load 1000+ messages into memory at once
- [ ] **Observation is scoped** — Use `@Observable` on small units, not entire app state

### Persistence

- [ ] **Saves are debounced** — Don't save on every keystroke; use `ConversationPersistenceCoordinator`
- [ ] **Encryption happens off main thread** — Use `Task { }` for crypto operations
- [ ] **Metadata loads fast** — Conversation list shouldn't decrypt all content upfront

### MCP & Subprocess (macOS only)

- [ ] **MCP processes are tracked** — `MCPProcessTracker` monitors lifecycle
- [ ] **Subprocess timeouts enforced** — Don't let hung tools block indefinitely
- [ ] **Resources cleaned up on termination** — Processes killed on app quit

### Cross-Platform

- [ ] **Core code avoids platform-specific overhead** — No UIKit/AppKit in Core without guards
- [ ] **watchOS is memory-conscious** — Smaller buffers, fewer cached items
- [ ] **iOS handles backgrounding** — Save state before suspension

### Verification Commands

```bash
# Profile memory usage (Instruments)
xcrun xctrace record --template 'Allocations' --launch -- /path/to/Ayna.app

# Check for main thread violations
xcrun xctrace record --template 'Main Thread Checker' --launch -- /path/to/Ayna.app
```

## Architecture Decision Records

For significant architectural decisions, document them in `docs/adr/`. See [docs/adr/README.md](docs/adr/README.md) for the format and existing decisions.

Current ADRs:
- [ADR-0001: Multi-Provider Architecture](docs/adr/0001-multi-provider-architecture.md)
- [ADR-0002: Encrypted Conversation Storage](docs/adr/0002-encrypted-conversation-storage.md)
- [ADR-0003: Cross-Platform Core Module](docs/adr/0003-cross-platform-core.md)

## PR Self-Review Checklist

Before requesting human review, verify:

### Code Quality
- [ ] Code is clean, readable, and follows existing patterns
- [ ] No TODO comments left unaddressed
- [ ] Error handling is complete (no silent failures)
- [ ] `DiagnosticsLogger` calls added for debugging

### Testing
- [ ] New code has unit tests in `Tests/aynaTests/`
- [ ] Edge cases covered (empty states, errors, cancellation)
- [ ] Existing tests still pass

### Security
- [ ] Secrets stored in Keychain (never UserDefaults or hardcoded)
- [ ] No force unwraps on user input or API responses
- [ ] Sensitive data not logged

### Platform Compatibility
- [ ] Builds on macOS, iOS, watchOS (as applicable)
- [ ] `#if os()` guards for platform-specific code in Core/
- [ ] No AppKit/UIKit imports in Core/ without guards

### Accessibility
- [ ] `.accessibilityLabel()` on image-only buttons
- [ ] Dynamic Type supported (no fixed font sizes)
- [ ] VoiceOver navigation logical

### Performance
- [ ] No `await` inside `ForEach` or loops
- [ ] Large lists use `LazyVStack`
- [ ] Streaming responses handled incrementally

## Common Errors & Solutions

### "Cannot find X in scope" (cross-platform builds)
- **Cause**: AppKit/UIKit used in `Core/` without platform guard
- **Fix**: Add `#if os(macOS)` / `#if os(iOS)` guards
- **Prevention**: Always verify iOS build after Core changes

### "Reference to captured var in concurrently-executing code"
- **Cause**: Mutable state accessed across actor boundaries
- **Fix**: Make the type `Sendable` or use `@MainActor`
- **Prevention**: Mark `@Observable` classes with `@MainActor`

### "Thread 1: Fatal error: Unexpectedly found nil"
- **Cause**: Force unwrap (`!`) on optional that was nil
- **Fix**: Use `guard let` or optional chaining
- **Prevention**: Avoid `!` except in tests with known values

### "Expression type is ambiguous without more context"
- **Cause**: SwiftUI view builder can't infer types
- **Fix**: Add explicit type annotations or break into smaller views
- **Prevention**: Extract complex views into separate structs

### Streaming response stops mid-message
- **Cause**: Task cancelled or error not propagated
- **Fix**: Check `Task.isCancelled` and handle errors in stream
- **Prevention**: Use `AsyncThrowingStream` with proper error handling

## When to Update This Document

**Add new rules when:**
- A pattern is used in 3+ places
- Code reviews repeatedly flag the same issue
- A bug could have been prevented by a documented rule
- New security or performance patterns emerge

**Update existing rules when:**
- Better examples exist in the codebase
- Edge cases are discovered
- APIs or patterns have changed

**Remove rules when:**
- They cause more confusion than they prevent
- The underlying issue no longer applies
- They duplicate other documentation
