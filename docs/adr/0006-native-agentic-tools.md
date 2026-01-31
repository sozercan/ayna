# ADR-0006: Native Agentic Tools Architecture

**Date**: 2025-01-30
**Status**: Proposed (Revised after review)
**Context**: Adding Claude Code-like agentic capabilities with built-in tools for file operations and shell execution
**Review**: See [0006-native-agentic-tools-review.md](0006-native-agentic-tools-review.md) for feedback incorporated below

## Context

Users want Ayna to provide agentic capabilities similar to Claude Code - the ability for AI models to read/write files, execute commands, and perform multi-step tasks autonomously.

### Current State

Ayna already has a solid foundation for tool use:

**Existing Capabilities:**
- **MCP (Model Context Protocol)** - macOS only, supports external MCP servers via stdio
- **Web Search (Tavily)** - Available on all platforms
- **Tool Call Chaining** - Up to 10 sequential tool calls per request
- **Multi-model Support** - Compare responses, defer tool execution until selection
- **Tool UI** - Status chips, tool summary view, content blocks for tool output

**Current Limitations:**
1. MCP is macOS-only (sandboxing prevents iOS/watchOS)
2. No built-in file/code manipulation tools
3. No permission/approval system for dangerous operations
4. No task/progress tracking for multi-step operations
5. No project/workspace context awareness
6. Limited agentic loop (fixed 10-step limit, no planning mode)

### Approaches Considered

1. **Copilot SDK Integration**: Use GitHub's Copilot CLI in server mode via JSON-RPC
2. **Native Swift Tools**: Build tool implementations directly in Swift

The Copilot SDK approach would provide battle-tested agentic features quickly but locks users into the Copilot ecosystem. Native tools work with all providers (OpenAI, Anthropic, local models) and give full control over security.

**Decision**: Implement native Swift tools. Copilot SDK can be added later as an optional provider.

## Decision

### Architecture Overview

```
User sends message → AI requests tool → PermissionService checks →
  → Auto-approve (read-only) → BuiltinToolService executes → Return result
  → Requires approval → Show inline UI → User approves → Execute → Return result
  → Denied → Return error to model
```

### 1. BuiltinToolService

Central service for all native tool operations. **Uses dependency injection via SwiftUI Environment** (per CLAUDE.md guidance — no static singletons for @MainActor types):

```swift
@Observable @MainActor
final class BuiltinToolService {
    private let permissionService: PermissionService
    private let shellSandbox: ShellSandbox
    private let projectRoot: URL?

    init(permissionService: PermissionService, shellSandbox: ShellSandbox, projectRoot: URL? = nil) {
        self.permissionService = permissionService
        self.shellSandbox = shellSandbox
        self.projectRoot = projectRoot
    }

    // File operations
    func readFile(path: String) async throws -> String
    func writeFile(path: String, content: String) async throws
    func editFile(path: String, oldText: String, newText: String) async throws
    func listDirectory(path: String) async throws -> [FileEntry]
    func searchFiles(pattern: String, path: String) async throws -> [SearchResult]

    // Shell execution
    func runCommand(command: String, workingDirectory: String?) async throws -> CommandResult

    // Tool definitions for AI (OpenAI function format)
    func allToolDefinitions() -> [[String: Any]]
}

// Inject via Environment in App root:
// .environment(builtinToolService)
```

### 2. PermissionService

Manages approval workflow for dangerous operations:

```swift
enum PermissionLevel: String, Codable, CaseIterable {
    case automatic        // Read-only operations, web search
    case askOnce          // Approve once per session (file writes in project directory)
    case askAlways        // Always confirm (shell commands, writes outside project)
    case denied           // Never allow (destructive commands, sensitive paths)

    // Forward-compatible decoding (new cases default to askAlways)
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = PermissionLevel(rawValue: value) ?? .askAlways
    }
}

struct PendingApproval: Identifiable {
    let id: UUID
    let toolName: String
    let description: String
    let details: String  // File path or command
    let diffPreview: String?  // For edit operations, show what will change
    let createdAt: Date
    let onApprove: () async -> Void
    let onDeny: () -> Void
}

@Observable @MainActor
final class PermissionService {
    var pendingApprovals: [PendingApproval] = []

    // Approval queue behavior:
    // - Concurrent approvals: Processed in order, UI shows queue count
    // - User closes conversation: Pending approvals auto-denied
    // - App terminates: Pending approvals lost (not persisted)
    // - Timeout: Auto-deny after 5 minutes (configurable)
    var approvalTimeoutSeconds: Int = 300

    func checkPermission(tool: String, details: [String: Any]) -> PermissionLevel
    func requestApproval(_ approval: PendingApproval)
    func denyAllPending(reason: String)  // Called on conversation close
    func expireStaleApprovals()  // Called periodically
}
```

