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

## Ask vs. Proceed

**Ask the user when:**
- The request is ambiguous and multiple interpretations lead to significantly different implementations
- You're about to make a destructive or irreversible change
- The task requires choosing between architectural approaches with real trade-offs
- You're unsure if a dependency/library addition is acceptable
- The scope seems larger than what was requested

**Proceed without asking when:**
- The task is clear and you have high confidence in the approach
- You're following established patterns already in the codebase
- The decision is easily reversible (can be changed in review)
- You're fixing an obvious bug with a straightforward solution
- The user explicitly said "just do it" or similar

**Never ask:**
- "Is this plan okay?" — just present the plan and start working
- "Should I proceed?" — if you have a plan, execute it
- "Do you want me to X?" when X is clearly part of the task
- For permission to read files or explore the codebase

**Instead of asking, state your assumption:**
```
❌ "Should I use async/await or completion handlers?"
✅ "I'll use async/await since that's the pattern in this codebase. Starting implementation."
```

The bias should be toward **action with stated assumptions** rather than **questions that block progress**.

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
├── Exit: Understand AIService pattern, confirm no existing solution

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

### When Plans Go Sideways

If implementation deviates significantly from the plan — **STOP and re-plan immediately**. Don't push through hoping it will work out.

Signs you need to re-plan:
- Discovered the approach won't work mid-implementation
- Found unexpected dependencies or constraints
- The scope has grown beyond the original estimate
- Tests are failing in ways that suggest a design flaw

Re-planning is not failure — it's course correction. A revised plan beats a broken implementation.

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

## Bug Fix Workflow: Test First, Then Fix

When a bug is reported, **do not start by trying to fix it**. Follow this workflow instead:

### Phase 1: Reproduce with a Test
1. Understand the bug report and identify the expected vs actual behavior
2. Write a failing test that reproduces the bug
3. Verify the test fails for the right reason (not a test error)

### Phase 2: Fix with Subagents
1. Use subagents to attempt the fix in isolation
2. Each subagent should:
   - Propose a fix
   - Verify the fix by running the failing test
   - Confirm the test now passes
3. Review the subagent's fix before integrating

### Why This Workflow?
- **Proves the bug exists** — A failing test is unambiguous evidence
- **Proves the fix works** — A passing test is unambiguous verification
- **Prevents regressions** — The test remains in the suite forever
- **Enables parallel attempts** — Multiple subagents can try different approaches
- **Isolates context** — Subagents don't pollute the main conversation with failed attempts

### Example

```
# Step 1: Write failing test
With #runSubagent, write a Swift Testing test in Tests/aynaTests/ that reproduces:
"Conversation fails to save when title contains emoji"
The test should fail with the current implementation.

# Step 2: Fix with subagent
With #runSubagent, fix the bug in Core/Services/ConversationPersistenceCoordinator.swift
where emoji in titles causes save failures. Run the test from Step 1 to verify the fix.
Return the diff and test results.
```

## Critical Rules (Apply to EVERY task)

> 🚨 **NEVER leak secrets, API keys, or tokens** — Under NO circumstances include real API keys, authentication tokens, or any sensitive credentials in code, comments, logs, documentation, test fixtures, or any output. Always use placeholder values like `"REDACTED"`, `"mock-token"`, or `"test-key"` in examples and tests. This applies to all files including tests and docs.

> ⚠️ **NEVER run `git commit` or `git push`** — Always leave committing and pushing to the human.

> 🤖 **Document Your Prompts** — When completing a task, summarize the key prompt(s) used so the human can include them in the PR. This supports a workflow where prompts are reviewed alongside (or instead of) code.

> 🎯 **Simplicity First** — Make every change as simple as possible. Touch only what's necessary. Find root causes instead of applying temporary fixes. If a fix feels hacky, pause and ask: "Knowing everything I know now, is there a more elegant solution?"

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
| `#available` for new SDK APIs | `#if compiler(>=version)` (compile-time check) |
| `Task.detached` with `NSImage`/`UIImage` | Process on same actor or use `Data` |

## Common Bug Patterns to Avoid

These patterns have caused bugs in Swift/SwiftUI codebases. **Always check for these during code review.**

### Fire-and-Forget Tasks

