# ADR-0003: Cross-Platform Core Module

**Date**: 2024-12-01  
**Status**: Accepted  
**Context**: Sharing business logic across macOS, iOS, and watchOS while maintaining platform-specific UI  

## Context

Ayna targets three Apple platforms with different capabilities:

| Platform | UI Framework | Unique Features |
|----------|--------------|-----------------|
| macOS | AppKit + SwiftUI | MCP tools, AIKit, App attachments, window management |
| iOS | UIKit + SwiftUI | Touch UI, share extensions |
| watchOS | SwiftUI only | Compact UI, Watch Connectivity |

We needed to:
1. Maximize code reuse for business logic
2. Allow platform-specific implementations
3. Maintain separate UI for each platform
4. Ensure changes to shared code don't break other platforms

## Decision

### 1. Core Module Structure

All shared logic lives in `Core/`:

```
Core/
├── Models/           # Data types (Conversation, Message, etc.)
├── ViewModels/       # @Observable state management
├── Services/         # Business logic (AIService, etc.)
│   └── Providers/    # AI provider implementations
├── Utilities/        # Helpers (ErrorPresenter, etc.)
├── Design/           # Shared design tokens
└── Diagnostics/      # Logging
```

### 2. Platform Guards

Use `#if os()` for platform-specific code within Core:

```swift
#if os(macOS)
// macOS-only implementation
#elseif os(iOS)
// iOS-only implementation
#elseif os(watchOS)
// watchOS-only implementation
#endif
```

### 3. Platform-Specific Views

Views are separated by platform:

```
Views/
├── macOS/    # macOS-specific SwiftUI views
├── iOS/      # iOS-specific SwiftUI views
└── watchOS/  # watchOS-specific SwiftUI views
```

### 4. Build Verification

Mandatory verification after Core changes:

```bash
# Must pass all three
xcodebuild -scheme Ayna -destination 'platform=macOS' build
xcodebuild -scheme Ayna-iOS -destination 'platform=iOS Simulator,...' build
xcodebuild -scheme Ayna-watchOS -destination 'platform=watchOS Simulator,...' build
```

### 5. Feature Availability

Document platform support in AGENTS.md:

| Feature | macOS | iOS | watchOS |
|---------|-------|-----|---------|
| OpenAI / Azure / GitHub Models | ✅ | ✅ | ✅ |
| Apple Intelligence | ✅ | ✅ | ❌ |
| MCP Tools | ✅ | ❌ | ❌ |

## Consequences

### Positive

1. **Code reuse**: ~80% of logic shared across platforms
2. **Consistency**: Same models and services everywhere
3. **Testing**: Core tests run once, cover all platforms
4. **Type safety**: Compiler catches platform mismatches

### Negative

1. **Build time**: Must verify all platforms after Core changes
2. **Complexity**: `#if os()` guards can be hard to read
3. **Lowest common denominator**: Some features limited by watchOS
4. **Import restrictions**: Cannot use UIKit/AppKit freely in Core

### Neutral

1. **Framework differences**: SwiftUI API variations handled in Views
2. **Performance tuning**: May need platform-specific optimizations
3. **Testing strategy**: Unit tests in Core, UI tests per platform

## Platform-Specific Considerations

### macOS
- Window management via AppDelegate
- MCP process lifecycle management
- AIKit integration for local models
- Menu bar and keyboard shortcuts

### iOS
- Adaptive layouts for iPhone/iPad
- Share extension support
- Background refresh considerations

### watchOS
- Extremely compact UI
- Watch Connectivity for phone sync
- Limited memory and processing
- No file system access for attachments

## References

- [AGENTS.md - Platform Feature Support](../../AGENTS.md)
- [docs/platforms.md](../platforms.md)
