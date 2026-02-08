# Common Bug Patterns to Avoid

These patterns have caused bugs in Swift/SwiftUI codebases. Always check for these during code review.

## Fire-and-Forget Tasks

```swift
// BAD: Task not tracked, errors lost, can't cancel
func sendMessage() {
    Task { await api.send(message) }
}

// GOOD: Track task, handle errors, support cancellation
private var sendTask: Task<Void, Error>?

func sendMessage() async throws {
    sendTask?.cancel()
    sendTask = Task {
        try await api.send(message)
    }
    try await sendTask?.value
}
```

## Optimistic Updates Without Proper Rollback

```swift
// BAD: CancellationError not handled, state permanently wrong
func toggleFavorite(_ item: Item) async {
    let previous = favorites[item.id]
    favorites[item.id] = !previous  // Optimistic update
    do {
        try await api.setFavorite(item.id, !previous)
    } catch {
        favorites[item.id] = previous  // Doesn't run on cancellation!
    }
}

// GOOD: Handle ALL errors including cancellation
func toggleFavorite(_ item: Item) async {
    let previous = favorites[item.id]
    favorites[item.id] = !previous
    do {
        try await api.setFavorite(item.id, !previous)
    } catch is CancellationError {
        favorites[item.id] = previous  // Rollback on cancel
        throw CancellationError()
    } catch {
        favorites[item.id] = previous  // Rollback on error
        throw error
    }
}
```

## `.onAppear` Instead of `.task` for Async Work

```swift
// BAD: Task not cancelled on disappear, can update stale view
.onAppear {
    Task { await viewModel.load() }
}

// GOOD: Lifecycle-managed, auto-cancelled on disappear
.task {
    await viewModel.load()
}

// GOOD: With ID for re-execution on change
.task(id: conversationId) {
    await viewModel.load(conversationId)
}
```

## ForEach with Unstable Identity

```swift
// BAD: Index-based identity causes wrong views during mutations
ForEach(messages.indices, id: \.self) { index in
    MessageRow(message: messages[index])
}

// BAD: Array enumeration recreates identity on every change
ForEach(Array(messages.enumerated()), id: \.offset) { index, message in
    MessageRow(message: message)
}

// GOOD: Use stable model identity
ForEach(messages) { message in
    MessageRow(message: message)
}

// GOOD: If you need index for display, use element ID
ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
    MessageRow(message: message, index: index)
}
```

## Background Tasks Not Cancelled on Deinit

```swift
// BAD: Task continues after ViewModel is deallocated
@Observable @MainActor
class ConversationViewModel {
    private var streamTask: Task<Void, Never>?

    func startStreaming() {
        streamTask = Task { /* ... */ }
    }
    // Missing deinit cleanup!
}

// GOOD: Cancel tasks in deinit
@Observable @MainActor
class ConversationViewModel {
    private var streamTask: Task<Void, Never>?

    func startStreaming() {
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            // ...
        }
    }

    deinit {
        streamTask?.cancel()
    }
}
```

## Static Shared Singletons with Mutable Assignment

```swift
// BAD: Race condition if multiple instances created
class ConversationViewModel {
    static var shared: ConversationViewModel?
    init() { Self.shared = self }  // Overwrites previous!
}

// GOOD: Use SwiftUI Environment for dependency injection
@Observable @MainActor
class ConversationViewModel { /* ... */ }

// In parent view:
.environment(conversationViewModel)

// In child view:
@Environment(ConversationViewModel.self) var viewModel
```

## Using `#available` for New SDK APIs

```swift
// BAD: #available is RUNTIME only — code still must COMPILE against older SDKs
// This fails to build on Xcode 16.x because .glassEffect() doesn't exist in the SDK
if #available(macOS 26.0, *) {
    view.glassEffect(.regular)  // Compile error on older SDKs!
}

// GOOD: Use compile-time checks for APIs that don't exist in older SDKs
#if compiler(>=6.2)  // Xcode 26+ ships Swift 6.2
if #available(macOS 26.0, *) {
    view.glassEffect(.regular)
}
#endif

// ALSO GOOD: Separate source files with build configurations
// Put macOS 26+ code in a separate file excluded from older SDK builds
```