### 3. ShellSandbox

Validates and restricts shell command execution.

**Security Model Note**: The blocklist is a *defense-in-depth* measure, not the primary security boundary. The actual security comes from user approval for any dangerous operation. The blocklist helps models avoid obviously dangerous commands without user intervention. Sophisticated bypass attempts (scripts invoking sudo, encoded payloads) are stopped at the approval layer.

**Why not AST parsing?** Shell parsing is notoriously complex (bash, zsh, POSIX sh variations), and even perfect parsing can't detect what a script *does* internally. The cost-benefit doesn't favor this complexity for our threat model (helpful AI, not malicious attacker).

```swift
struct ShellSandbox {
    // Default allowed commands (execute without approval)
    static let defaultAllowed = ["ls", "cat", "grep", "find", "git", "npm", "swift", "xcodebuild", "echo", "pwd", "which", "env"]

    // Always blocked (denied even with approval attempt)
    static let defaultBlocked = [
        "sudo", "doas", "pkexec",           // Privilege escalation
        "rm -rf /", "rm -rf ~", "rm -rf .",  // Destructive
        "chmod 777", "chmod -R 777",         // Unsafe permissions
        "> /dev/", "dd if=", "mkfs",         // Device/filesystem danger
        ":(){:|:&};:",                       // Fork bombs
    ]

    // Command chaining detection: split on ; && || | and validate each part
    func validate(command: String) -> ValidationResult
    func isPathAllowed(_ path: String, projectRoot: URL?) -> Bool

    // Path canonicalization (addresses symlink attacks)
    func canonicalizePath(_ path: String, projectRoot: URL?) -> URL?
}

enum ValidationResult {
    case allowed           // In allowlist, can execute
    case requiresApproval  // Not in allowlist, needs user approval
    case blocked(reason: String)  // In blocklist, always denied
}
```

**Command Chaining**: The sandbox splits commands on `;`, `&&`, `||`, and `|` to validate each component. `git status; rm -rf /` fails because `rm -rf /` is blocked.

### 4. Path Security

All file operations validate paths to prevent traversal attacks:

```swift
struct PathValidator {
    let projectRoot: URL?
    let protectedPaths: [String]

    /// Validates a path is safe to access.
    /// 1. Expands ~ and environment variables
    /// 2. Resolves symlinks (prevents symlink-to-sensitive-file attacks)
    /// 3. Canonicalizes path (removes . and ..)
    /// 4. Checks against protected paths
    /// 5. Validates within project root (if configured)
    func validate(_ path: String, operation: FileOperation) throws -> URL

    enum FileOperation {
        case read    // Less restrictive
        case write   // Must be in project or explicitly approved
        case execute // Same as write
    }
}

// Protected paths (default, expanded from review feedback):
static let defaultProtectedPaths = [
    "~/.ssh",
    "~/.aws",
    "~/.gnupg", "~/.gpg",
    "~/.config",           // Contains secrets for many CLI tools
    "~/.kube",             // Kubernetes credentials
    "~/.docker",           // Docker credentials
    "~/Library/Keychains", // macOS keychain
    "/etc",
    "/var",
    "/System",
    "/Library",
]

// Always check for .env files in any directory
static let sensitiveFilenames = [".env", ".env.local", ".env.production", "credentials.json", "secrets.yaml"]

// Git credential files
static let gitSensitiveFiles = [".git/config", ".gitconfig"]
```

**Symlink Attack Prevention**: `read_file("link.txt")` where `link.txt → ~/.ssh/id_rsa` is caught by resolving the symlink first, then validating the *resolved* path against protected paths.

### 5. Inline Approval UI

Approval requests appear as message bubbles in the chat. **Includes diff preview for edit operations** (per review feedback):

