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
| AIKit | macOS only | None | `localhost:8080` |

### OpenAI Service Architecture

Decomposed into single-responsibility components:

| File | Responsibility |
|------|----------------|
| `OpenAIService.swift` | Coordinator/Facade, manages all AI requests |
| `OpenAIEndpointResolver.swift` | URL resolution for different providers |
| `OpenAIRequestBuilder.swift` | Request factory, handles Chat Completions & Responses API formats |
| `OpenAIStreamParser.swift` | SSE parsing, tool call handling |
| `OpenAIRetryPolicy.swift` | Exponential backoff for transient failures |
| `OpenAIImageService.swift` | DALL·E image generation |

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

### AIKit (Local Models)

- **macOS only** — requires Podman with GPU access
- Uses containerized models (Llama, Mixtral, etc.)
- Managed by `AIKitService.swift` and `AIKitSettingsView`

## Multi-Model Architecture

Allows sending a single prompt to multiple models simultaneously for comparison.

- **Data Model**:
  - `ResponseGroup`: Links a user message to multiple assistant messages
  - Each `Message` has a `model` property identifying which model generated it
- **Execution**: `OpenAIService.sendToMultipleModels` manages concurrent `Task`s
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

- **Categories**: Defined in `DiagnosticsLogger.Category` (e.g., `.openAIService`, `.mcpServerManager`, `.cloudKit`)
- **Levels**: `.debug`, `.info`, `.warning`, `.error`
- **Output**: Logs persist to `breadcrumbs.json` for debugging

## Error Handling

- Use `OpenAIError` (conforms to `LocalizedError`) for AI-related errors
- Display errors in UI with red text styling
- Always log errors with context before handling
