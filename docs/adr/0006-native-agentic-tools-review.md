# Review: ADR-0006 Native Agentic Tools Architecture

**Reviewers**: Claude Opus 4.5, GPT 5.2 Codex, Gemini 3 Pro (simulated multi-model review)  
**Date**: 2025-01-31  
**Status**: Review Complete

---

## Security & Safety Concerns

### 🔴 Critical: ShellSandbox Bypass Risks

The blocklist approach (`defaultBlocked`) is fundamentally flawed. Attackers can bypass it trivially:
- `sudo` blocked → `doas`, `pkexec`, or scripts that invoke sudo
- `rm -rf /` blocked → `find / -delete`, `perl -e 'unlink($_) for ...'`, or encoding tricks
- No mention of command chaining: `git status; rm -rf /` would pass the `git` allowlist

**Recommendation**: Invert to allowlist-only by default. Parse commands AST-style (not string matching) using a proper shell parser. Consider using `sandbox-exec` (macOS) for true sandboxing rather than string validation.

### 🔴 Critical: Path Traversal Not Addressed

`read_file(path: String)` accepts arbitrary paths. What prevents:
- Symlink attacks: `ln -s ~/.ssh/id_rsa /project/link.txt` then `read_file("link.txt")`
- `..` traversal: `read_file("../../../.ssh/id_rsa")`

**Recommendation**: Canonicalize paths with `URL.resolvingSymlinksInPath()` and validate against the project root *after* resolution.

### 🟡 Medium: `@MainActor` Singleton Anti-pattern

```swift
@MainActor
final class BuiltinToolService: ObservableObject {
    static let shared = BuiltinToolService()
```

AGENTS.md explicitly warns against this pattern. Accessing `BuiltinToolService.shared` from nonisolated contexts will fail in Swift 6.

**Recommendation**: Use dependency injection via SwiftUI Environment (per AGENTS.md guidance).

### 🟡 Medium: Protected Paths List is Incomplete

`~/.ssh, ~/.aws, ~/.gnupg, /etc` misses:
- `~/.config` (contains secrets for many tools)
- `~/.kube` (Kubernetes credentials)
- `~/Library/Keychains`
- `.env` files in any directory
- `.git/config` (can contain credentials)

**Recommendation**: Provide a more comprehensive default list with documentation explaining the risks.

---

## Architecture & Design

### 🟡 Medium: Missing Error Taxonomy

The plan doesn't define how tool failures communicate back to models. Distinguish:
1. Permission denied (user said no)
2. Sandbox blocked (security policy)
3. Execution failed (file not found, command exited non-zero)
4. Timeout exceeded

Models need structured errors to recover gracefully. Currently, `AynaError.swift` exists—extend it with `ToolExecutionError` cases.

### 🟡 Medium: Approval Queue Race Conditions

```swift
@Published var pendingApprovals: [PendingApproval] = []
```

What happens if:
- Two tool calls request approval simultaneously?
- User closes conversation with pending approvals?
- App terminates with unapproved operations?

**Recommendation**: Define queue behavior, orphan handling, and timeout policy (auto-deny after N seconds?).

### 🟡 Medium: Unclear `edit_file` Semantics

```swift
func editFile(path: String, oldText: String, newText: String) async throws
```

- Does `oldText` need to match exactly or is it fuzzy?
- What if `oldText` appears multiple times?
- What about encoding (UTF-8 vs. other)?
- Binary files?

These are exactly the edge cases that cause real bugs. Define behavior explicitly.

### 🟢 Suggestion: Missing Undo/Rollback

Phase 4 mentions "checkpoint system" but no undo mechanism for file operations. After `write_file` creates a file, how does the user revert?

**Recommendation**: Store file backup before modification, add `undo_last_operation` tool or at minimum log original content for manual recovery.

---

## User Experience

### 🟡 Medium: Approval Fatigue

If a model performs 15 file edits, does the user click "Allow" 15 times? The `askOnce` pattern helps but is session-scoped and path-specific.