```swift
struct ApprovalRequestView: View {
    let approval: PendingApproval
    @State private var showDiff = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(approval.toolName, systemImage: "exclamationmark.shield")
                .font(.headline)
            Text(approval.description)
            Text(approval.details)
                .font(.caption)
                .monospaced()

            // Diff preview for edit operations
            if let diff = approval.diffPreview {
                DisclosureGroup("Show changes", isExpanded: $showDiff) {
                    DiffView(diff: diff)
                        .frame(maxHeight: 200)
                }
            }

            HStack {
                Button("Deny") { approval.onDeny() }
                    .buttonStyle(.bordered)
                Button("Allow") { Task { await approval.onApprove() } }
                    .buttonStyle(.borderedProminent)

                // Batch approval option (addresses approval fatigue)
                if approval.toolName == "edit_file" || approval.toolName == "write_file" {
                    Button("Allow All File Ops") { Task { await approveAllFileOperations() } }
                        .buttonStyle(.bordered)
                }
            }
        }
    }
}
```

**Approval Fatigue Mitigation**: Added "Allow All File Ops" button for batch approval when multiple file operations are queued. Shows count of pending operations.

### 6. Tool Definitions

Tools registered following the same pattern as TavilyService:

| Tool | Description | Permission |
|------|-------------|------------|
| `read_file` | Read file contents | automatic |
| `write_file` | Create/overwrite file | requiresApproval |
| `edit_file` | Search/replace edit | requiresApproval |
| `list_directory` | List files in directory | automatic |
| `search_files` | Grep-like search | automatic |
| `run_command` | Execute shell command | requiresApproval |

#### `edit_file` Semantics (per review feedback)

```swift
/// Performs search-and-replace edit on a file.
/// - Parameters:
///   - path: File path (validated via PathValidator)
///   - oldText: Text to find. Must match EXACTLY (byte-for-byte, including whitespace)
///   - newText: Replacement text
/// - Returns: ToolResult with success/failure
/// - Throws: ToolExecutionError
///
/// Behavior:
/// - `oldText` must appear exactly ONCE in the file. Multiple matches = error (ambiguous edit)
/// - Encoding: UTF-8 only. Binary files rejected with error.
/// - Empty `oldText`: Rejected (use write_file for new content)
/// - Empty `newText`: Valid (deletes the matched text)
/// - `oldText == newText`: No-op, returns success
func editFile(path: String, oldText: String, newText: String) async throws -> ToolResult
```

### 7. Error Taxonomy

Extend `AynaError.swift` with structured tool errors (per review feedback). Models need to distinguish error types to recover gracefully:

```swift
enum ToolExecutionError: Error, LocalizedError {
    // Permission errors (user declined or policy blocked)
    case permissionDenied(tool: String, reason: String)
    case sandboxBlocked(command: String, reason: String)

    // Execution errors (tool ran but failed)
    case fileNotFound(path: String)
    case fileNotReadable(path: String, underlying: Error)
    case fileNotWritable(path: String, underlying: Error)
    case commandFailed(command: String, exitCode: Int, stderr: String)
    case commandTimeout(command: String, timeoutSeconds: Int)

    // Validation errors (bad input)
    case invalidPath(path: String, reason: String)
    case editAmbiguous(path: String, matchCount: Int)  // oldText matched multiple times
    case binaryFileUnsupported(path: String)

    // System errors
    case resourceLimitExceeded(resource: String, limit: String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied(let tool, let reason):
            return "Permission denied for \(tool): \(reason)"
        // ... etc
        }
    }

    /// Structured error for model consumption
    var modelFacingDescription: String {
        // Returns a clear, actionable description the model can use to recover
    }
}
```

### 8. Integration Points

1. Register tools in `AIService.sendMessage()` alongside MCP and Tavily
2. Handle `onToolCallRequested` callback for built-in tools
3. Route through PermissionService before execution
4. Increase tool chain depth from 10 to 25 for complex tasks

### 9. Agentic Loop Enhancements

Improve multi-step execution capabilities:

- **Dynamic Depth Limit** - Increase from 10 to configurable (default 25)
- **Planning Mode** - Allow model to outline steps before execution
- **Checkpoint System** - Save state at each tool call for recovery
- **Cancellation Improvements** - Graceful stop with rollback option

**New Content Block Types** (using `ContentBlock` instead of message roles, per review feedback — maintains provider protocol compatibility):

