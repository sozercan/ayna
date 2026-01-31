# Architecture & Services

This document provides detailed information about Ayna's architecture, services, and design patterns.

## Core Structure

The codebase follows a "Symmetric Roots" architecture:

```
App/ (Entry points) → Core/ (Logic) → Views/ (UI)
```

- **App/**: Platform-specific entry points
  - `aynaApp.swift` (macOS)
  - `AynaIOSApp.swift` (iOS)
  - `AynaWatchApp.swift` (watchOS)
- **Core/**: Shared logic (must compile for all platforms)
  - `Models/` — Data types (`Conversation`, `Message`, `ResponseGroup`, `ContentBlock`)
  - `ViewModels/` — State management (`ConversationManager`, `IOSChatViewModel`, `WatchChatViewModel`)
  - `Services/` — Business logic (AI providers, persistence, sync)
  - `Utilities/` — Helpers (`MarkdownRenderer`, `ConversationExporter`)
- **Views/**: Platform-specific UI
  - `Views/macOS/` — AppKit/SwiftUI hybrid
  - `Views/iOS/` — UIKit/SwiftUI
  - `Views/watchOS/` — WatchKit/SwiftUI

## State Management

- **Source of Truth**: `ConversationManager` (`@StateObject` in App, `@EnvironmentObject` in views)
- **Persistence Flow**: `ConversationManager` → `ConversationPersistenceCoordinator` → `EncryptedConversationStore`
- **Storage**: JSON-encoded, AES-GCM encrypted, stored in `Application Support/Ayna/Conversations`

## AI Providers

The app supports multiple AI providers via the `AIProvider` enum.

| Provider | Platforms | Authentication | Endpoint |
|----------|-----------|----------------|----------|
| OpenAI | All | API Key | `api.openai.com` or custom |
| Azure OpenAI | All | API Key | `<resource>.openai.azure.com` |
| GitHub Models | All | OAuth (PKCE) | `models.github.ai` |
| Apple Intelligence | macOS/iOS 26.0+ | None (on-device) | Local |

### OpenAI Service Architecture

Decomposed into single-responsibility components:

| File | Responsibility |
|------|----------------|
| `AIService.swift` | Coordinator/Facade, manages all AI requests |
| `OpenAIEndpointResolver.swift` | URL resolution for different providers |
| `OpenAIRequestBuilder.swift` | Request factory, handles Chat Completions & Responses API formats |
| `OpenAIStreamParser.swift` | SSE parsing, tool call handling |
| `AIRetryPolicy.swift` | Exponential backoff for transient failures |
| `OpenAIImageService.swift` | DALL·E image generation |
| `Providers/AIProviderProtocol.swift` | Protocol defining provider interface |
| `Providers/OpenAIProvider.swift` | OpenAI API implementation |
| `Providers/AzureOpenAIProvider.swift` | Azure OpenAI implementation |
| `Providers/GitHubModelsProvider.swift` | GitHub Models implementation |

### Apple Intelligence Service

- **File**: `AppleIntelligenceService.swift`
- **Requirements**: macOS 26.0+ or iOS 26.0+ with Apple Intelligence enabled
- **Not available on watchOS**
- Uses the on-device Foundation Models framework
- No API key required — runs entirely locally

### GitHub Models

- **Authentication**: OAuth Web Flow with PKCE (`GitHubOAuthService.swift`)
- **Token Exchange**: Proxied via Cloudflare Worker to secure `client_secret`
- **Headers**: `Authorization: Bearer <token>`, `Accept: application/vnd.github+json`, `X-GitHub-Api-Version: 2022-11-28`
- **Model Catalog**: Fetched from `https://models.github.ai/catalog/models`

## Multi-Model Architecture

Allows sending a single prompt to multiple models simultaneously for comparison.

- **Data Model**:
  - `ResponseGroup`: Links a user message to multiple assistant messages
  - Each `Message` has a `model` property identifying which model generated it
- **Execution**: `AIService.sendToMultipleModels` manages concurrent `Task`s
- **Streaming**: Callbacks (`onChunk`, `onModelComplete`, `onError`) are keyed by model name

## Tool Integration

### Web Search (Tavily)

- **Platforms**: macOS, iOS, watchOS
- **Files**: `TavilyService.swift`, `TavilyModels.swift`
- **Tool name**: `web_search`
- **Parameters**: `query` (required), `topic`, `max_results` (default 3)
- **Flow**: Model requests tool → `TavilyService.executeToolCall()` → Results returned → Model generates response

### MCP (Model Context Protocol)

- **macOS only** — sandboxing prevents iOS/watchOS support
- **Files**: `MCPServerManager.swift`, `MCPService.swift`, `MCPModels.swift`
- **Flow**: User Message → LLM requests tool → App executes via MCP server → Result sent back → Final answer

## Deep Link Manager

Handles URL scheme (`ayna://`) for automation and external app integration.

- **File**: `Core/Utilities/DeepLinkManager.swift`
- **Platforms**: macOS, iOS (watchOS receives settings via WatchConnectivity sync)

### Supported Actions

| Action | URL Pattern | Description |
|--------|-------------|-------------|
| Add Model | `ayna://add-model?...` | Configure a new AI model |
| Chat | `ayna://chat?...` | Start a conversation |

### Add Model Parameters

| Parameter | Required | Values | Description |
|-----------|:--------:|--------|-------------|
| `name` | ✅ | String | Model identifier (e.g., `gpt-4o`) |
| `provider` | | `openai`, `github`, `azure`, `apple` | API provider |
| `endpoint` | | URL | Custom API endpoint |
| `key` | | String | API key |
| `type` | | `chat`, `responses`, `image` | Model capability type |

### Chat Parameters

| Parameter | Required | Values | Description |
|-----------|:--------:|--------|-------------|
| `model` | | String | Model to use (default if omitted) |
| `prompt` | | String | Auto-send message |
| `system` | | String | System prompt |
| `provider` | | See Add Model | For unified flow (if model doesn't exist) |
| `endpoint` | | URL | For unified flow |
| `key` | | String | For unified flow |
| `type` | | See Add Model | For unified flow |

### Security

- **Confirmation dialogs**: All `add-model` requests show a confirmation UI before adding
- **URL validation**: Invalid parameters show error banners
- **No auto-key storage**: API keys from URLs require user confirmation

### Implementation Flow

```
URL received → DeepLinkManager.handleURL()
                    ↓
            Parse action & parameters
                    ↓
         ┌─────────┴─────────┐
    add-model              chat
         ↓                   ↓
  pendingAddModel     Check model config params
  (shows confirmation)        ↓
                    ┌────────┴────────┐
              No config params    Has config params
                    ↓                   ↓
           startConversation()   Model exists?
                                      ↓
                              ┌───────┴───────┐
                            Yes              No
                              ↓               ↓
                   startConversation()  pendingAddModel +
                                        pendingChat (unified)
                                              ↓
                                     User confirms add
                                              ↓
                                     startConversation()
```

### URL Format

**Add a Model**

```
ayna://add-model?name=<model>&provider=<provider>&endpoint=<url>&key=<apikey>&type=<type>
```

**Start a Chat**

```
ayna://chat?model=<model>&prompt=<message>&system=<systemprompt>&provider=<provider>&endpoint=<url>&key=<apikey>&type=<type>
```

**Note:** If you include `provider`, `endpoint`, `key`, or `type` parameters in a chat URL and the model doesn't exist, Ayna will prompt to add it first, then start the chat.

### Examples

```bash
# Add an OpenAI model
open "ayna://add-model?name=gpt-4o&provider=openai"

# Start a chat with a specific model and prompt
open "ayna://chat?model=gpt-4o&prompt=Hello"

# Quick question
open "ayna://chat?prompt=What%20is%20the%20capital%20of%20France?"

# Unified flow: Add model and start chat in one URL
open "ayna://chat?model=my-model&provider=openai&endpoint=https://api.example.com&key=sk-xxx&prompt=Hello"
```

### Platform-Specific Handling

- **macOS**: App delegate `application(_:open:)` with `handlesExternalEvents(matching:)` for single-window behavior
- **iOS**: `.onOpenURL` modifier in `AynaIOSApp`

## Persistence & Sync Services

| Service | Purpose |
|---------|---------|
| `ConversationPersistenceCoordinator` | Orchestrates save/load operations with debouncing |
| `EncryptedConversationStore` | AES-GCM encryption for conversations at rest |
| `CloudKitService` | Cross-device sync via iCloud |
| `WatchConnectivityService` | iPhone ↔ Watch settings and conversation sync |
| `AttachmentStorage` | File/image attachment persistence |
| `KeychainStorage` | Secure API key storage |

## Logging

All services must log via `DiagnosticsLogger`:

```swift
DiagnosticsLogger.log(.serviceName, level: .info, message: "✅ Action completed", metadata: ["key": value])
```

- **Categories**: Defined in `DiagnosticsLogger.Category` (e.g., `.aiService`, `.mcpServerManager`, `.cloudKit`)
- **Levels**: `.debug`, `.info`, `.warning`, `.error`
- **Output**: Logs persist to `breadcrumbs.json` for debugging

## Error Handling

### Unified Error Type

The app uses `AynaError` as the unified error type for consistent error handling:

- **File**: `Core/Models/AynaError.swift`
- **Conforms to**: `LocalizedError`, `Sendable`, `Equatable`
- **Categories**: Network, Authentication, Model/Provider, API Response, Tool Execution, Data/Storage, Conversation

```swift
// Example usage
let error = AynaError.missingAPIKey(provider: "OpenAI")
print(error.errorDescription)     // "OpenAI API key not configured"
print(error.recoverySuggestion)   // "Add your OpenAI API key in Settings → Models"
```

### Error Wrapping

```swift
// Wrap any error into AynaError
let aynaError = AynaError.wrap(urlError)  // Converts URLError.timedOut → .timeout

// Create from HTTP response
let error = AynaError.fromHTTPResponse(statusCode: 429, data: responseData)
```

### ErrorPresenter Utility

- **File**: `Core/Utilities/ErrorPresenter.swift`
- Provides user-friendly messages, recovery suggestions, and error categorization
- Determines if errors are retryable or require user action

```swift
let message = ErrorPresenter.userMessage(for: error)
let suggestion = ErrorPresenter.recoverySuggestion(for: error)
let isRetryable = ErrorPresenter.isRetryable(error)
let action = ErrorPresenter.suggestedAction(for: error)  // .retry, .openSettings, .dismiss
```

### Legacy Errors

- `AIService.AIError` — Still used internally by OpenAI-related services
- Display errors in UI with red text styling
- Always log errors with context before handling
