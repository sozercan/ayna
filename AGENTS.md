# AGENTS.md

This file provides guidance to AI coding assistants (Claude, GitHub Copilot, etc.) when working with code in this repository.

## Project Overview

ayna is a native macOS ChatGPT client built with SwiftUI for macOS 14+. It supports both OpenAI and Azure OpenAI providers, featuring a conversation management system and streaming responses with a clean, simplified interface.

## Build and Development

### Building the App
```bash
open ayna.xcodeproj
# In Xcode: Select "My Mac" target and press Cmd+R
```

### Requirements
- macOS 14.0+ (Sonoma)
- Xcode 15.0+
- Swift 6.2.1

### Testing
The repository ships with the `aynaTests` unit bundle plus a deterministic `aynaUITests` UI bundle.

- Run the entire suite with:
  ```bash
  xcodebuild -scheme Ayna -destination 'platform=macOS' test
  ```
- Tests live under `aynaTests/` and rely on `InMemoryKeychainStorage` plus `MockURLProtocol` to avoid hitting the real Keychain or network. UI smoke tests live under `aynaUITests/` and launch the app with `--ui-testing` + `AYNA_UI_TESTING=1`, which swaps an in-memory Keychain, temporary store, and mocked OpenAI responses.
- `OpenAIService` now accepts injected `URLSession` and `KeychainStoring` implementations—use those seams when writing additional tests.
- CI enforces the same command via `.github/workflows/tests.yml`; keep the suite deterministic and free of external side effects.

### Build & Test Expectations
- Unless your change is strictly documentation (e.g., Markdown copy edits with zero code or config impact), run both `xcodebuild -scheme Ayna -destination 'platform=macOS' build` and `xcodebuild -scheme Ayna -destination 'platform=macOS' test` before handing work back.
- Fix every build, lint, or test failure you hit; do not skip failures unless the user explicitly waives them for that task.
- Note any deviations (such as intentionally skipping tests for docs-only edits) in your final handoff so the user knows what ran.

### Linting
- Run `swiftlint --strict` from the repo root after every non-trivial change and before handing work back to the user.
- Run `swiftformat .` from the repo root whenever you touch Swift files so formatting stays consistent with the rest of the project.
- Fix every reported warning; only add `// swiftlint:disable` annotations when there is a documented reason in-code.
- Do **not** raise lint thresholds or comment out rules to “get green.” If a rule is noisy, discuss with the user before changing `.swiftlint.yml`.
- When editing large files (e.g., `Views/SettingsView.swift`), keep existing scoped disables intact and avoid introducing new violations elsewhere.

## Architecture

### Core Structure
The codebase follows clean SwiftUI architecture with clear separation:

```
Models → ViewModels → Views → Services
```

**Models** (`Models/Conversation.swift`, `Models/Message.swift`)
- Pure data structures conforming to `Codable` for persistence
- All models use `UUID` for identification
- - `Conversation` contains array of `Message` objects and metadata (title, timestamps, model settings)

**ViewModels** (`ViewModels/ConversationManager.swift`)
- `ConversationManager`: Single source of truth for all conversation state
- - Manages CRUD operations, search, and persistence
- Uses `@Published` properties for reactive UI updates
- Automatically generates conversation titles from first user message
- Persists to `UserDefaults` using JSON encoding

**Views** (`ContentView.swift`, `Views/SidebarView.swift`, `Views/ChatView.swift`, `Views/MessageView.swift`, `Views/SettingsView.swift`)
- `ContentView`: Root view with `NavigationSplitView` (sidebar + detail)
- `SidebarView`: Conversation list with search and context menu actions
- `ChatView`: Clean chat interface with message history, dynamic text editor, and send button
- `MessageView`: Individual message bubble with avatar, copy/like actions
- `SettingsView`: 4-tab settings (General, Model, API, About)

**Services** (`Services/OpenAIService.swift`, `Services/MCPServerManager.swift`, `Services/MCPService.swift`)
- `OpenAIService.shared`: Singleton managing API communication with OpenAI-compatible endpoints
- Supports OpenAI, Azure OpenAI, AIKit with provider-specific authentication
- Tool calling support via `onToolCallRequested` callback
- `MCPServerManager.shared`: Manages MCP server connections, tool discovery, and execution with performance optimizations
- `MCPService`: Individual MCP server communication via stdio
- API keys are retrieved via `KeychainStorage` (global and per-model) and never written to UserDefaults

### State Management Pattern
- `@StateObject` in App entry point for `ConversationManager`
- `.environmentObject()` to inject throughout view hierarchy
- Access via `@EnvironmentObject` in child views
- All state mutations go through `ConversationManager` methods

### Multi-Provider Support
The app supports multiple AI providers via the `AIProvider` enum:

**OpenAI**: Standard OpenAI API
- Endpoint: `https://api.openai.com/v1/chat/completions`
- Auth: `Authorization: Bearer {key}`
- Model specified in request body