```swift
// Extend ContentBlock instead of MessageRole to maintain API compatibility
enum ContentBlockType: String, Codable {
    case text, image, toolUse, toolResult
    // New agentic types:
    case plan              // Model's execution plan (collapsible in UI)
    case checkpoint        // Progress marker in tool chain
    case approvalRequest   // Pending user approval
    case progress          // Streaming output from long-running commands
}
```

### 10. Task Management

Add todo/task tracking within conversations:

```swift
struct ConversationTask: Identifiable, Codable {
    let id: UUID
    var content: String
    var status: TaskStatus  // pending, in_progress, completed
    var createdAt: Date
    var completedAt: Date?
}

enum TaskStatus: String, Codable {
    case pending
    case inProgress
    case completed
}
```

**Features:**
- Model can create/update tasks via `update_tasks` tool
- Task list displayed in conversation sidebar
- Progress bar for multi-step operations
- Persist tasks with conversation

### 11. Project Context Awareness

Enable workspace/project understanding:

1. **Project Detection** - Auto-detect project type (Swift, Node, Python, etc.)
2. **Context Files** - Load CLAUDE.md, .cursorrules, AGENTS.md automatically
3. **File Tree Context** - Provide project structure to model
4. **Git Integration** - Current branch, recent commits, staged changes

**Settings:**
- Project root path selection
- Files to include in context
- Auto-load project rules toggle
- Per-conversation permission overrides

### 12. Git Integration

Provide repository awareness to models:

```swift
struct GitContext: Codable {
    let currentBranch: String
    let recentCommits: [GitCommit]  // Last 5-10 commits
    let stagedChanges: [String]     // File paths
    let modifiedFiles: [String]     // Unstaged changes
    let isClean: Bool
}

struct GitCommit: Codable {
    let hash: String
    let message: String
    let author: String
    let date: Date
}
```

### 13. Agents Settings View

New settings tab for configuring agentic capabilities:

#### Permission Levels Section

Default permission levels for each tool type:

| Tool | Default Permission | User Configurable |
|------|-------------------|-------------------|
| `read_file` | Automatic | Yes |
| `list_directory` | Automatic | Yes |
| `search_files` | Automatic | Yes |
| `write_file` | Ask Once | Yes |
| `edit_file` | Ask Once | Yes |
| `run_command` | Ask Always | Yes |

- Master toggle: "Enable agentic tools" (on/off)

#### Shell Sandbox Section

- **Allowed commands list** — Commands that run without approval (default: `git`, `ls`, `cat`, `grep`, `find`, `npm`, `swift`, `xcodebuild`)
- **Blocked patterns list** — Commands that are always denied (default: `sudo`, `rm -rf /`, `chmod 777`, `> /dev/`)
- Toggle: "Allow commands outside allowed list" (with approval)
- Working directory restriction picker: Project-only vs. Anywhere

#### Project Context Section

- **Project root path** — Folder picker for workspace root
- Toggle: "Auto-detect project type" (Swift, Node, Python, etc.)
- Toggle: "Auto-load context files" (CLAUDE.md, .cursorrules, AGENTS.md)
- Toggle: "Include file tree in system prompt"
- **Exclude patterns** — Text field for glob patterns to exclude (e.g., `node_modules`, `.git`, `build`)

#### Git Integration Section

- Toggle: "Include git context in prompts"
- Checkboxes for context to include:
  - [ ] Current branch name
  - [ ] Recent commits
  - [ ] Staged changes
  - [ ] Unstaged changes
- Picker: "Recent commits count" (5 / 10 / 20)

#### Execution Limits Section

- **Tool chain depth** — Stepper (default: 25, range: 5–50)
- **Timeout per tool** — Stepper in seconds (default: 30, range: 10–300)
- Toggle: "Enable planning mode" (model outlines steps before execution)
- Toggle: "Enable checkpoints" (save state at each tool call for recovery)

#### Session Approvals Section

- List view of current session's "approved once" permissions
- Button: "Clear All Session Approvals"
- Toggle: "Remember approvals across sessions" (persistent vs. session-only)

#### Safety Section