```swift
// ❌ BAD: Task not tracked, errors lost, can't cancel
func sendMessage() {
    Task { await api.send(message) }
}

// ✅ GOOD: Track task, handle errors, support cancellation
private var sendTask: Task<Void, Error>?

func sendMessage() async throws {
    sendTask?.cancel()
    sendTask = Task {
        try await api.send(message)
    }
    try await sendTask?.value
}
```

### Optimistic Updates Without Proper Rollback

```swift
// ❌ BAD: CancellationError not handled, state permanently wrong
func toggleFavorite(_ item: Item) async {
    let previous = favorites[item.id]
    favorites[item.id] = !previous  // Optimistic update
    do {
        try await api.setFavorite(item.id, !previous)
    } catch {
        favorites[item.id] = previous  // Doesn't run on cancellation!
    }
}

// ✅ GOOD: Handle ALL errors including cancellation
func toggleFavorite(_ item: Item) async {
    let previous = favorites[item.id]
    favorites[item.id] = !previous
    do {
        try await api.setFavorite(item.id, !previous)
    } catch is CancellationError {
        favorites[item.id] = previous  // Rollback on cancel
        throw CancellationError()
    } catch {
        favorites[item.id] = previous  // Rollback on error
        throw error
    }
}
```

### `.onAppear` Instead of `.task` for Async Work

```swift
// ❌ BAD: Task not cancelled on disappear, can update stale view
.onAppear {
    Task { await viewModel.load() }
}

// ✅ GOOD: Lifecycle-managed, auto-cancelled on disappear
.task {
    await viewModel.load()
}

// ✅ GOOD: With ID for re-execution on change
.task(id: conversationId) {
    await viewModel.load(conversationId)
}
```

### ForEach with Unstable Identity

```swift
// ❌ BAD: Index-based identity causes wrong views during mutations
ForEach(messages.indices, id: \.self) { index in
    MessageRow(message: messages[index])
}

// ❌ BAD: Array enumeration recreates identity on every change
ForEach(Array(messages.enumerated()), id: \.offset) { index, message in
    MessageRow(message: message)
}

// ✅ GOOD: Use stable model identity
ForEach(messages) { message in
    MessageRow(message: message)
}

// ✅ GOOD: If you need index for display, use element ID
ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
    MessageRow(message: message, index: index)
}
```

### Background Tasks Not Cancelled on Deinit

```swift
// ❌ BAD: Task continues after ViewModel is deallocated
@Observable @MainActor
class ConversationViewModel {
    private var streamTask: Task<Void, Never>?

    func startStreaming() {
        streamTask = Task { /* ... */ }
    }
    // Missing deinit cleanup!
}

// ✅ GOOD: Cancel tasks in deinit
@Observable @MainActor
class ConversationViewModel {
    private var streamTask: Task<Void, Never>?

    func startStreaming() {
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            // ...
        }
    }

    deinit {
        streamTask?.cancel()
    }
}
```

### Static Shared Singletons with Mutable Assignment

```swift
// ❌ BAD: Race condition if multiple instances created
class ConversationViewModel {
    static var shared: ConversationViewModel?
    init() { Self.shared = self }  // Overwrites previous!
}

// ✅ GOOD: Use SwiftUI Environment for dependency injection
@Observable @MainActor
class ConversationViewModel { /* ... */ }

// In parent view:
.environment(conversationViewModel)

// In child view:
@Environment(ConversationViewModel.self) var viewModel
```

### Using `#available` for New SDK APIs

```swift
// ❌ BAD: #available is RUNTIME only — code still must COMPILE against older SDKs
// This fails to build on Xcode 16.x because .glassEffect() doesn't exist in the SDK
if #available(macOS 26.0, *) {
    view.glassEffect(.regular)  // Compile error on older SDKs!
}

// ✅ GOOD: Use compile-time checks for APIs that don't exist in older SDKs
#if compiler(>=6.2)  // Xcode 26+ ships Swift 6.2
if #available(macOS 26.0, *) {
    view.glassEffect(.regular)
}
#endif

// ✅ ALSO GOOD: Separate source files with build configurations
// Put macOS 26+ code in a separate file excluded from older SDK builds
```

**Key insight**: `#available` checks which OS version is *running*, but the compiler must still *parse and type-check* all code paths. For APIs that don't exist in older SDKs at all, use `#if compiler()` or `#if swift()` to hide the code from the compiler entirely.

### Passing Non-Sendable Types Across Actor Boundaries