**Azure OpenAI**: Enterprise Azure service
- Endpoint: `{endpoint}/openai/deployments/{deployment}/chat/completions?api-version={version}`
- Auth: `api-key: {key}` header
- Model determined by deployment name in URL
- Requires: endpoint URL, deployment name, API version
- Settings auto-trim whitespace from all Azure configuration fields

**AIKit**: Local containerized AI models via Podman
- Endpoint: `http://localhost:8080/v1/chat/completions` (OpenAI-compatible)
- Auth: None required (local endpoint)
- Uses Podman to run container images
- Requires: Podman installed, and GPU access configured (recommended)
- Models pulled from ghcr.io/kaito-project/aikit registry
- Container lifecycle managed through `AIKitService`
- 11 models available: Llama, Mixtral, Phi, Gemma, QwQ, Codestral, GPT-OSS
- Settings UI in `AIKitSettingsView` for pulling/running/stopping containers

When adding new providers, extend `AIProvider` enum and update `OpenAIService.getAPIURL()` and authentication logic.

### MCP (Model Context Protocol) Integration
The app supports tool calling via MCP servers for extended functionality:

**Architecture**:
- `MCPServerManager`: Manages server connections, tool discovery, and execution
- `MCPService`: Handles stdio communication with individual MCP servers
- `MCPModels.swift`: Data models for tools, resources, and tool calls
- Tool calling flow: User message → LLM requests tool → Execute via MCP → LLM processes result → Response

**Supported MCP Servers**:
- `brave-search`: Web search capabilities (requires Brave Search API key)
- `filesystem`: File system access for reading/writing files

**Tool Calling Flow**:
1. User sends message with available tools in context
2. LLM decides to call tool(s) and returns `tool_calls` in response
3. App executes tools via `MCPServerManager.executeTool()`
4. Tool results added as messages with `role: .tool`
5. Automatic continuation sends tool results back to LLM
6. LLM processes results and provides final answer
7. Maximum depth of 5 tool call iterations to prevent loops

**Thread Safety**: All MCP operations use `MainActor.run` for thread-safe dictionary access to services.

## Key Implementation Details

### Streaming Responses
The `OpenAIService.streamResponse()` method:
1. Makes URLSession request expecting Server-Sent Events (SSE)
2. Parses `data: ` prefixed lines
3. Extracts content from `delta.content` in JSON chunks
4. Calls `onChunk()` callback for each piece
5. Completes when receiving `[DONE]` marker

### Conversation Persistence
- Conversations are JSON-encoded via `Codable` and written to an encrypted file (`conversations.enc`) in `Application Support/Ayna`.
- Encryption uses AES-GCM with a 256-bit symmetric key stored in the Keychain.
- Auto-saves after every mutation (create, delete, update, add message, etc.) with a debounce to reduce writes.
- Loads on `ConversationManager.init()`; corrupted data wipes the encrypted file.

### Title Generation
When the first user message is sent and title is still "New Conversation":
- Takes first 50 characters of message content
- Appends "..." if content is longer
- Updates conversation title automatically

### Simplified Interface
The interface has been streamlined to focus on core chat functionality:
- Clean input area with dynamic text editor that auto-expands
- Simple send button with stop capability during generation
- Enter key sends message, Shift+Enter for new line

## Common Development Tasks

### Adding a New AI Model
1. Add model identifier to `OpenAIService.availableModels` array
2. Model will automatically appear in Settings → Model tab picker
3. Ensure model is available for selected provider (OpenAI vs Azure)

### Modifying UI Layout
- Window size constraints set in `aynaApp.swift`: `.frame(minWidth: 900, minHeight: 600)`
- Sidebar minimum width: 260px (set in `NavigationSplitView`)
- Use native SwiftUI controls for consistency
- App uses `.windowStyle(.hiddenTitleBar)` and `.windowToolbarStyle(.unified)` for modern macOS appearance

### Adding Settings
`Views/SettingsView.swift` uses `TabView` with 4 tabs. To add new setting:
1. Add `@Published` property to appropriate manager (`OpenAIService` or `ConversationManager`)
2. Save to `UserDefaults` in property `didSet`
3. Add UI control in relevant settings tab
4. Use `@ObservedObject` binding

## Security Considerations

### API Key Storage
API keys (global and per-model) are stored in the macOS Keychain via `KeychainStorage`. No plaintext copies remain in `UserDefaults`.

### App Sandbox
App uses `App Sandbox` entitlement (`ayna.entitlements`) with:
- Network client access (for API calls)
- User selected file read/write (for future export features)

- All conversations stored locally in an encrypted file under Application Support
- No telemetry or analytics
- Direct API connection, no proxy servers
- Users must provide their own API keys

## Code Style and Patterns

### SwiftUI Patterns Used
- `NavigationSplitView` for sidebar layout (macOS 14+ API)
- `@StateObject`, `@EnvironmentObject`, `@ObservedObject` for state management
- `.sheet()` for modal presentations
- `.contextMenu()` for right-click actions
- `ScrollViewReader` with `.scrollTo()` for auto-scroll to latest message
- `.transaction { transaction in transaction.disablesAnimations = true }` to prevent unwanted animations in `ContentView`

