# ADR-0011: Agentic Tool Security, Subprocess Isolation, and MCP Namespacing

**Date**: 2026-11-26  
**Status**: Accepted  
**Context**: Native agentic tools (file I/O, shell, git, web fetch) and external MCP servers execute untrusted model-supplied arguments on the user's machine and require defense-in-depth boundaries.

## Context

Model-driven tool execution introduces path traversal, symlink retargeting (TOCTOU), command injection, runaway subprocesses, SSRF, and confused-deputy tool routing across MCP servers. While [ADR-0006](0006-native-agentic-tools.md) describes the overall agentic tools architecture, concrete security and transport invariants must be preserved across refactors.

## Decision

### 1. Path Validation & TOCTOU Defenses
- `PathValidator` re-resolves protected system paths on every validation and compares case-insensitively on macOS. `/var` (including macOS `FileManager.temporaryDirectory` under `/var/folders`) is intentionally protected and requires approval; `/tmp` is unprotected.
- Approvals bind to canonical resolved targets. File writes re-verify the resolved target immediately before writing; context file reads open descriptors with `O_NOFOLLOW | O_NONBLOCK`; directory checks verify device and inode identity.
- Approval identities are strictly scoped:
  - Pre-reads for `edit_file` use a separate approval identity so "Allow & Remember" on read cannot authorize the edit.
  - Command approvals include the working directory.
  - Task-list approvals are scoped to the conversation ID.
  - `.git` files pointing outside the work tree require separate authorization.

### 2. Defense-in-Depth Shell Sandbox & Process-Group Isolation
- `ShellSandbox` applies a blocklist as defense-in-depth while user approval remains the primary security boundary. Allowlisted read-only commands cannot execute arbitrary code (`env`, `find -exec`, `git -c`, output redirection).
- `CommandSubprocess` runs shell and git commands in their own process group, escalates `SIGTERM` to `SIGKILL` on timeout/cancel, and pins the leader PID until reaping so background descendants are terminated.
- Pipes drain concurrently via `readabilityHandler` (per Apple TN2050) without waiting for descendant EOF to avoid deadlocks.
- `GitContextService` disables hooks, credential helpers, fsmonitor, submodules, and filter drivers via `GIT_CONFIG_*` environment variables (rather than `-c`, which splits `=` in driver names) and sets `GIT_OPTIONAL_LOCKS=0`.

### 3. Web Fetch Ownership & SSRF Defenses
- `web_fetch` is owned exclusively by `WebFetchService` (not duplicated in `BuiltinToolService`).
- Because `URLSession` lacks a pre-connect IP-pinning hook, `WebFetchService` combines preflight DNS resolution, proxy rejection, redirect blocking (preventing 302 redirects to link-local/metadata IPs like `169.254.169.254`), and post-transaction endpoint verification.
- DNS resolution uses an unstructured one-shot deadline race that does not await the losing task during teardown because `getaddrinfo` can remain blocked after cancellation.
- HTML entity decoding decodes `&amp;` last so double-encoded entities (`&amp;lt;`) stay literal (`&lt;`).

### 4. MCP Stdio Transport & Session-Sticky Tool Aliasing
- `MCPService` sets `F_SETNOSIGPIPE` on the subprocess stdin pipe so writing to a wedged/closed transport returns `EPIPE` instead of terminating the app with `SIGPIPE`.
- Ayna advertises empty MCP client capabilities because it does not serve roots or sampling.
- Incoming JSON-RPC messages carrying a `method` field are server-initiated requests/notifications and must never resolve pending client requests with colliding numeric IDs.
- Built-in tool names are reserved; colliding MCP tools are namespaced as `<server>__<tool>`. Once an alias is bound to a `(server, tool)` pair, it is never reassigned during the session so a call against an older tool list either reaches the same tool or fails—never a different server (`MCPModels`, `MCPServerManager`).

### 5. Platform-Tiered Tool Depth & Deduplication
- `maxToolCallDepth` is tiered by platform resource constraints: macOS = 25, iOS = 10, watchOS = 5.
- When a provider omits tool-call IDs, `WatchChatViewModel` generates round-local synthetic IDs keyed by canonical tool payload to prevent duplicate execution within a round.

## Consequences

### Positive
- Prevents symlink retargeting, confused-deputy MCP routing, pipe deadlocks, `SIGPIPE` crashes, and SSRF redirects.
- Keeps security invariants documented independently of source-file comments.

### Negative
- Full IP pinning for `web_fetch` remains deferred until a custom TLS transport is warranted.

### Neutral
- Complements [ADR-0006](0006-native-agentic-tools.md) and [ADR-0007](0007-revisioned-watch-sync.md).