```swift
// ❌ BAD: NSImage/UIImage are non-Sendable — can't cross actor boundaries
let image = await Task.detached(priority: .userInitiated) {
    return NSImage(data: imageData)  // NSImage created off main actor
}.value  // Error: non-sendable type cannot exit actor-isolated context

// ✅ GOOD: Keep image creation on the same actor
@MainActor
func loadImage(from data: Data) -> NSImage? {
    return NSImage(data: data)
}

// ✅ ALSO GOOD: Pass Sendable data, create image on destination actor
let imageData = await Task.detached {
    return processImageData(data)  // Data is Sendable
}.value
let image = NSImage(data: imageData)  // Create on @MainActor
```

**Why**: `NSImage` and `UIImage` are explicitly marked non-`Sendable` by Apple. Swift 6 strict concurrency enforces this to prevent data races.

### Accessing @MainActor Singletons from Nonisolated Context

```swift
// ❌ BAD: Accessing @MainActor static property from nonisolated context
@MainActor
class MyService {
    static let shared = MyService()
}

func someNonisolatedFunc() {
    let service = MyService.shared  // Warning in Swift 5, Error in Swift 6!
}

// ✅ GOOD: Make the accessor async and await it
func someNonisolatedFunc() async {
    let service = await MyService.shared
}

// ✅ ALSO GOOD: Mark the calling function @MainActor
@MainActor
func someMainActorFunc() {
    let service = MyService.shared  // OK — same actor isolation
}
```

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

> ⚠️ **NEVER run unit tests and UI tests together** — Always execute them separately to avoid resource conflicts and flaky results.

```bash
# Unit tests only
xcodebuild -scheme Ayna -destination 'platform=macOS' test -only-testing:aynaTests

# Full suite
xcodebuild -scheme Ayna -destination 'platform=macOS' test

# UI tests (run separately, ask permission first as they launch the app)
xcodebuild -scheme Ayna -destination 'platform=macOS' test -only-testing:aynaUITests
```

### Platform Feature Support

| Feature                        | macOS |  iOS  | watchOS |
| ------------------------------ | :---: | :---: | :-----: |
| OpenAI / Azure / GitHub Models |   ✅   |   ✅   |    ✅    |
| Apple Intelligence             |   ✅   |   ✅   |    ❌    |
| MCP Tools                      |   ✅   |   ❌   |    ❌    |
| Web Search (Tavily)            |   ✅   |   ✅   |    ✅    |
| Attach from App                |   ✅   |   ❌   |    ❌    |

## Key Files

- `Core/Services/AIService.swift` — Main AI service coordinator
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
- [ ] **Retry logic uses exponential backoff** — See `AIRetryPolicy` for the pattern
- [ ] **Large payloads are chunked** — Don't send/receive massive JSON in one request

### UI Performance

- [ ] **Conversation lists use `LazyVStack`** — Not `VStack` for potentially long lists
- [ ] **Message views avoid re-renders** — Extract expensive markdown rendering to subviews
- [ ] **No `await` calls inside `ForEach`** — Fetch data before iteration
- [ ] **Images/attachments use async loading** — Never block UI thread for file I/O
- [ ] **Search input is debounced** — Not firing on every keystroke
- [ ] **Frequently updating UI caches formatted strings** — Don't recompute on every render

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

### Concurrency Safety

- [ ] **No fire-and-forget `Task { }` without error handling** — Track tasks, handle errors
- [ ] **Optimistic updates handle `CancellationError` explicitly** — Rollback on cancel, not just on error
- [ ] **Background tasks cancelled in `deinit`** — Prevent work after deallocation
- [ ] **Using `.task` instead of `.onAppear { Task { } }`** — Lifecycle-managed, auto-cancelled
- [ ] **ForEach uses stable identity** — Use model ID, not array index
- [ ] **Non-Sendable types stay on their actor** — `NSImage`/`UIImage` don't cross actor boundaries
- [ ] **@MainActor singletons accessed correctly** — Use `await` or `@MainActor` caller

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
- [ ] Solution is as simple as possible — no over-engineering
- [ ] For non-trivial changes: paused to consider if there's a more elegant approach

### Testing
- [ ] New code has unit tests in `Tests/aynaTests/`
- [ ] Edge cases covered (empty states, errors, cancellation)
- [ ] Existing tests still pass
- [ ] **Never mark complete without proving it works** — run tests, check logs, demonstrate correctness
- [ ] For behavioral changes: diff behavior between main branch and your changes