**Recommendation**: Add batch approval: "Allow all remaining file operations in this conversation?" with a summary.

### 🟡 Medium: No Visual Diff for Edit Operations

`edit_file` shows only "File edited" after approval. Users should see what changed.

**Recommendation**: Show inline diff preview in `ApprovalRequestView` before user approves.

### 🟢 Suggestion: Progress for Long Operations

`run_command` with `xcodebuild` could take minutes. No streaming output mentioned.

**Recommendation**: Stream stdout/stderr to UI incrementally (like terminal).

---

## Implementation Phasing

### 🔴 Issue: Phase 1 Ships Without Safety

Phase 1 creates `BuiltinToolService` and `PermissionService` but `ShellSandbox` arrives in Phase 2. This means Phase 1 could deploy with unsafe command execution.

**Recommendation**: Move `ShellSandbox` to Phase 1 or gate `run_command` behind a feature flag until Phase 2 completes.

### 🟡 Medium: iOS Build Verification Gap

Phase 1-3 only verify macOS builds. iOS is checked in Phase 4, but Core/ code added in earlier phases could break iOS.

**Recommendation**: Add iOS build check to every phase's exit gate (even if tools are disabled on iOS, the code must still compile).

---

## Missing Considerations

### 1. Audit Logging

No mention of logging tool invocations. For security and debugging, every tool call (especially shell commands) should be logged persistently.

### 2. Rate Limiting

What prevents a rogue model from requesting 1000 file reads in a loop? Add rate limiting or at least warn users.

### 3. Resource Limits

`run_command` has timeout but no memory/CPU limits. A `while true; do :; done` would hang forever.

### 4. Cancellation Handling

AGENTS.md emphasizes `CancellationError` handling. How does cancellation mid-file-write ensure file isn't corrupted? Use atomic writes (write to temp, rename on completion).

### 5. Multi-Model Tool Choice

In multi-model mode, different models may request conflicting tools (Model A: delete file, Model B: edit file). How is this resolved?

---

## Specific Code Suggestions

### Message Role Enum Extension

```swift
case plan              // Model's execution plan (collapsible in UI)
case checkpoint        // Progress marker in tool chain
case approvalRequest   // Pending user approval
```

These aren't really "roles"—they're message types. Consider a separate `MessageType` enum or use `ContentBlock` types instead to maintain protocol compatibility with providers.

### AgentSettings Codable Issue

`PermissionLevel` is used in `AgentSettings` but if it changes (enum cases added/removed), older persisted settings will fail to decode.

**Recommendation**: Add explicit `CodingKeys` with default values for forward compatibility.

---

## Summary of Actionable Items

| Priority | Item | Action |
|----------|------|--------|
| 🔴 Critical | Shell sandbox bypass | Switch to allowlist-only with AST parsing |
| 🔴 Critical | Path traversal | Canonicalize + validate after symlink resolution |
| 🔴 Critical | Phase 1 safety gap | Move ShellSandbox to Phase 1 |
| 🟡 Medium | Singleton pattern | Use DI via Environment |
| 🟡 Medium | Error taxonomy | Extend AynaError with ToolExecutionError |
| 🟡 Medium | Approval queue races | Document behavior, add timeouts |
| 🟡 Medium | edit_file semantics | Define edge case behavior |
| 🟡 Medium | iOS build in all phases | Add to every exit gate |
| 🟡 Medium | Approval fatigue | Add batch approval option |
| 🟡 Medium | Diff preview | Show diff before edit approval |
| 🟢 Nice-to-have | Audit logging | Log all tool invocations |
| 🟢 Nice-to-have | Undo mechanism | Store backups before file changes |
| 🟢 Nice-to-have | Streaming output | Show shell output incrementally |

---

## Recommended Next Steps

1. **Address critical security issues** before any implementation begins
2. **Update Phase 1** to include ShellSandbox and path validation
3. **Define error taxonomy** in AynaError.swift upfront
4. **Add iOS build check** to all phase exit gates
5. **Create threat model document** outlining attack vectors and mitigations
