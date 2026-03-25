# CLAUDE.md - Sockit Package

## Overview

Sockit is a cross-platform Swift WebSocket abstraction library for both **client (iOS/macOS/Linux)** and **server (Vapor)** with:
- Pure reducer architecture (Elm-style) for testable state management
- Simple JSON wire protocol (not Phoenix V2)
- Protocol-oriented design
- Swift 6 concurrency support
- Linux compatible (no Apple-only APIs)

## Architecture

```
┌─────────────────────────────────────────┐
│ Public API (Actor)                      │
│ Client / Connection                     │
└─────────────────────────────────────────┘
                    ↓
┌─────────────────────────────────────────┐
│ Pure Reducer                            │
│ (State, Action) → [Effect]              │
│ Testable, no side effects               │
└─────────────────────────────────────────┘
                    ↓
┌─────────────────────────────────────────┐
│ Transport / WebSocket                   │
│ URLSession (Apple) / NIO (Linux)        │
└─────────────────────────────────────────┘
```

## Package Structure

```
Sources/
├── SockitCore/            # Shared types (both platforms)
│   ├── Protocol/          # SockitMessage wire format
│   ├── Types/             # Request, Response, PushEvent, Raw* types
│   ├── Transport/         # TransportProtocol, TransportEvent, WebSocketError, LockedValue
│   └── Errors/            # Error types
│
├── SockitClient/          # iOS/macOS/Linux client
│   ├── Public/            # Client actor, ClientConfig, SockitCommand protocol
│   └── Internal/          # State, Action, Effect, Reducer, WebSocketTransport (Apple)
│
├── SockitNIOTransport/    # NIO-based transport (auto-linked on Linux)
│   └── NIOWebSocketTransport  # websocket-kit implementation of TransportProtocol
│
└── SockitServer/          # Vapor server
    ├── Public/            # Connection, ConnectionManager, ChannelRegistry
    ├── Internal/          # State, Action, Effect, Reducer
    └── Vapor/             # VaporIntegration
```

## Wire Protocol

Simple JSON format with **end-to-end Codable** - typed DTOs flow directly without intermediate types:
```json
{
  "event": "home.get_today",
  "payload": { ... },           // typed DTO encoded directly
  "requestId": "uuid-string",   // optional, for request/response
  "channel": "user:123",        // optional, for pub/sub
  "status": "ok"                // optional, for responses (ok|error)
}
```

**Key principle**: No envelope wrapping. The `payload` IS the typed response/request DTO.

## Usage

### Client (iOS/macOS)

```swift
import SockitClient

let client = Client()

// Connect
try await client.connect(config: ClientConfig(
    url: URL(string: "wss://api.example.com/socket")!,
    token: "auth-token"
))

// Join a channel
await client.join("user:self")

// Send a request
await client.send(Request(
    event: "home.get_today",
    payload: [:]
))

// Listen for messages
for await message in client.messages {
    switch message {
    case .response(let response):
        print("Response: \(response)")
    case .pushEvent(let push):
        print("Push: \(push.event)")
    case .rawPushEvent(let push):
        // Preferred: decode to typed payload
        if let payload = try? push.decodePayload(MyPayload.self) {
            print("Typed push: \(payload)")
        }
    case .connectionStateChanged(let state):
        print("Connection: \(state)")
    }
}

// Typed commands (preferred over raw Request)
struct GetProfile: SockitCommand {
    typealias Response = ProfileResponse
    static let event = "profile.get"
}
let profile = try await client.send(GetProfile())
```

### Server (Vapor)

```swift
import Vapor
import SockitServer

// Define typed handler - request and response are Codable DTOs
struct GetTodayHandler: SockitHandlerNoPayload {
    typealias Response = TodaySnapshotDTO  // From shared contracts
    static let event = "home.get_today"

    func handle(context: HandlerContext) async throws -> Response {
        let snapshot = try await fetchTodaySnapshot(userId: context.userId!)
        return snapshot  // Typed DTO, encoded directly to wire
    }
}

// Register handlers
func routes(_ app: Application) throws {
    let router = TypedRouter()
    router.register(GetTodayHandler(app: app))

    app.sockit(path: "socket", router: router) { req in
        try await authenticateToken(req)
    }
}
```

## Key Design Patterns

