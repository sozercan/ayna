# AGENTS.md

This file provides guidance to AI coding assistants (Claude, GitHub Copilot, etc.) when working with code in this repository.

## 🚨 CRITICAL INSTRUCTIONS

### Cross-Platform Compatibility
**CRITICAL**: This project targets both macOS and iOS.
- Shared code (Models, ViewModels, Services, Utilities) must compile for **both** platforms.
- Avoid platform-specific imports (e.g., `AppKit`, `UIKit`) in shared files unless wrapped in `#if os(macOS)` or `#if os(iOS)`.
- When modifying shared logic, **always** verify the build for both platforms to ensure no regressions.

### Build Commands
**macOS**:
```bash
xcodebuild -scheme Ayna -destination 'platform=macOS' build
```

**iOS**:
```bash
xcodebuild -scheme Ayna-iOS -destination 'platform=iOS Simulator,name=iPhone 17' build
```

### Test Commands
- **Unit Tests** (Logic/Backend):
  ```bash
  xcodebuild -scheme Ayna -destination 'platform=macOS' test -only-testing:aynaTests
  ```
- **UI Tests** (Views/Interactions):
  ```bash
  xcodebuild -scheme Ayna -destination 'platform=macOS' test -only-testing:aynaUITests
  ```
- **Full Suite**:
  ```bash
  xcodebuild -scheme Ayna -destination 'platform=macOS' test
  ```

### Linting & Git
- Run `swiftlint --strict` after every non-trivial change.
- Run `swiftformat .` to maintain consistency.
- **Never** run `git push`.

## 🏗️ ARCHITECTURE & PATTERNS

### Core Structure
The codebase follows a "Symmetric Roots" architecture:
```
App/ (Entry points) → Core/ (Logic) → Views/ (UI)
```
- **App**: Platform-specific entry points (`aynaApp.swift`, `AynaIOSApp.swift`)
- **Core**: Shared logic (`Models`, `ViewModels`, `Services`, `Utilities`)
- **Views**: Platform-specific UI (`Views/macOS`, `Views/iOS`)

### State Management
- **Source of Truth**: `ConversationManager` (`@StateObject` in App, `@EnvironmentObject` in views).
- **Persistence**: Conversations are JSON-encoded, encrypted (AES-GCM), and stored in `Application Support/Ayna/Conversations`.

## 🧠 AI PROVIDERS

The app supports multiple AI providers via the `AIProvider` enum and `OpenAIService`.

### OpenAI Service Architecture
Decomposed into single-responsibility components:
- `OpenAIService.swift`: Coordinator/Facade.
- `OpenAIEndpointResolver.swift`: URL resolution (OpenAI, Azure, GitHub Models, AIKit).
- `OpenAIRequestBuilder.swift`: Request factory (`@MainActor`).
- `OpenAIStreamParser.swift`: SSE parsing and tool call handling.
- `OpenAIRetryPolicy.swift`: Exponential backoff.

### GitHub Models
- **Cross-Platform**: Works on both macOS and iOS.
- **Authentication**: Uses GitHub OAuth Web Flow with PKCE (`GitHubOAuthService.swift`).
  - **Token Exchange**: Proxied via Cloudflare Worker (`https://ayna.sozercan.workers.dev`) to secure `client_secret`.
  - **Flow**: `ASWebAuthenticationSession` handles the browser interaction.
- **API Endpoint**: `https://models.github.ai/inference/chat/completions`.
- **Headers**: Requires `Authorization: Bearer <token>`, `Accept: application/vnd.github+json`, `X-GitHub-Api-Version: 2022-11-28`.
- **Model Catalog**: Available models fetched from `https://models.github.ai/catalog/models`.
- **Key Files**: `GitHubOAuthService.swift` (OAuth flow), `GitHubModelsConfigurationView` (in `MacSettingsView.swift`).

### Multi-Model Architecture
- **Concept**: Allows sending a single prompt to multiple models simultaneously for comparison.
- **Data Model**:
  - `ResponseGroup`: Links a user message to multiple assistant messages (one per model).
  - `Message`: Each assistant response is a separate `Message` entity with a `model` property.
- **Execution**:
  - `OpenAIService.sendToMultipleModels`: Manages concurrent `Task`s for each model.
  - **Streaming**: Callbacks (`onChunk`, `onModelComplete`, `onError`) are keyed by `model` name to route data to the correct message.
- **State Management**:
  - ViewModels (`IOSChatViewModel`) maintain a mapping of `model -> messageId`.
  - Updates are applied atomically to `ConversationManager` to prevent race conditions during parallel streaming.

