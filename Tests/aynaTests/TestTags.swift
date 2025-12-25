// TestTags.swift
// Centralized test tags for cross-cutting concerns.
//
// Usage:
//   @Test("My test", .tags(.fast))
//   func myTest() { ... }
//
// Filter from CLI:
//   swift test --filter .fast
//   swift test --skip .slow
//
// Filter in Xcode Test Plan:
//   Add tag name to "Include Tags" or "Exclude Tags" field
//

import Testing

extension Tag {
    /// Fast unit tests that complete in milliseconds.
    /// Use for pure logic tests with no I/O or mocking overhead.
    @Tag static var fast: Self

    /// Slower tests that involve file I/O, encryption, or complex mocking.
    /// Consider skipping on quick feedback loops.
    @Tag static var slow: Self

    /// Tests involving network requests (mocked or real).
    /// Useful for isolating API-related failures.
    @Tag static var networking: Self

    /// Tests involving file persistence, encryption, or Keychain access.
    /// May require cleanup between runs.
    @Tag static var persistence: Self

    /// Tests for ViewModel behavior and state management.
    @Tag static var viewModel: Self

    /// Tests for error handling and edge cases.
    @Tag static var errorHandling: Self

    /// Tests that verify async/callback behavior with confirmations.
    @Tag static var async: Self
}
