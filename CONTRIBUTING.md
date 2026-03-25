# Contributing to Sockit

Thank you for your interest in contributing. This guide covers the basics to get you started.

## Prerequisites

- Swift 6.0 or later
- Xcode 16 or later (for macOS/iOS development)
- Swift toolchain on Linux (for server-side or cross-platform work)

## Building and Testing

```bash
# Build all targets
swift build

# Run the full test suite
swift test

# Run tests in parallel
swift test --parallel

# Run a specific test target
swift test --filter SockitClientTests
```

All tests should pass before submitting a pull request.

## Pull Request Guidelines

- **Keep PRs focused.** One logical change per pull request. If you are fixing a bug and refactoring nearby code, split them into separate PRs.
- **Add tests.** Every behavioral change should include corresponding reducer tests. Because the reducers are pure functions, tests require no mocking -- just assert on the returned state and effects.
- **Follow existing patterns.** Look at how existing code is structured before introducing new patterns.
- **Write clear commit messages.** Summarize the "why" in the first line, not just the "what."

## Code Style

- Follow the conventions already present in the codebase.
- Use Swift 6 strict concurrency throughout. All public types must be `Sendable`.
- Prefer value types and protocols over class hierarchies.
- No force unwraps in production code.

## Architecture

Sockit uses a pure reducer pattern. When adding new functionality:

1. **Define actions** for the new behavior.
2. **Update the reducer** to handle those actions and return effect descriptions.
3. **Add effect cases** if new side effects are needed.
4. **Execute effects** in the actor layer (Client or Connection).

The reducer must remain a pure function: no async, no side effects, no captured state. This is the core invariant that keeps the library testable.

## Questions

If you have questions or want to discuss a change before starting work, open an issue to start the conversation.
