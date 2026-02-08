# Development Workflow

## Task Planning: Phases with Exit Criteria

For any non-trivial task, plan in phases with testable exit criteria before writing code. This ensures incremental progress and early detection of issues.

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
| macOS build succeeds | `xcodebuild -scheme Ayna -destination 'platform=macOS' build` |
| iOS build succeeds | `xcodebuild -scheme Ayna-iOS -destination 'platform=iOS Simulator,name=iPhone 17' build` |
| watchOS build succeeds (if applicable) | `xcodebuild -scheme Ayna-watchOS ...` |

**Exit gate**: All platform builds pass.

#### Phase 5: Quality Assurance

| Deliverable | Exit Criteria |
|-------------|---------------|
| Linting passes | `swiftlint --strict` reports 0 errors |
| Formatting applied | `swiftformat .` makes no changes |
| Full test suite passes | `xcodebuild test` succeeds |

**Exit gate**: CI-equivalent checks pass locally.

> **CI runs multiple Xcode versions** (16.2, 16.4, 26.0). Code that compiles on newer Xcode may fail on older versions due to stricter Swift concurrency checking. See [patterns.md](patterns.md#delegate-protocol-conformance-from-mainactor-classes) for common pitfalls.

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

### When Plans Go Sideways

If implementation deviates significantly from the plan — STOP and re-plan immediately. Don't push through hoping it will work out.

Signs you need to re-plan:
- Discovered the approach won't work mid-implementation
- Found unexpected dependencies or constraints
- The scope has grown beyond the original estimate
- Tests are failing in ways that suggest a design flaw

Re-planning is not failure — it's course correction.

---

## Debugging: Five Whys Technique

Before implementing a fix, ask "Why?" five times to find the root cause.

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

---

## Bug Fix Workflow: Test First, Then Fix

When a bug is reported, do not start by trying to fix it. Follow this workflow instead.

### Phase 1: Reproduce with a Test

1. Understand the bug report and identify the expected vs actual behavior
2. Write a failing test that reproduces the bug
3. Verify the test fails for the right reason (not a test error)

### Phase 2: Fix and Verify

1. Implement the fix
2. Run the failing test to confirm it now passes
3. Run the full test suite to ensure no regressions

### Why This Workflow?

- **Proves the bug exists** — A failing test is unambiguous evidence
- **Proves the fix works** — A passing test is unambiguous verification
- **Prevents regressions** — The test remains in the suite forever

### Example

```swift
// Step 1: Write failing test
@Test("Conversation saves when title contains emoji")
func conversationSavesWithEmojiTitle() async throws {
    let conversation = Conversation(title: "Test 🎉")
    try await store.save(conversation)
    let loaded = try await store.load(conversation.id)
    #expect(loaded?.title == "Test 🎉")
}

// Step 2: Fix the bug in ConversationPersistenceCoordinator.swift
// Step 3: Run test to verify fix
```
