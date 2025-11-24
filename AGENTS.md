# AGENTS.md

This file provides guidance to AI coding assistants (Claude, GitHub Copilot, etc.) when working with code in this repository.

## Project Overview

ayna is a native macOS and iOS ChatGPT client built with SwiftUI. It supports OpenAI-compatible endpoints, Apple Intelligence, and AIKit with a conversation management system and streaming responses in a clean interface.

## Build and Development

### Cross-Platform Compatibility
**CRITICAL**: This project targets both macOS and iOS.
- Shared code (Models, ViewModels, Services, Utilities) must compile for **both** platforms.
- Avoid platform-specific imports (e.g., `AppKit`, `UIKit`) in shared files unless wrapped in `#if os(macOS)` or `#if os(iOS)`.
- When modifying shared logic, **always** verify the build for both platforms to ensure no regressions.
- Use `xcodebuild` to verify both targets before finishing a task.

### Building the App

**macOS**:
```bash
xcodebuild -scheme Ayna -destination 'platform=macOS' build
```

**iOS**:
```bash
xcodebuild -scheme Ayna-iOS -destination 'platform=iOS Simulator,name=iPhone 17' build
```

### Requirements
- macOS 14.0+ (Sonoma)
- Xcode 16.0+
- Swift 6.2.1

### Testing
The repository ships with the `aynaTests` unit bundle plus a deterministic `aynaUITests` UI bundle.

- Run unit tests (logic/backend):
  ```bash
  xcodebuild -scheme Ayna -destination 'platform=macOS' test -only-testing:aynaTests
  ```
- Run UI tests (views/interactions):
  ```bash
  xcodebuild -scheme Ayna -destination 'platform=macOS' test -only-testing:aynaUITests
  ```
- Run the entire suite:
  ```bash
  xcodebuild -scheme Ayna -destination 'platform=macOS' test
  ```
- Tests live under `Tests/aynaTests/` and rely on `InMemoryKeychainStorage` plus `MockURLProtocol` to avoid hitting the real Keychain or network. UI smoke tests live under `Tests/aynaUITests/` and launch the app with `--ui-testing` + `AYNA_UI_TESTING=1`, which swaps an in-memory Keychain, temporary store, and mocked OpenAI responses.
- `OpenAIService` now accepts injected `URLSession` and `KeychainStoring` implementations—use those seams when writing additional tests.
- CI enforces the same command via `.github/workflows/tests.yml`; keep the suite deterministic and free of external side effects.

### Build & Test Expectations
- Unless your change is strictly documentation (e.g., Markdown copy edits with zero code or config impact), run `xcodebuild -scheme Ayna -destination 'platform=macOS' build`.
- For logic or backend changes, run unit tests (`-only-testing:aynaTests`).
- For UI changes, run UI tests (`-only-testing:aynaUITests`).
- If changes span both or you are unsure, run the full suite.
- When introducing new functionality or bug fixes, add or update unit tests wherever possible so coverage grows alongside the feature.
- Fix every build, lint, or test failure you hit; do not skip failures unless the user explicitly waives them for that task.
- Note any deviations (such as intentionally skipping tests for docs-only edits) in your final handoff so the user knows what ran.

### Linting
- Run `swiftlint --strict` from the repo root after every non-trivial change and before handing work back to the user.
- Run `swiftformat .` from the repo root whenever you touch Swift files so formatting stays consistent with the rest of the project.
- Fix every reported warning; only add `// swiftlint:disable` annotations when there is a documented reason in-code.
- Do **not** raise lint thresholds or comment out rules to “get green.” If a rule is noisy, discuss with the user before changing `.swiftlint.yml`.
- When editing large files (e.g., `Views/SettingsView.swift`), keep existing scoped disables intact and avoid introducing new violations elsewhere.
- **Proactively design for linting compliance**: avoid long functions (> 40 lines) and excessive parameters (> 5). Refactor early using helper methods or parameter structs rather than waiting for the linter to fail.

### Git Usage
- Never run `git push`; leave publishing commits and branches to the user.

## Architecture

### Core Structure
The codebase follows a "Symmetric Roots" architecture to support both macOS and iOS with maximum code sharing while maintaining native platform idioms:

```
App/ (Entry points) → Core/ (Logic) → Views/ (UI)
```

**App** (`App/macOS/`, `App/iOS/`)
- Platform-specific entry points (`aynaApp.swift`, `AynaIOSApp.swift`)
- Platform-specific configuration (`Info.plist`, `Entitlements`)
- Assets (`Assets.xcassets`)

**Core** (`Core/Models`, `Core/ViewModels`, `Core/Services`, `Core/Utilities`, `Core/Diagnostics`)
- Shared business logic, data models, and services
- **Models**: `Conversation`, `Message` (Codable, UUID-based)
- **ViewModels**: `ConversationManager` (State source of truth)
- **Services**: `OpenAIService`, `MCPServerManager` (API & Tooling)
- **Utilities**: Helpers for markdown, keychain, etc.
- **Diagnostics**: Unified logging system (`DiagnosticsLogger`)

