# Contributing

Thank you for helping improve **ayna**! This document captures the practical steps for local development, testing, and submitting changes.

## Prerequisites

- macOS 14.0 (Sonoma) or newer
- Xcode 15.0 or newer (Swift 5.9 toolchain)
- Clone the repo and open `ayna.xcodeproj`.

```bash
git clone https://github.com/yourusername/ayna.git
cd ayna
open ayna.xcodeproj
```

## Local Development

1. Select the **Ayna** scheme and the **My Mac** destination in Xcode.
2. Build & run with **Cmd+R**.
3. For manual builds outside Xcode:
   ```bash
   xcodebuild -project ayna.xcodeproj -scheme Ayna -destination 'platform=macOS' build
   ```

## Testing

- Run SwiftLint before committing:
  ```bash
  swiftlint --strict
  ```
- Run the full suite (unit + UI tests) with:
  ```bash
  xcodebuild -scheme Ayna -destination 'platform=macOS' test
  ```
- UI tests live under `aynaUITests/`. They launch the app with `--ui-testing` plus `AYNA_UI_TESTING=1`, which swaps in-memory storage, deterministic models, and mocked OpenAI responses. You can run only the UI bundle with:
  ```bash
  xcodebuild -scheme Ayna -destination 'platform=macOS' -only-testing AynaUITests test
  ```
- Unit tests remain in `aynaTests/` and never touch the real Keychain or network. Use the helpers provided there:
  - `InMemoryKeychainStorage` keeps credentials in-memory during tests.
  - `MockURLProtocol` intercepts `URLSession` traffic for `OpenAIService`.
  - `EncryptedConversationStore` and `ConversationManager` accept dependency-injected stores/file URLs for isolation.
- Keep every test deterministic—avoid real network calls, timers, or writes outside temporary directories.

## Continuous Integration

Two GitHub Actions run automatically on pushes and pull requests:

- `.github/workflows/tests.yml` builds the project and runs `xcodebuild test` on a macOS runner.
- `.github/workflows/dev-build.yml` produces a signed Release build plus a DMG artifact for manual verification.

Please make sure `xcodebuild test` succeeds locally before pushing to avoid CI noise.

## Pull Request Checklist

- [ ] Tests pass locally (`xcodebuild -scheme Ayna -destination 'platform=macOS' test`).
- [ ] New source files include concise comments only where logic is non-obvious.
- [ ] Security-sensitive code (Keychain, encryption) includes informative logging on error paths.
- [ ] Update documentation (this file, `README.md`, `AGENTS.md`, or `SECURITY.md`) when behavior changes.

We appreciate every contribution—thank you for helping keep ayna fast, secure, and reliable!