**Key insight**: `#available` checks which OS version is *running*, but the compiler must still *parse and type-check* all code paths. For APIs that don't exist in older SDKs at all, use `#if compiler()` or `#if swift()` to hide the code from the compiler entirely.

## Passing Non-Sendable Types Across Actor Boundaries

```swift
// BAD: NSImage/UIImage are non-Sendable — can't cross actor boundaries
let image = await Task.detached(priority: .userInitiated) {
    return NSImage(data: imageData)  // NSImage created off main actor
}.value  // Error: non-sendable type cannot exit actor-isolated context

// GOOD: Keep image creation on the same actor
@MainActor
func loadImage(from data: Data) -> NSImage? {
    return NSImage(data: data)
}

// ALSO GOOD: Pass Sendable data, create image on destination actor
let imageData = await Task.detached {
    return processImageData(data)  // Data is Sendable
}.value
let image = NSImage(data: imageData)  // Create on @MainActor
```

**Why**: `NSImage` and `UIImage` are explicitly marked non-`Sendable` by Apple. Swift 6 strict concurrency enforces this to prevent data races.

## Accessing @MainActor Singletons from Nonisolated Context

```swift
// BAD: Accessing @MainActor static property from nonisolated context
@MainActor
class MyService {
    static let shared = MyService()
}

func someNonisolatedFunc() {
    let service = MyService.shared  // Warning in Swift 5, Error in Swift 6!
}

// GOOD: Make the accessor async and await it
func someNonisolatedFunc() async {
    let service = await MyService.shared
}

// ALSO GOOD: Mark the calling function @MainActor
@MainActor
func someMainActorFunc() {
    let service = MyService.shared  // OK — same actor isolation
}
```

## Delegate Protocol Conformance from @MainActor Classes

```swift
// BAD: Completion handler sendability doesn't match protocol requirement
// This compiles on Xcode 26+ but FAILS on Xcode 16.x
@MainActor
class PermissionService: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

// GOOD: Mark completion handler as @Sendable to match protocol requirement
@MainActor
class PermissionService: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
```

**Why**: Apple's delegate protocols increasingly require `@Sendable` completion handlers for Swift 6 concurrency safety. Older Xcode versions (16.x) enforce this more strictly than newer versions (26+). Always add `@Sendable` to completion handlers in delegate methods to ensure compatibility across all supported Xcode versions.

**Affected protocols** (non-exhaustive):
- `UNUserNotificationCenterDelegate`
- `URLSessionDelegate` and variants
- `WCSessionDelegate`

## Discarding Results: `let _ =` vs `_ =`

```swift
// BAD: SwiftLint violation (redundant_discardable_let)
let _ = someFunction()

// GOOD: Simpler syntax for discarding results
_ = someFunction()
```

**Why**: `let _ =` is unnecessarily verbose. The `_` wildcard pattern alone is sufficient to discard a result. SwiftLint enforces this in strict mode.

---

## Pre-Push Checklist

Before pushing code, run these locally to avoid CI failures:

```bash
# 1. Lint check (catches style violations)
swiftlint --strict

# 2. Format check (ensures consistent style)
swiftformat . --lint

# 3. Build on macOS (catches compile errors)
xcodebuild -scheme Ayna -destination 'platform=macOS' build

# 4. Run unit tests (catches regressions)
xcodebuild -scheme Ayna -destination 'platform=macOS' test -only-testing:aynaTests
```

**Key insight**: CI runs on multiple Xcode versions (16.2, 16.4, 26.0). Code that compiles locally on Xcode 26 may fail on older versions due to stricter sendability checking. When in doubt, add explicit `@Sendable` annotations to closures and completion handlers.