### Debugging and Logging
**IMPORTANT**: Always use comprehensive logging for complex flows and error scenarios.

**Logging Guidelines**:
- Always log through `DiagnosticsLogger.log` so entries land in both the unified logging system and breadcrumb store.
- Keep using emoji prefixes in the `message` string for quick scanning (`🔌`, `✅`, `❌`, `⚠️`, `🔍`, `📋`, `📦`, `🔄`, `🚀`, etc.).
- Include concise metadata (`conversationId`, `toolName`, `server`, etc.) to make log filtering deterministic.

**When to Add Logging**:
1. **Complex Flows**: Any multi-step async operation (e.g., MCP server initialization, tool calling chains)
2. **Error Paths**: Every catch block should log the error with context
3. **State Transitions**: When changing important state (connecting, disconnecting, enabling/disabling)
4. **Data Validation**: When validating or sanitizing user input or loaded data
5. **Background Operations**: All async/Task operations that run in the background
6. **Integration Points**: When communicating with external services (APIs, MCP servers, processes)

**Viewing Debug Logs**:
```bash
# Real-time log streaming
log stream --predicate 'process == "Ayna"' --level debug --style compact

# View recent logs
log show --predicate 'process == "Ayna"' --last 5m --info --debug

# Check crash reports
ls -lt ~/Library/Logs/DiagnosticReports/ | grep Ayna
```

#### Structured Logging & Breadcrumbs
- Prefer `DiagnosticsLogger.log(_:,level:message:metadata:)` for any new logs so entries land in both the unified logging system and `BreadcrumbStore`.
- Pick the closest `DiagnosticsCategory` (see `Diagnostics/DiagnosticsLogger.swift`) and always include lightweight metadata keys (e.g., `conversationId`, `toolName`, `server`). These key/value pairs make `log show` searches deterministic.
- Breadcrumbs persist to `~/Library/Application Support/Ayna/breadcrumbs.json`; read that file or call `BreadcrumbStore.shared.latest()` when you need a quick timeline while debugging.
- When sharing debugging findings with the user, cite the log line you relied on (category + emoji prefix + timestamp if available) so they can correlate with `log show` output.

**Structured Logging Example**:
```swift
do {
  DiagnosticsLogger.log(
    .mcpServerManager,
    level: .default,
    message: "🔌 Attempting MCP connect",
    metadata: ["server": config.name]
  )
  try await service.connect()
  DiagnosticsLogger.log(
    .mcpServerManager,
    level: .info,
    message: "✅ Connected to MCP server",
    metadata: ["server": config.name]
  )
} catch {
  DiagnosticsLogger.log(
    .mcpServerManager,
    level: .error,
    message: "❌ Failed MCP connect: \(error.localizedDescription)",
    metadata: ["server": config.name]
  )
}
```

### Error Handling
- Custom `OpenAIError` enum in `OpenAIService` conforming to `LocalizedError`
- Errors displayed to user in chat view with red text
- Network errors and API errors handled separately
- Missing configuration shows user-friendly messages (e.g., "Please add your API key in Settings")
- **Always log errors with context** before handling them
- Use defensive programming: validate data types, check optionals, handle edge cases

### Naming Conventions
- Views: `{Purpose}View.swift` (e.g., `ChatView`, `SettingsView`)
- Models: Singular nouns (e.g., `Conversation`, `Message`)
- ViewModels: `{Domain}Manager` (e.g., `ConversationManager`)
- Services: `{Provider}Service` (e.g., `OpenAIService`)

## Future Development Notes

### Planned Features (Roadmap)
The README outlines features ready for implementation due to extensible architecture:
- Markdown rendering for messages (replace `Text` views with `AttributedString` or markdown library)
- Export conversations (data already structured, add PDF/Markdown formatters)
- Voice input (add AVFoundation speech recognition)
- Image generation (extend `OpenAIService` for DALL-E endpoints)
- iCloud sync (models already `Codable`, switch from `UserDefaults` to CloudKit)

### Known Limitations
- No actual Keychain implementation despite comments
- No unit tests
- No retry logic for network failures
- No token usage tracking or cost calculation
- Streaming response parsing is simplistic (may fail on complex SSE formats)
- Azure OpenAI API version hardcoded list (may need updates for new Azure releases)

## Project Files Reference

### Configuration Files
- `ayna.xcodeproj/project.pbxproj` - Xcode project settings
- `ayna.entitlements` - App capabilities and sandboxing

### Documentation
- `README.md` - Comprehensive feature list and setup guide
- `AGENTS.md` - This file - development guide for AI assistants
- `LICENSE` - MIT License

### Assets
- `Assets.xcassets/` - App icon and color assets (using SF Symbols for icons)

## Additional Notes

- The app uses SF Symbols for all icons (e.g., "bubble.left", "star", "gear", "message", "sparkles")
- Dark/Light mode support is automatic via system colors
- Keyboard shortcuts defined in `aynaApp.swift` using `.commands` modifier (Cmd+N for new conversation)
- Settings window configured in `aynaApp.swift` using `Settings` scene
- App entry point is `aynaApp` struct in `aynaApp.swift`