- **Protected paths** — List editor for paths that always require approval (expanded defaults per review: `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.config`, `~/.kube`, `~/.docker`, `~/Library/Keychains`, `/etc`, `/var`, `/System`)
- **Sensitive filenames** — Always require approval: `.env`, `.env.local`, `credentials.json`, `secrets.yaml`
- Toggle: "Require approval for writes outside project directory"
- Toggle: "Show command preview before execution"

```swift
// Settings data model
struct AgentSettings: Codable {
    var enabled: Bool = true

    // Permission levels
    var readFilePermission: PermissionLevel = .automatic
    var writeFilePermission: PermissionLevel = .askOnce
    var editFilePermission: PermissionLevel = .askOnce
    var runCommandPermission: PermissionLevel = .askAlways

    // Shell sandbox
    var allowedCommands: [String] = ShellSandbox.defaultAllowed
    var blockedPatterns: [String] = ShellSandbox.defaultBlocked
    var allowUnlistedCommands: Bool = true
    var restrictToProjectDirectory: Bool = true

    // Project context
    var projectRootPath: String?
    var autoDetectProjectType: Bool = true
    var autoLoadContextFiles: Bool = true
    var includeFileTreeInPrompt: Bool = true
    var excludePatterns: [String] = ["node_modules", ".git", "build", "DerivedData"]

    // Git integration
    var includeGitContext: Bool = true
    var includeCurrentBranch: Bool = true
    var includeRecentCommits: Bool = true
    var includeStagedChanges: Bool = true
    var includeUnstagedChanges: Bool = true
    var recentCommitsCount: Int = 10

    // Execution limits
    var toolChainDepth: Int = 25
    var toolTimeoutSeconds: Int = 30
    var enablePlanningMode: Bool = false
    var enableCheckpoints: Bool = true

    // Session management
    var persistApprovalsAcrossSessions: Bool = false

    // Safety (expanded per review feedback)
    var protectedPaths: [String] = [
        "~/.ssh", "~/.aws", "~/.gnupg", "~/.gpg",
        "~/.config", "~/.kube", "~/.docker",
        "~/Library/Keychains",
        "/etc", "/var", "/System", "/Library"
    ]
    var requireApprovalOutsideProject: Bool = true
    var showCommandPreview: Bool = true
}
```

## Consequences

### Positive

1. **Provider-agnostic**: Works with OpenAI, Anthropic, local models - any provider supporting function calling
2. **Full control**: Complete control over sandboxing, permissions, and security
3. **No dependencies**: No external CLI, subscriptions, or network requirements for tool execution
4. **Consistent UX**: Inline approval matches existing chat UI patterns
5. **Extensible**: Easy to add new tools following the established pattern

### Negative

1. **Development effort**: Must implement and maintain tool logic ourselves
2. **Security responsibility**: We own the sandboxing and permission logic
3. **Feature parity**: May lag behind dedicated agentic tools (Copilot, Claude Code)

### Neutral

1. **macOS only**: File/shell operations restricted to macOS (same as MCP)
2. **Tool chain depth**: Configurable but defaults to 25 steps
3. **Copilot optional**: Can still add Copilot SDK as a separate provider later

## Implementation Phases

> **Note**: Per review feedback, ShellSandbox is moved to Phase 1 to ensure safety is never deployed without sandboxing. Also, **every phase now includes iOS build verification** to catch cross-platform issues early.

### Phase 1: Core Tool Infrastructure + Safety (combined per review)

| Deliverable | Exit Criteria |
|-------------|---------------|
| `BuiltinToolService.swift` | All 6 tools implemented (read, write, edit, list, search, run) |
| `PermissionService.swift` | Permission check and approval queue working |
| `ShellSandbox.swift` | Blocks `sudo`, `rm -rf /`, allows `git`, `ls` (**moved from Phase 2**) |
| `PathValidator.swift` | Path canonicalization with symlink resolution |
| `ApprovalRequestView.swift` | Inline UI renders in chat with diff preview |
| Tool chain depth increased | `maxToolCallDepth = 25` in MacChatView |

**Exit Gate:**
```bash
# All unit tests pass
xcodebuild -scheme Ayna -destination 'platform=macOS' test -only-testing:aynaTests/BuiltinToolServiceTests
xcodebuild -scheme Ayna -destination 'platform=macOS' test -only-testing:aynaTests/ShellSandboxTests

# macOS builds successfully
xcodebuild -scheme Ayna -destination 'platform=macOS' build

# iOS builds successfully (Core/ code must compile even if tools are disabled)
xcodebuild -scheme Ayna-iOS -destination 'platform=iOS Simulator,name=iPhone 17' build
```