**Views** (`Views/macOS`, `Views/iOS`)
- **macOS**: `MacContentView`, `MacSidebarView`, `MacChatView`, `MacSettingsView`, `MacMessageView`, `DynamicTextEditor`, `AIKitSettingsView`, `MCPSettingsView`, `MCPToolSummaryView`
- **iOS**: `IOSContentView`, `IOSSidebarView`, `IOSChatView`, `IOSSettingsView`, `IOSMessageView`

### State Management Pattern
- `@StateObject` in App entry point for `ConversationManager`
- `.environmentObject()` to inject throughout view hierarchy
- Access via `@EnvironmentObject` in child views
- All state mutations go through `ConversationManager` methods

### Multi-Provider Support
The app supports multiple AI providers via the `AIProvider` enum:

**OpenAI**: Standard OpenAI API (plus any OpenAI-compatible endpoint)
- Default endpoint: `https://api.openai.com/v1/chat/completions`
- Auth: `Authorization: Bearer {key}`
- Model specified in request body
- Azure detection: if a custom endpoint contains `openai.azure.com`, `OpenAIService` automatically builds Azure deployment URLs, appends `api-version=2025-04-01-preview`, and swaps headers to `api-key`

**AIKit**: Local containerized AI models via Podman (uses OpenAI-compatible endpoint)
- Endpoint: `http://localhost:8080/v1/chat/completions`
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

**MCP Servers**:
The app ships with a single default configuration:
- `wassette`: Runs the [Wassette](https://github.com/microsoft/wassette) MCP runtime (`wassette serve --stdio`) so users can load secure WebAssembly tools without manual setup.

Users can add any other MCP server via Settings.

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
- Conversations are JSON-encoded via `Codable` and written to individual encrypted files (`{UUID}.enc`) in `Application Support/Ayna/Conversations`.
- Encryption uses AES-GCM with a 256-bit symmetric key stored in the Keychain.
- Auto-saves individual conversations after mutation (create, update, add message, etc.) with a per-conversation debounce to reduce writes.
- Loads all valid conversation files on `ConversationManager.init()`; corrupted files are skipped or handled gracefully.

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
3. Ensure the endpoint and authentication align with the provider (Azure deployments should use the deployment name as the model name plus `https://<resource>.openai.azure.com` as the endpoint)

### Modifying UI Layout
- Window size constraints set in `App/macOS/aynaApp.swift`: `.frame(minWidth: 900, minHeight: 600)`
- Sidebar minimum width: 260px (set in `NavigationSplitView`)
- Use native SwiftUI controls for consistency
- App uses `.windowStyle(.hiddenTitleBar)` and `.windowToolbarStyle(.unified)` for modern macOS appearance

### Adding Settings
`Views/macOS/MacSettingsView.swift` uses `TabView` with 4 tabs. To add new setting:
1. Add `@Published` property to appropriate manager (`OpenAIService` or `ConversationManager`)
2. Save to `UserDefaults` in property `didSet`
3. Add UI control in relevant settings tab
4. Use `@ObservedObject` binding

## Security Considerations

### API Key Storage
API keys (global and per-model) are stored in the macOS Keychain via `KeychainStorage`. No plaintext copies remain in `UserDefaults`.

### App Sandbox
App has `App Sandbox` disabled (`com.apple.security.app-sandbox` set to `false`) to allow:
- Execution of external MCP servers (e.g. via `npx` or `uvx`)
- File system access for MCP tools

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
- Voice input (add AVFoundation speech recognition)
- iCloud sync (models already `Codable`, switch from `UserDefaults` to CloudKit)

### Known Limitations
- No token usage tracking or cost calculation
- Streaming response parsing is simplistic (may fail on complex SSE formats)
- Azure OpenAI API version hardcoded to `2025-04-01-preview` (update the constant in `OpenAIService` when Azure ships a newer requirement)

## Project Files Reference

### Configuration Files
- `Ayna.xcodeproj/project.pbxproj` - Xcode project settings
- `App/macOS/ayna.entitlements` - App capabilities and sandboxing
- `App/macOS/Info.plist` - App configuration

### Documentation
- `README.md` - Comprehensive feature list and setup guide
- `AGENTS.md` - This file - development guide for AI assistants
- `LICENSE` - MIT License

### Assets
- `App/macOS/Assets.xcassets/` - App icon and color assets (using SF Symbols for icons)

## Additional Notes

- The app uses SF Symbols for all icons (e.g., "bubble.left", "star", "gear", "message", "sparkles")
- Dark/Light mode support is automatic via system colors
- Keyboard shortcuts defined in `aynaApp.swift` using `.commands` modifier (Cmd+N for new conversation)
- Settings window configured in `aynaApp.swift` using `Settings` scene
- App entry point is `aynaApp` struct in `aynaApp.swift`
