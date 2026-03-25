# Changelog

## [1.0.0] - Unreleased

### Added
- Initial public release
- Cross-platform WebSocket client (iOS/macOS/Linux) with pure reducer architecture
- Vapor-based WebSocket server with typed handler routing
- End-to-end Codable wire protocol (no intermediate types)
- Swift 6 strict concurrency support
- Channel-based pub/sub messaging
- Automatic reconnection with configurable strategies
- Typed command protocol (SockitCommand) for type-safe request/response
- Typed server handlers (SockitHandler) with shared DTOs
- Raw types for deferred JSON decoding (performance optimization)
- Comprehensive client reducer test suite
- Performance benchmarks
