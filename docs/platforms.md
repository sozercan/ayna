# Platform Support

This document details platform-specific capabilities, limitations, and implementation notes.

## Feature Matrix

| Feature | macOS | iOS | watchOS |
|---------|:-----:|:---:|:-------:|
| **Core Chat** | ✅ | ✅ | ✅ |
| **Multi-Model Responses** | ✅ | ✅ | ❌ |
| **OpenAI / Azure / Custom** | ✅ | ✅ | ✅ |
| **GitHub Models (OAuth)** | ✅ | ✅ | ✅ (via iPhone) |
| **Apple Intelligence** | ✅ (26.0+) | ✅ (26.0+) | ❌ |
| **AIKit (Local Models)** | ✅ | ❌ | ❌ |
| **MCP Tools** | ✅ | ❌ | ❌ |
| **Web Search (Tavily)** | ✅ | ✅ | ✅ (via iPhone) |
| **Image Generation** | ✅ | ✅ | ❌ |
| **Attachments** | ✅ | ✅ | ❌ |
| **CloudKit Sync** | ✅ | ✅ | ❌ |
| **Export (Markdown/PDF)** | ✅ | ✅ | ❌ |

## Platform Details

### macOS

- **Minimum Version**: macOS 14.0 (Sonoma)
- **Apple Intelligence**: Requires macOS 26.0+
- **UI Pattern**: `NavigationSplitView` with sidebar + detail
- **Input**: Keyboard shortcuts (`Cmd+N`, `Cmd+,`, `Enter` to send)
- **Entitlements**: Sandbox disabled for MCP subprocess spawning (`ayna.entitlements`)
- **Scheme**: `Ayna`

### iOS

- **Minimum Version**: iOS 17.0
- **Apple Intelligence**: Requires iOS 26.0+
- **UI Pattern**: `TabView` with navigation stacks
- **Input**: Touch, swipe actions for conversation management
- **Limitations**:
  - No AIKit (cannot run Podman containers)
  - No MCP (sandbox prevents subprocess spawning)
- **Scheme**: `Ayna-iOS`

### watchOS

- **Minimum Version**: watchOS 10.0
- **UI Pattern**: `NavigationStack` with list-based navigation
- **Input**: Digital Crown, dictation, scribble
- **Settings Sync**: All settings synced from paired iPhone via `WatchConnectivityService`
- **Limitations**:
  - No local providers (AIKit, Apple Intelligence)
  - No MCP tools
  - No attachments or image generation
  - No CloudKit direct access (syncs via iPhone)
  - Simpler markdown rendering (`WatchMarkdownRenderer`)
- **Scheme**: `Ayna-watchOS`

## Build Commands

```bash
# macOS
xcodebuild -scheme Ayna -destination 'platform=macOS' build

# iOS
xcodebuild -scheme Ayna-iOS -destination 'platform=iOS Simulator,name=iPhone 16' build

# watchOS
xcodebuild -scheme Ayna-watchOS -destination 'platform=watchOS Simulator,name=Apple Watch Ultra 3 (49mm)' build
```

## Cross-Platform Code Guidelines

### Shared Code (`Core/`)

All code in `Core/` must compile for **all three platforms**.

**DO:**
```swift
// Use compile-time checks for platform-specific code
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

// Use canImport for optional frameworks
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif
```

**DON'T:**
```swift
// ❌ Never import platform frameworks unconditionally in Core/
import AppKit  // Breaks iOS/watchOS build
import UIKit   // Breaks macOS/watchOS build
```

### Filtering Providers by Platform

`OpenAIService.usableModels` automatically filters providers:

```swift
// iOS: Filters out AIKit
// watchOS: Filters out AIKit and Apple Intelligence
var usableModels: [String] {
    models.filter { model in
        let provider = modelProviders[model]
        #if os(iOS)
        return provider != .aikit
        #elseif os(watchOS)
        return provider != .aikit && provider != .appleIntelligence
        #else
        return true
        #endif
    }
}
```

## watchOS-Specific Architecture

### WatchConnectivityService

Handles bidirectional sync between iPhone and Apple Watch:

- **iPhone → Watch**: API keys, model selections, Tavily settings
- **Watch → iPhone**: Conversation updates (if initiated on Watch)
- **File**: `Core/Services/WatchConnectivityService.swift`

### WatchChatViewModel

Lightweight ViewModel optimized for Watch constraints:

- Smaller context windows
- Simplified error handling
- No attachment support
- **File**: `Core/ViewModels/WatchChatViewModel.swift`

### WatchConversationStore

Local conversation cache for offline access:

- Syncs from iPhone on connection
- Persists locally for offline viewing
- **File**: `Core/ViewModels/WatchConversationStore.swift`