**Manual Verification:**
- [ ] Send "read the file /etc/hosts" → returns file contents (no approval needed)
- [ ] Send "create a file test.txt with hello" → approval prompt appears
- [ ] Approve → file created, AI confirms success
- [ ] Send "run sudo ls" → blocked, error returned to model
- [ ] Send "run rm -rf /" → blocked, error returned to model
- [ ] Attempt symlink attack → blocked by path validation

---

### Phase 2: Permission Persistence & Batch Approval

| Deliverable | Exit Criteria |
|-------------|---------------|
| Permission persistence | `askOnce` approvals survive within session |
| Batch approval UI | "Allow All File Ops" button works |
| Approval timeout | Stale approvals auto-denied after 5 min |
| `ToolExecutionError` enum | Structured errors in AynaError.swift |

**Exit Gate:**
```bash
# Unit tests pass
xcodebuild -scheme Ayna -destination 'platform=macOS' test -only-testing:aynaTests/PermissionServiceTests

# Both platforms build
xcodebuild -scheme Ayna -destination 'platform=macOS' build
xcodebuild -scheme Ayna-iOS -destination 'platform=iOS Simulator,name=iPhone 17' build
```

**Manual Verification:**
- [ ] Approve write to project dir → second write to same dir auto-approved
- [ ] Queue 5 file operations → "Allow All" approves all at once
- [ ] Wait 5+ minutes on approval → auto-denied

---

### Phase 3: Enhanced UX

| Deliverable | Exit Criteria |
|-------------|---------------|
| `ConversationTask.swift` | Task model persists with conversation |
| `TaskListView.swift` | Tasks visible in sidebar |
| `update_tasks` tool | Model can create/update tasks |
| `ProjectContextService.swift` | Detects project type, loads CLAUDE.md |
| `AgentsSettingsSection.swift` | Settings tab renders, toggles persist |
| `AgentSettings.swift` | Settings model loads/saves correctly |
| Audit logging | All tool invocations logged via DiagnosticsLogger |

**Exit Gate:**
```bash
# Full test suite passes
xcodebuild -scheme Ayna -destination 'platform=macOS' test -only-testing:aynaTests

# Both platforms build
xcodebuild -scheme Ayna -destination 'platform=macOS' build
xcodebuild -scheme Ayna-iOS -destination 'platform=iOS Simulator,name=iPhone 17' build
```

**Manual Verification:**
- [ ] Send "create a task list for refactoring X" → tasks appear in sidebar
- [ ] Tasks persist after app restart
- [ ] Open project with CLAUDE.md → context auto-loaded in system prompt
- [ ] Project type detected (shown in UI or logs)
- [ ] Agents tab appears in Settings window
- [ ] Permission toggles persist after app restart
- [ ] Disabling agents master toggle prevents tool execution
- [ ] Check logs: all tool invocations recorded

---

### Phase 4: Git Integration & Polish

| Deliverable | Exit Criteria |
|-------------|---------------|
| `GitContextService.swift` | Returns branch, commits, status |
| Git context in system prompt | Model aware of current branch |
| Checkpoint system | State saved at each tool call |
| Background execution | Long commands don't block UI |
| Streaming output | stdout/stderr shown incrementally for long commands |
| Atomic file writes | Write to temp + rename prevents corruption on cancel |
| File backup | Store original content before modification for undo |

**Exit Gate:**
```bash
# All tests pass, both platforms build
xcodebuild -scheme Ayna -destination 'platform=macOS' test
xcodebuild -scheme Ayna-iOS -destination 'platform=iOS Simulator,name=iPhone 17' build
```

**Manual Verification:**
- [ ] Send "what branch am I on?" → correct branch returned
- [ ] Send "show recent commits" → last 5 commits listed
- [ ] Cancel mid-task → state recoverable
- [ ] Run `xcodebuild` → UI remains responsive, output streams live
- [ ] Cancel during file write → file not corrupted (atomic write)
- [ ] After file edit → can view original in logs/backup

## Additional Considerations (from review)

These items are acknowledged but **deferred to future iterations** or handled differently:

### Rate Limiting

