# Contributing

Thank you for helping improve **Ayna**! This guide covers development setup, code style, and how to submit changes.

## Development Environment

### Requirements

- macOS 14.0 (Sonoma) or newer
- Xcode 16.0+ with Swift 6.0 toolchain
- iOS Simulator for iOS development
- watchOS Simulator for watchOS development

### Setup

```bash
git clone https://github.com/sozercan/ayna.git
cd ayna
open ayna.xcodeproj
```

### Build Commands

```bash
# macOS
xcodebuild -scheme Ayna -destination 'platform=macOS' build

# iOS
xcodebuild -scheme Ayna-iOS -destination 'platform=iOS Simulator,name=iPhone 17' build

# watchOS
xcodebuild -scheme Ayna-watchOS -destination 'platform=watchOS Simulator,name=Apple Watch Ultra 3 (49mm)' build
```

## Code Style Guidelines

### SwiftUI Conventions

| Avoid | Prefer |
|-------|--------|
| `.foregroundColor()` | `.foregroundStyle()` |
| `.cornerRadius()` | `.clipShape(.rect(cornerRadius:))` |
| `NavigationView` | `NavigationStack` |
| `DispatchQueue.main.async` | `@MainActor` or `await MainActor.run {}` |
| `AnyView` | Concrete types or `@ViewBuilder` |
| XCTest for unit tests | Swift Testing (`@Suite`, `@Test`, `#expect`) |

### General Rules

- **Cross-Platform**: Code in `Core/` must compile for macOS, iOS, and watchOS. Use `#if os()` guards for platform-specific code.
- **Concurrency**: Mark `@Observable` classes with `@MainActor`. Use Swift concurrency (`async`/`await`), not `DispatchQueue`.
- **Logging**: Use `DiagnosticsLogger` for all logging.
- **Security**: Store secrets in Keychain, never in UserDefaults or hardcoded.
- **Design Tokens**: Use `Theme`, `Typography`, `Spacing` from `Core/Design/` instead of hardcoded values.

### Linting

Run before committing:

```bash
swiftlint --strict && swiftformat .
```

## Testing

Unit tests use [Swift Testing](https://developer.apple.com/documentation/testing), not XCTest. UI tests remain on XCTest.

```bash
# Unit tests only
xcodebuild -scheme Ayna -destination 'platform=macOS' test -only-testing:aynaTests

# Full test suite
xcodebuild -scheme Ayna -destination 'platform=macOS' test
```

See [docs/testing.md](docs/testing.md) for detailed testing patterns.

## Submitting a Pull Request

1. **Fork and clone** the repository
2. **Create a branch** from `main`: `git checkout -b feature/your-feature`
3. **Make your changes** following the code style guidelines
4. **Run the checks**:
   ```bash
   # Lint
   swiftlint --strict && swiftformat .

   # Test
   xcodebuild -scheme Ayna -destination 'platform=macOS' test

   # Verify cross-platform (if modifying Core/)
   xcodebuild -scheme Ayna-iOS -destination 'platform=iOS Simulator,name=iPhone 17' build
   ```
5. **Commit** with a descriptive message
6. **Push** and open a pull request

### PR Checklist

- [ ] Tests pass locally
- [ ] Linting passes (`swiftlint --strict && swiftformat .`)
- [ ] Cross-platform builds verified (if modifying `Core/`)
- [ ] New code includes tests where applicable
- [ ] Documentation updated if behavior changes

## Reporting Issues

When reporting bugs, please include:

- **Environment**: macOS/iOS/watchOS version, Xcode version
- **Steps to reproduce**: Clear, numbered steps
- **Expected vs actual behavior**: What should happen vs what happens
- **Logs/screenshots**: If applicable, include console output or screenshots

For feature requests, describe the use case and why it would benefit users.

Open issues at: [github.com/sozercan/ayna/issues](https://github.com/sozercan/ayna/issues)

## Additional Resources

- [Architecture Overview](docs/architecture.md)
- [Platform-Specific Patterns](docs/platforms.md)
- [Testing Guide](docs/testing.md)
- [Architecture Decision Records](docs/adr/README.md)
