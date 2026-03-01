# Contributing

Thank you for helping improve **ayna**! This document captures the practical steps for local development, testing, and submitting changes.

## Prerequisites

- macOS 26.0 (Tahoe) or newer
- Xcode 16.0 or newer (Swift 6.0+ toolchain)
- iOS Simulator or device for iOS development
- watchOS Simulator for watchOS development
- Clone the repo and open `Package.swift`.

```bash
git clone https://github.com/yourusername/ayna.git
cd ayna
open Package.swift
```

## Build from Source

1. Open `Package.swift` in Xcode, or build from the command line.
2. In Xcode, select the appropriate scheme and destination:
   - **Ayna** scheme with **My Mac** for macOS
   - **Ayna-iOS** scheme with an iOS Simulator for iOS
   - **Ayna-watchOS** scheme with a watchOS Simulator for watchOS
3. Run with **Cmd+R** or click the Run button.
4. Prefer running from Terminal? Use:

  ```bash
  # macOS
  swift build

  # iOS (cross-compile)
  swift build --triple arm64-apple-ios26.0

  # watchOS (cross-compile)
  swift build --triple arm64-apple-watchos12.0
  ```

## Local Development

1. Select the appropriate scheme and destination in Xcode (see Build from Source above).
2. Build & run with **Cmd+R**.
3. **Important**: Code in `Sources/Ayna/` must compile for all platforms (macOS, iOS, watchOS). Never use `AppKit`/`UIKit` in `Sources/Ayna/` without `#if os()` guards.
4. After modifying shared code, verify builds on multiple platforms:
   ```bash
   swift build
   swift build --triple arm64-apple-ios26.0
   ```

## Testing

**Unit tests use [Swift Testing](https://developer.apple.com/documentation/testing)** (not XCTest). UI tests remain on XCTest.

- Run SwiftLint before committing:
  ```bash
  swiftlint --strict
  ```
- Run the unit test suite with:
  ```bash
  swift test
  ```
- UI tests live under `Tests/AynaUITests/`. They launch the app with `--ui-testing` plus `AYNA_UI_TESTING=1`, which swaps in-memory storage, deterministic models, and mocked OpenAI responses. You can run only the UI bundle with:
  ```bash
  xcodebuild -project AynaUITests.xcodeproj -scheme AynaUITests -destination 'platform=macOS' test
  ```
- Unit tests live in `Tests/AynaTests/` and never touch the real Keychain or network. Use the helpers provided there:
  - `InMemoryKeychainStorage` keeps credentials in-memory during tests.
  - `MockURLProtocol` intercepts `URLSession` traffic for `AIService`.
  - `EncryptedConversationStore` and `ConversationManager` accept dependency-injected stores/file URLs for isolation.
- Keep every test deterministic—avoid real network calls, timers, or writes outside temporary directories.

See [docs/testing.md](docs/testing.md) for detailed testing patterns and templates.

## Architecture

### Core Structure
The codebase follows clean SwiftUI architecture with clear separation:

```
Models → ViewModels → Views → Services
```

**Models** (`Models/Conversation.swift`, `Models/Message.swift`)
- Pure data structures conforming to `Codable` for persistence
- All models use `UUID` for identification
- `Conversation` contains array of `Message` objects and metadata

**ViewModels** (`ViewModels/ConversationManager.swift`)
- `ConversationManager`: Single source of truth for all conversation state
- Manages CRUD operations, search, and persistence
- Uses `@Published` properties for reactive UI updates

**Views**
- `MacContentView` / `IOSContentView`: Root view with `NavigationSplitView`
- `MacSidebarView` / `IOSSidebarView`: Conversation list
- `MacChatView` / `IOSChatView`: Main chat interface
- `MacSettingsView` / `IOSSettingsView`: Configuration tabs

**Services**
- `AIService`: Manages API communication (OpenAI-compatible endpoints with Azure auto-detection and Apple Intelligence)
- `MCPServerManager`: Handles Model Context Protocol tools (macOS only)
- `KeychainStorage`: Securely stores API keys

**Design System** (`Sources/Ayna/Design/`)
- `Theme` (ColorTokens.swift): Semantic color tokens that adapt to light/dark mode and platform
- `Typography`: Consistent text styles with platform-appropriate sizing
- `Spacing`: Layout constants using a 4pt grid system
- `Motion` (Animation.swift): Standardized animation presets and transitions

When building UI, prefer using design tokens over hardcoded values:
```swift
// Prefer this:
Text("Hello").font(Typography.body).foregroundStyle(Theme.textPrimary)

// Over this:
Text("Hello").font(.system(size: 14)).foregroundColor(.primary)
```

### State Management
- `@StateObject` in App entry point for `ConversationManager`
- `.environmentObject()` to inject throughout view hierarchy
- Access via `@EnvironmentObject` in child views

## Code Style and Patterns

- **SwiftUI**: Use `NavigationSplitView` for layout. Use `@StateObject`, `@EnvironmentObject` for state.
- **Linting**: Run `swiftlint --strict` and `swiftformat .` before committing.
- **Logging**: Use `DiagnosticsLogger` with emoji prefixes for easy scanning.
- **Error Handling**: Display user-friendly errors in the UI; log detailed errors with context.

## Common Development Tasks

### Adding a New AI Model
1. Add the model identifier to `AIService.availableModels`.
2. The model will automatically appear in the Settings picker.

### Modifying UI Layout
- The app uses a minimum window size of 900x600.
- Sidebar minimum width is 260px.
- Use native SwiftUI controls for consistency.

## Continuous Integration

Two GitHub Actions run automatically on pushes and pull requests:

- `.github/workflows/tests.yml` builds the project and runs `swift test` on a macOS runner.
- `.github/workflows/dev-build.yml` produces a signed Release build plus a DMG artifact for manual verification.

Please make sure `swift test` succeeds locally before pushing to avoid CI noise.

## Pull Request Checklist

- [ ] Tests pass locally (`swift test`).
- [ ] If modifying `Sources/Ayna/`, verify iOS build: `swift build --triple arm64-apple-ios26.0`
- [ ] Run linting: `swiftlint --strict && swiftformat .`
- [ ] New source files include concise comments only where logic is non-obvious.
- [ ] Security-sensitive code (Keychain, encryption) includes informative logging on error paths.
- [ ] Use design tokens from `Sources/Ayna/Design/` for colors, typography, spacing, and animations.
- [ ] Update documentation (this file, `README.md`, `AGENTS.md`, or `SECURITY.md`) when behavior changes.

We appreciate every contribution—thank you for helping keep ayna fast, secure, and reliable!