### Security
- [ ] Secrets stored in Keychain (never UserDefaults or hardcoded)
- [ ] No force unwraps on user input or API responses
- [ ] Sensitive data not logged

### Platform Compatibility
- [ ] Builds on macOS, iOS, watchOS (as applicable)
- [ ] `#if os()` guards for platform-specific code in Core/
- [ ] No AppKit/UIKit imports in Core/ without guards
- [ ] New SDK APIs wrapped in `#if compiler()` for older Xcode compatibility

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

### "Value of type X has no member Y" (new SDK APIs)
- **Cause**: Using APIs from newer SDKs (e.g., macOS 26) with `#available` only
- **Fix**: Wrap in `#if compiler(>=version)` to hide from older compilers entirely
- **Prevention**: `#available` is runtime-only; new SDK APIs need compile-time guards

### "Conformance of 'NSImage' to 'Sendable' is unavailable"
- **Cause**: Passing `NSImage`/`UIImage` across actor boundaries via `Task.detached`
- **Fix**: Process images on the same actor, or pass `Data` and create image on destination
- **Prevention**: Platform image types are non-`Sendable`; don't cross actor boundaries with them

### "Main actor-isolated static property 'shared' cannot be referenced from nonisolated context"
- **Cause**: Accessing `@MainActor` singleton from nonisolated function
- **Fix**: Make caller `@MainActor` or use `await` to access the property
- **Prevention**: When using `@MainActor` singletons, ensure callers have compatible isolation

## Subagents (Context-Isolated Tasks)

VS Code's `#runSubagent` tool enables context-isolated task execution. Subagents run independently with their own context, preventing context confusion in complex tasks.

### When to Use Subagents

| Task Type | Use Subagent? | Rationale |
|-----------|---------------|-----------|
| Research unfamiliar code areas | Yes | Deep dives don't pollute main conversation |
| Review a single file for patterns | Yes | Focused analysis, returns summary only |
| Generate test fixtures | Yes | Boilerplate generation isolated from design discussion |
| Simple edits to known files | No | Direct action is faster |
| Multi-step refactoring | No | Needs continuous context across steps |
| Tasks requiring user feedback | No | Subagents don't pause for input |

### Subagent Prompts for This Project

**Code Pattern Analysis** — Understand existing patterns:
```
With #runSubagent, analyze #file:Core/Services/AIService.swift and identify:
1. How provider requests are constructed
2. Error handling patterns
3. How streaming responses are processed
Return a concise pattern guide for adding a new provider.
```

**Test Stub Generation** — Generate boilerplate:
```
Using #runSubagent, generate a Swift Testing test struct following the pattern in #file:Tests/aynaTests/
for testing a new EncryptionService with encrypt/decrypt methods.
Return only the struct definition with placeholder test methods.
```

**Performance Audit** — Isolated deep dive:
```
With #runSubagent, audit #file:Views/macOS/ConversationView.swift for SwiftUI performance issues.
Check for: await in ForEach, missing LazyVStack, inline image loading, excessive state updates.
Return a prioritized list of issues with line numbers.
```

### Subagent Best Practices

1. **Be specific in prompts** — Subagents don't have conversation history; include all necessary context
2. **Request structured output** — Ask for summaries, lists, or code snippets that integrate cleanly
3. **Use for exploration, not execution** — Subagents are great for research; keep edits in main context
4. **Combine with file references** — Use `#file:path` to give subagents focused context
5. **Review before integrating** — Subagent results join main context; verify accuracy first
6. **One task per subagent** — Keep subagents focused; split complex work into multiple subagents
7. **Offload to keep context clean** — Use subagents for research, exploration, and parallel analysis to prevent context pollution in the main conversation

### Anti-Patterns

- Using subagents for quick lookups (overhead not worth it)
- Chaining multiple subagents (use main context for multi-step work)
- Expecting subagents to remember previous subagent results
- Using subagents for tasks requiring user clarification

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

### Self-Improvement Loop

After ANY correction from the user, immediately update this document:
1. Identify the pattern that led to the mistake
2. Write a rule that prevents the same mistake
3. Add it to the appropriate section above

This creates a feedback loop where each correction improves future behavior. The goal is to reduce the same mistake from happening twice.