### State Machine (Impossible States Impossible)
```swift
enum ConnectionStatus {
    case disconnected
    case connecting(attempt: Int)
    case connected(since: Date)
    case reconnecting(attempt: Int, lastError: Error?)
}
// Can only be in ONE state at a time
```

### Pure Reducer (Testable Core)
```swift
func clientReducer(
    state: inout ClientState,
    action: ClientAction
) -> [ClientEffect]
// No side effects, no async - just state transitions
```

### Effect Descriptions (Not Execution)
```swift
enum ClientEffect {
    case openConnection(URL, token: String?)
    case sendMessage(SockitMessage)
    case scheduleTimeout(requestId: String, delay: TimeInterval)
    case emit(ClientMessage)
}
// Effects describe what to do, actor executes them
```

## Testing

Run tests:
```bash
cd sockit
swift test
```

Reducer tests require no mocking - they're pure functions:
```swift
@Test func connectFromDisconnected() {
    var state = ClientState()
    let effects = clientReducer(state: &state, action: .connect(config))

    #expect(state.connection == .connecting(attempt: 1))
    #expect(effects.contains(.openConnection(url, token: nil)))
}
```

## Commands

```bash
swift build              # Build
swift test               # Run tests
swift test --parallel    # Run tests in parallel
swift test --filter Performance  # Run benchmarks
```

## Performance

Benchmarks on Apple Silicon:
- **Message Creation**: ~1.4M msgs/sec
- **JSON Encoding**: ~228K msgs/sec
- **JSON Decoding**: ~106K msgs/sec (main bottleneck)

Practical: Single connection can handle ~100K msgs/sec. More than sufficient for real-world use.

**Tip**: Use typed commands (`SockitCommand`) for single-parse decoding instead of double-parsing through intermediate types.

## Design Decisions

1. **End-to-end Codable** - No intermediate types (AnyCodable, JSONValue, envelopes). Typed DTOs encode/decode directly
2. **Simple JSON protocol** - Not Phoenix V2, easier to debug and implement
3. **Pure reducer** - All business logic testable without mocking
4. **Actor isolation** - Thread-safe without manual locking
5. **NSLock for transport** - Cross-platform (Linux + Apple)
6. **Token as query param** - iOS `URLSessionWebSocketTask` doesn't reliably forward custom headers, so auth token is sent as `?token=` query parameter

## Server Typed Handlers

The server uses `SockitHandler` protocol for type-safe request/response handling:

```swift
// Handler with typed request payload
public protocol SockitHandler: Sendable {
    associatedtype Request: Decodable & Sendable
    associatedtype Response: Encodable & Sendable
    static var event: String { get }
    func handle(request: Request, context: HandlerContext) async throws -> Response
}

// Handler with no request payload
public protocol SockitHandlerNoPayload: Sendable {
    associatedtype Response: Encodable & Sendable
    static var event: String { get }
    func handle(context: HandlerContext) async throws -> Response
}
```

Both client (`SockitCommand`) and server (`SockitHandler`) use the same DTOs from shared contracts - true end-to-end type safety.

## Typed Command Protocol

For type-safe request/response handling, use `SockitCommand`:

```swift
// Define command with typed response
protocol SockitCommand: Sendable {
    associatedtype Response: Decodable & Sendable
    static var event: String { get }
}

// For commands with payload
protocol SockitCommandWithPayload: SockitCommand, Encodable {}

// Usage
struct GetProfile: SockitCommand {
    typealias Response = ProfileResponse
    static let event = "profile.get"
}

let response = try await client.send(GetProfile())
// response is ProfileResponse, fully typed
```

### Raw Types (Deferred Decoding)

For performance-critical paths, raw types defer JSON parsing:

| Type | Purpose |
|------|---------|
| `RawPushEvent` | Push event with `payloadData: Data` for deferred decode |
| `RawResponse` | Response with `dataPayload: Data` for deferred decode |
| `RawPayload` | Wrapper with `decode<T>()` method |

```swift
// Decode only when needed
case .rawPushEvent(let push):
    if push.event == "home.today_updated" {
        let payload = try push.decodePayload(TodayPayload.self)
    }
```

## Important Notes

- **Token Refresh**: When refreshing tokens while connected, you must disconnect first, wait for disconnected state, then reconnect. The client ignores `connect()` calls unless in disconnected state.
- **Server must support query param auth**: The server should check both `Authorization: Bearer` header AND `?token=` query parameter for WebSocket auth.