The review asks: *"What prevents a rogue model from requesting 1000 file reads in a loop?"*

**Response**: The tool chain depth limit (default 25, max 50) inherently rate-limits within a single request. For sustained abuse across multiple requests, we rely on the provider's rate limiting. A local rate limiter (e.g., 100 tool calls per conversation per 5 minutes) could be added if abuse patterns emerge.

**Status**: Defer to Phase 5 if needed.

### Resource Limits (Memory/CPU)

The review notes `while true; do :; done` could hang forever.

**Response**: The `toolTimeoutSeconds` setting (default 30s) handles infinite loops. For memory, macOS process limits apply naturally. We could add explicit memory monitoring, but this adds complexity for an edge case.

**Status**: Timeout is sufficient for MVP. Memory limits deferred.

### Multi-Model Tool Conflicts

The review asks: *"Model A deletes file, Model B edits file — how resolved?"*

**Response**: In multi-model mode, tool execution is already deferred until the user selects a response. Only the selected model's tools execute. Parallel tool execution from multiple models is explicitly not supported.

**Status**: Already handled by existing architecture.

### Undo/Rollback Mechanism

The review suggests storing backups before modification.

**Response**: Added to Phase 4: atomic file writes and backup storage. An explicit `undo_last_operation` tool adds complexity; recommend logging original content for manual recovery instead.

**Status**: Partial implementation in Phase 4. Full undo tool deferred.

### `sandbox-exec` / True OS Sandboxing

The review suggests using `sandbox-exec` for true sandboxing.

**Response**: `sandbox-exec` is deprecated and complex to configure correctly. The approval-based security model is more appropriate for a chat app where the user is present. For headless/automated use cases, a container-based approach would be better than `sandbox-exec`.

**Status**: Not adopting. Current approach is suitable for interactive use.

## Files to Create

| File | Purpose |
|------|---------|
| `Core/Services/BuiltinToolService.swift` | File ops, shell execution, tool definitions |
| `Core/Services/PathValidator.swift` | Path canonicalization and security validation |
| `Core/Services/PermissionService.swift` | Permission checks, approval queue |
| `Core/Services/ShellSandbox.swift` | Command validation, path restrictions |
| `Core/Services/ProjectContextService.swift` | Project detection, CLAUDE.md loading |
| `Core/Services/GitContextService.swift` | Git integration (branch, commits, status) |
| `Core/Models/ConversationTask.swift` | Task tracking data model |
| `Views/macOS/ApprovalRequestView.swift` | Inline approval UI component |
| `Views/macOS/TaskListView.swift` | Task sidebar component |
| `Views/macOS/Settings/AgentsSettingsSection.swift` | Agents configuration UI |
| `Core/Models/AgentSettings.swift` | Settings data model |
| `Tests/aynaTests/BuiltinToolServiceTests.swift` | Unit tests for tools |
| `Tests/aynaTests/PermissionServiceTests.swift` | Unit tests for permissions |
| `Tests/aynaTests/ShellSandboxTests.swift` | Unit tests for sandboxing |

## Files to Modify

| File | Changes |
|------|---------|
| `Core/Services/AIService.swift` | Register built-in tools, route tool calls, increase depth to 25 |
| `Core/Services/OpenAIRequestBuilder.swift` | Include BuiltinToolService definitions |
| `Core/Models/ContentBlock.swift` | Add `.plan`, `.checkpoint`, `.approvalRequest`, `.progress` block types |
| `Core/Models/Conversation.swift` | Add `tasks: [ConversationTask]` property |
| `Core/Models/AynaError.swift` | Add `ToolExecutionError` enum |
| `Views/macOS/MacChatView.swift` | Inline approval UI, task list, handle pending approvals |
| `Views/macOS/MCPToolSummaryView.swift` | Show built-in tools status |
| `Views/macOS/MacSettingsView.swift` | Add `.agents` tab to SettingsTab enum and TabView |
| `Core/Utilities/SettingsNavigator.swift` | Add `case agents` to SettingsTab enum |

## Verification Plan

### Unit Tests

```bash
# Test BuiltinToolService
xcodebuild -scheme Ayna -destination 'platform=macOS' test -only-testing:aynaTests/BuiltinToolServiceTests

# Test PermissionService
xcodebuild -scheme Ayna -destination 'platform=macOS' test -only-testing:aynaTests/PermissionServiceTests

# Test ShellSandbox
xcodebuild -scheme Ayna -destination 'platform=macOS' test -only-testing:aynaTests/ShellSandboxTests
```

