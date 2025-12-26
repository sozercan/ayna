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
| **MCP Tools** | ✅ | ❌ | ❌ |
| **Web Search (Tavily)** | ✅ | ✅ | ✅ (via iPhone) |
| **Image Generation** | ✅ | ✅ | ❌ |
| **Attachments** | ✅ | ✅ | ❌ |
| **CloudKit Sync** | ✅ | ✅ | ❌ |
| **Export (Markdown/PDF)** | ✅ | ✅ | ❌ |
| **Deep Links** | ✅ | ✅ | ❌ |

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
  - No MCP (sandbox prevents subprocess spawning)
- **Scheme**: `Ayna-iOS`

### watchOS

- **Minimum Version**: watchOS 10.0
- **UI Pattern**: `NavigationStack` with list-based navigation
- **Input**: Digital Crown, dictation, scribble
- **Settings Sync**: All settings synced from paired iPhone via `WatchConnectivityService`
- **Limitations**:
  - No local providers (Apple Intelligence)
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

## SwiftUI API Best Practices

Use modern SwiftUI APIs. Our minimum targets (iOS 17.6, macOS 14.0, watchOS 10.6) support all of these.

### Deprecated APIs to Avoid

| ❌ Deprecated | ✅ Use Instead | Notes |
|--------------|----------------|-------|
| `.foregroundColor(_:)` | `.foregroundStyle(_:)` | Works with any `ShapeStyle`, not just `Color` |
| `.cornerRadius(_:)` | `.clipShape(.rect(cornerRadius:))` | More flexible, composable |
| `onChange(of:) { newValue in }` | `onChange(of:) { oldValue, newValue in }` | Two-parameter closure required |
| `Task.sleep(nanoseconds:)` | `Task.sleep(for: .seconds(_:))` | Use `Duration` for clarity |

### Code Examples

```swift
// ❌ Don't
Text("Hello")
    .foregroundColor(.red)
    .background(Color.blue)
    .cornerRadius(8)

// ✅ Do
Text("Hello")
    .foregroundStyle(.red)
    .background(Color.blue)
    .clipShape(.rect(cornerRadius: 8))
```

```swift
// ❌ Don't
.onChange(of: selectedItem) { newValue in
    handleSelection(newValue)
}

// ✅ Do
.onChange(of: selectedItem) { _, newValue in
    handleSelection(newValue)
}
```

```swift
// ❌ Don't
try await Task.sleep(nanoseconds: 500_000_000)

// ✅ Do
try await Task.sleep(for: .milliseconds(500))
```

### Accessibility Requirements

Always add accessibility labels to image-only buttons:

```swift
// ❌ Don't
Button {
    dismiss()
} label: {
    Image(systemName: "xmark.circle.fill")
}

// ✅ Do
Button {
    dismiss()
} label: {
    Image(systemName: "xmark.circle.fill")
}
.accessibilityLabel("Close")
```

### Other Patterns to Prefer

| Pattern | Preferred Approach |
|---------|-------------------|
| Main thread dispatch | `await MainActor.run { }` or `@MainActor` |
| Array enumeration with index | `ForEach(Array(items.enumerated()), id: \.element.id)` is OK, but consider if index is truly needed |
| Optional string display | Use `Text(verbatim:)` for user-generated content to avoid localization issues |

### Filtering Providers by Platform

`OpenAIService.usableModels` automatically filters providers:

```swift
// watchOS: Filters out Apple Intelligence
var usableModels: [String] {
    models.filter { model in
        let provider = modelProviders[model]
        #if os(watchOS)
        return provider != .appleIntelligence
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