### AIKit (Local Models)
- **macOS Only**.
- Uses Podman to run containerized models (Llama, Mixtral, etc.).
- Endpoint: `http://localhost:8080/v1/chat/completions`.
- Managed by `AIKitService` and `AIKitSettingsView`.

### MCP (Model Context Protocol)
- **macOS Only**.
- Enables tool calling via local servers (e.g., `wassette`).
- Architecture: `MCPServerManager` (Connection), `MCPService` (Stdio), `MCPModels`.
- Flow: User Message → LLM requests tool → App executes tool → Result sent back → LLM Final Answer.

### Web Search (Tavily)
- **Cross-Platform**: Works on both macOS and iOS.
- **Provider**: Tavily API (`https://api.tavily.com/search`).
- **Authentication**: API key stored in Keychain (`TavilyService.swift`).
- **Key Files**:
  - `TavilyService.swift`: API client, tool definition, and execution.
  - `TavilyModels.swift`: Request/response models (`TavilySearchRequest`, `TavilySearchResponse`, `TavilyError`).
  - `IOSToolsSettingsView` (in `IOSSettingsView.swift`): iOS configuration UI.
  - `ToolsSettingsView` (in `MacSettingsView.swift`): macOS configuration UI.
- **Tool Integration**:
  - Tool name: `web_search`
  - Parameters: `query` (required), `topic` (general/news/finance), `max_results` (1-5, default 3).
  - Results formatted as markdown with AI-generated answer + source snippets.
- **Flow**: Model requests `web_search` tool → `TavilyService.executeToolCall()` → Results returned to model → Model generates final response.
- **Performance**: Optimized for speed with reduced result count (3) and shorter snippets (150 chars).

## 🧪 TESTING STRATEGY

### Unit Test Requirements
**CRITICAL**: New code in `Core/` (Services, Models, ViewModels, Utilities) **must** include unit tests.
- Create test file in `Tests/aynaTests/` matching the source file name (e.g., `TavilyService.swift` → `TavilyServiceTests.swift`).
- Add the test file to `Ayna.xcodeproj/project.pbxproj` (PBXFileReference, PBXBuildFile, and group entry in aynaTests).
- Use existing test patterns: `MockURLProtocol` for network, `InMemoryKeychainStorage` for keychain.
- Run tests before marking work complete: `xcodebuild -scheme Ayna -destination 'platform=macOS' test -only-testing:aynaTests`

### Environment Isolation
Tests run with `AYNA_UI_TESTING=1`, injecting:
- `InMemoryKeychainStorage`: No system keychain access.
- `MockURLProtocol`: Deterministic network responses.
- Temporary storage paths.

### UI Testing Guidelines
- **Identifiers**: Mandatory `.accessibilityIdentifier` on all interactive elements.
- **Naming Convention**: Use dot notation (e.g., `sidebar.newConversationButton`, `chat.composer.textEditor`, `message.action.copy`).
- **Dynamic Elements**: Append IDs for lists (e.g., `sidebar.conversationRow.{UUID}`).
- **Hover States (macOS)**: Must explicitly `.hover()` over container to reveal child buttons.
- **Async**: Use `waitForExistence(timeout:)`, never `sleep()`.


## 📱 PLATFORM SPECIFICS

| Feature | macOS | iOS |
|---------|-------|-----|
| **GitHub Models** | ✅ Full Support | ✅ Full Support |
| **Web Search (Tavily)** | ✅ Full Support | ✅ Full Support |
| **MCP / AIKit** | ✅ Full Support | ❌ Not Supported (Sandboxing/Runtime limits) |
| **UI Metaphor** | Sidebar + Detail (`NavigationSplitView`) | TabView / Stack |
| **Inputs** | Keyboard Shortcuts (Cmd+N) | Swipe Actions |

**Note**: `OpenAIService.usableModels` automatically filters out AIKit models on iOS.

## 📝 CODE STYLE & LOGGING

### Logging
- **Mandatory**: Log via `DiagnosticsLogger.log`.
- **Format**: Emoji prefix + concise message + metadata.
  ```swift
  DiagnosticsLogger.log(.mcpServerManager, level: .info, message: "✅ Connected", metadata: ["server": name])
  ```
- **Breadcrumbs**: Logs persist to `breadcrumbs.json` for debugging.

### Error Handling
- Use `OpenAIError` (LocalizedError).
- Display errors in UI (red text).
- Log errors with context before handling.

## PROJECT FILES
- `AGENTS.md`: This file.
- `App/macOS/ayna.entitlements`: Capabilities (Sandbox disabled for MCP).
- `README.md`: Feature list.