### Integration Tests

- Test tool chaining: read → edit → verify content changed
- Test permission flow: request → approve → execute → result
- Test denial flow: request → deny → error returned to model
- Test sandbox: blocked command returns error without execution

### Manual Testing Checklist

1. **File Operations**
   - [ ] Read an existing file via chat
   - [ ] Create a new file via chat (verify approval prompt)
   - [ ] Edit a file with search/replace
   - [ ] List directory contents
   - [ ] Search for pattern across files

2. **Shell Execution**
   - [ ] Run `git status` (should work)
   - [ ] Run `xcodebuild build` (should prompt approval)
   - [ ] Attempt `sudo` command (should be blocked)
   - [ ] Attempt `rm -rf /` (should be blocked)

3. **Permission Flow**
   - [ ] Approve a write operation
   - [ ] Deny a write operation
   - [ ] Verify "approve once" persists for session
   - [ ] Verify per-conversation overrides work

4. **Agents Settings**
   - [ ] Toggle "Enable agentic tools" disables all tool execution
   - [ ] Change permission level for `run_command` to "Ask Always"
   - [ ] Add custom command to allowed list
   - [ ] Set project root path via folder picker
   - [ ] Exclude pattern hides files from context
   - [ ] Clear session approvals works
   - [ ] Tool chain depth change takes effect

5. **Platform Builds**
   ```bash
   # macOS (should include all tools)
   xcodebuild -scheme Ayna -destination 'platform=macOS' build

   # iOS (should compile, tools hidden/disabled)
   xcodebuild -scheme Ayna-iOS -destination 'platform=iOS Simulator,name=iPhone 17' build
   ```

## References

- [Core/Services/MCPService.swift](../../Core/Services/MCPService.swift) - Existing MCP tool pattern
- [Core/Services/TavilyService.swift](../../Core/Services/TavilyService.swift) - Existing tool registration pattern
- [Views/macOS/MacChatView.swift](../../Views/macOS/MacChatView.swift) - Tool call handling in chat

---

## Review Response Summary

| Review Item | Status | Resolution |
|-------------|--------|------------|
| 🔴 Shell sandbox bypass | **Addressed** | Added command chaining detection, documented that approval is primary security; blocklist is defense-in-depth |
| 🔴 Path traversal | **Addressed** | Added `PathValidator` with symlink resolution and canonicalization |
| 🔴 Phase 1 ships without safety | **Addressed** | Moved ShellSandbox to Phase 1 |
| 🟡 @MainActor singleton | **Addressed** | Changed to Environment-based DI |
| 🟡 Protected paths incomplete | **Addressed** | Expanded to include `~/.config`, `~/.kube`, `~/.docker`, etc. |
| 🟡 Error taxonomy missing | **Addressed** | Added `ToolExecutionError` enum |
| 🟡 Approval queue races | **Addressed** | Documented behavior, added timeout policy |
| 🟡 edit_file semantics | **Addressed** | Defined exact-match, single-occurrence, UTF-8 only |
| 🟡 iOS build in all phases | **Addressed** | Added iOS build check to every phase exit gate |
| 🟡 Approval fatigue | **Addressed** | Added batch approval "Allow All File Ops" button |
| 🟡 Diff preview missing | **Addressed** | Added to ApprovalRequestView |
| 🟡 Message role enum | **Addressed** | Changed to ContentBlock types for protocol compatibility |
| 🟡 AgentSettings Codable | **Addressed** | Added forward-compatible decoding with defaults |
| 🟢 Audit logging | **Addressed** | Added to Phase 3 deliverables |
| 🟢 Undo mechanism | **Partial** | Added atomic writes + backup; explicit undo tool deferred |
| 🟢 Streaming output | **Addressed** | Added to Phase 4 deliverables |
| Rate limiting | **Deferred** | Tool chain depth limit sufficient for MVP |
| Resource limits | **Deferred** | Timeout handles infinite loops; memory limits deferred |
| `sandbox-exec` | **Not adopting** | Deprecated, approval-based model preferred for interactive use |
| Multi-model conflicts | **Already handled** | Existing architecture defers execution until model selected |
