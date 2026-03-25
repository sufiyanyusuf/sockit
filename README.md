# Sockit

A Swift WebSocket library with shared types between client and server, and a pure functional core.

![Swift 6](https://img.shields.io/badge/Swift-6.0-orange)
![Platforms](https://img.shields.io/badge/Platforms-iOS%2017%2B%20%7C%20macOS%2014%2B%20%7C%20Linux-blue)
![License](https://img.shields.io/badge/License-MIT-green)

Sockit gives you typed request/response over WebSockets -- define a command once, use the same DTOs on your iOS app and Vapor server. All the connection logic (reconnection, heartbeats, channels, timeouts) is separated from the network layer, so you can test your entire WebSocket state machine by calling a function and checking the result. No server, no connection, no async.

```swift
struct GetProfile: SockitCommand {
    typealias Response = ProfileDTO
    static let event = "profile.get"
}

let profile = try await client.send(GetProfile()) // Typed. Done.
```

## Why Sockit?

🔧 **Raw pipe** — `URLSessionWebSocketTask` has no typing, correlation, or timeouts.
→ Sockit gives you end-to-end typed commands. Same DTOs on client and server.

🧪 **Untestable** — WebSocket logic is coupled to the connection.
→ All state logic is a plain function. Test it by calling it. No server needed.

🔄 **Reconnection** — Backoff, heartbeats, channel re-joins — lots of edge cases.
→ Built in, configurable, and tested. You don't write this code.

⚡ **Concurrency** — Swift 6 `Sendable` compliance is painful to retrofit.
→ Actors throughout, zero warnings. Designed for strict concurrency from day one.

🔑 **Auth headers** — iOS drops them silently on WebSocket upgrade.
→ Token sent as query param automatically. Server checks both.

## Table of Contents

- [Why Sockit?](#why-sockit)
- [Key Concepts](#key-concepts)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Client API](#client-api)
- [Server API](#server-api)
- [Package Structure](#package-structure)
- [Testing](#testing)
- [Performance](#performance)
- [Contributing](#contributing)
- [License](#license)

## Key Concepts

### How it works

```
+-------------------------------------------+
|  Public API (Actor)                       |
|  Client / Connection                      |
+-------------------------------------------+
                    |
                    v
+-------------------------------------------+
|  Reducer                                  |
|  (State, Action) -> [Effect]              |
|  All logic lives here. No side effects.   |
+-------------------------------------------+
                    |
                    v
+-------------------------------------------+
|  Transport                                |
|  URLSession (Apple) / NIO (Linux)         |
+-------------------------------------------+
```

When the client receives a message or the user takes an action, it goes to the **reducer** -- a plain function that takes the current state, returns what should happen next (as a list of effects). The actor layer then executes those effects (open a connection, send a message, emit an event).

Because the reducer is just a function, you can test every state transition by calling it directly:

```swift
var state = ClientState()
let effects = clientReducer(state: &state, action: .connect(config))

// Assert state changed
#expect(state.connection == .connecting(attempt: 1))
// Assert what effects were requested
#expect(effects.contains(.openConnection(url, token: "...")))
```

No mocks, no network, no async. Just input and output.

### State machine

Connection and channel states are enums -- you can only be in one state at a time, and invalid transitions are caught at compile time:

```swift
enum ConnectionStatus {
    case disconnected
    case connecting(attempt: Int)
    case connected(since: Date)
    case reconnecting(attempt: Int, lastError: Error?)
}

enum ChannelState {
    case joining(joinRef: String)
    case joined(joinRef: String)
    case leaving
    case left
    case error(code: String, message: String)
}
```

### Wire protocol

Simple JSON. The `payload` field IS your typed DTO -- no envelope wrapping, no intermediate types.

```json
{
  "event": "profile.get",
  "payload": { "theme": "dark" },
  "requestId": "550e8400-e29b-41d4-a716-446655440000",
  "channel": "user:123",
  "status": "ok"
}
```

| Field       | Required | Description                           |
|-------------|----------|---------------------------------------|
| `event`     | Yes      | Event name (e.g. `"profile.get"`)     |
| `payload`   | No       | Typed DTO, encoded directly           |
| `requestId` | No       | UUID for request/response correlation |
| `channel`   | No       | Channel name for pub/sub              |
| `status`    | No       | `"ok"` or `"error"` (responses only)  |

Error responses include an error object in the payload:

```json
{
  "event": "chat.send",
  "requestId": "...",
  "status": "error",
  "payload": {
    "error": { "code": "not_authorized", "message": "Not a member of this channel" }
  }
}
```

### Transport

On Apple platforms, `SockitClient` uses `URLSessionWebSocketTask`. On Linux, it auto-links a SwiftNIO-based transport via conditional dependency. `Client()` works on all platforms with no configuration.

You can also provide your own:

```swift
let client = Client(transportFactory: { MyCustomTransport() })
```

The `TransportProtocol` in `SockitCore` defines the contract.

## Requirements

| Dependency | Version |
|-----------|---------|
| Swift     | 6.0+    |
| iOS       | 17+     |
| macOS     | 14+     |
| Linux     | Swift 6.0+ toolchain |
| Vapor     | 4.99+ (server only) |

## Installation

Add Sockit to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/sufiyanyusuf/sockit.git", from: "1.0.0"),
]
```

Then add the target you need:

```swift
// iOS/macOS client
.target(name: "MyApp", dependencies: [
    .product(name: "SockitClient", package: "sockit"),
])

// Vapor server
.target(name: "MyServer", dependencies: [
    .product(name: "SockitServer", package: "sockit"),
])

// Shared types only
.target(name: "SharedContracts", dependencies: [
    .product(name: "SockitCore", package: "sockit"),
])
```

## Quick Start

### Client

```swift
import SockitClient

let client = Client()

try await client.connect(config: ClientConfig(
    url: URL(string: "wss://api.example.com/socket")!,
    token: "auth-token"
))

// Typed command -- send and await a decoded response
struct GetProfile: SockitCommand {
    typealias Response = ProfileDTO
    static let event = "profile.get"
}
let profile = try await client.send(GetProfile())

// Listen for events
for await message in client.messages {
    switch message {
    case .response(let response):
        handleResponse(response)
    case .rawPushEvent(let push):
        if push.event == "chat.message" {
            let msg = try push.decodePayload(ChatMessage.self)
            displayMessage(msg)
        }
    case .connectionStateChanged(let change):
        updateUI(for: change) // .connecting, .connected, .reconnecting(attempt:), .disconnected
    default:
        break
    }
}
```

### Server (Vapor)

```swift
import Vapor
import SockitServer

struct GetProfileHandler: SockitHandlerNoPayload {
    typealias Response = ProfileDTO
    static let event = "profile.get"

    func handle(context: HandlerContext) async throws -> Response {
        try await fetchProfile(userId: context.userId!)
    }
}

func routes(_ app: Application) async throws {
    let router = TypedRouter()
    await router.register(GetProfileHandler())

    app.sockit(path: "socket", router: router) { req in
        try await authenticateToken(req) // Returns UUID?
    }
}
```

## Client API

### Connecting

```swift
let client = Client()

// All parameters except url are optional
try await client.connect(config: ClientConfig(
    url: URL(string: "wss://api.example.com/socket")!,
    token: "jwt-token",                    // Sent as ?token= query param
    heartbeatInterval: 30.0,               // Default: 30s
    reconnectStrategy: .exponentialBackoff( // Default
        baseDelay: 1.0,
        maxDelay: 30.0,
        maxAttempts: 5
    ),
    defaultTimeout: 30.0                   // Request timeout
))

await client.disconnect()
```

**Reconnection strategies:**

```swift
.exponentialBackoff(baseDelay: 1.0, maxDelay: 30.0, maxAttempts: 5) // Default
.linear(delay: 2.0, maxAttempts: 10)
.none
```

### Typed Commands (Preferred)

```swift
// Command with no payload
struct GetProfile: SockitCommand {
    typealias Response = ProfileDTO
    static let event = "profile.get"
}
let profile = try await client.send(GetProfile())

// Command with payload
struct UpdateSettings: SockitCommandWithPayload {
    typealias Response = SettingsDTO
    static let event = "settings.update"

    let theme: String
    let notifications: Bool
}
let settings = try await client.send(UpdateSettings(theme: "dark", notifications: true))

// Command scoped to a channel
struct SendMessage: SockitCommandWithPayload {
    typealias Response = MessageDTO
    static let event = "chat.send"
    var channel: String? { "room:general" }

    let text: String
}
```

### Channels

```swift
await client.join("room:general")
await client.join("room:general", payload: JoinParams(role: "member")) // With typed payload
await client.leave("room:general")
```

### Listening for Messages

```swift
for await message in client.messages {
    switch message {
    case .connectionStateChanged(let change):
        // change: .connecting, .connected, .reconnecting(attempt:), .disconnected
        break
    case .channelStateChanged(let channel, let change):
        // channel: "room:general"
        // change: .joining, .joined, .leaving, .left, .error(code:, message:)
        break
    case .response(let response):
        // Response to a fire-and-forget SendableRequest
        break
    case .pushEvent(let push):
        // Server push event (fully decoded)
        break
    case .rawPushEvent(let push):
        // Server push event with deferred payload decoding
        let payload = try push.decodePayload(MyPayload.self)
        break
    case .requestTimeout(let requestId):
        // A fire-and-forget request timed out
        break
    }
}
```

### Typed Push Events

Route server push events to typed handlers:

```swift
struct ChatMessageEvent: SockitPushEvent {
    typealias Payload = ChatMessage
    static let event = "chat.message"
}

let registry = PushEventRegistry()
await registry.on(ChatMessageEvent.self) { chatMessage in
    // chatMessage is already decoded as ChatMessage
    displayInChat(chatMessage)
}

// Route incoming push events through the registry
for await message in client.messages {
    if case .rawPushEvent(let push) = message {
        await registry.route(push)
    }
}
```

### Raw Types (Deferred Decoding)

For high-throughput scenarios, decode only the events you need:

```swift
case .rawPushEvent(let push):
    switch push.event {
    case "chat.message":
        let msg = try push.decodePayload(ChatMessage.self)
    case "presence.update":
        let update = try push.decodePayload(PresenceUpdate.self)
    default:
        break // No JSON parsing cost for unhandled events
    }
```

| Type           | Purpose                                                |
|----------------|--------------------------------------------------------|
| `RawPushEvent` | Push event with `payloadData: Data` for deferred decode |
| `RawResponse`  | Response with `dataPayload: Data` for deferred decode   |
| `RawPayload`   | Wrapper with `decode<T>()` method                       |

## Server API

### Handlers

```swift
// Handler with typed request payload
struct SendMessageHandler: SockitHandler {
    typealias Request = SendMessageRequest  // Decodable & Sendable
    typealias Response = SendMessageResponse // Encodable & Sendable
    static let event = "chat.send"

    func handle(request: Request, context: HandlerContext) async throws -> Response {
        let msg = try await saveMessage(from: context.userId!, text: request.text)
        return SendMessageResponse(id: msg.id, sentAt: msg.createdAt)
    }
}

// Handler with no request payload
struct GetTodayHandler: SockitHandlerNoPayload {
    typealias Response = TodaySnapshotDTO
    static let event = "home.get_today"

    func handle(context: HandlerContext) async throws -> Response {
        try await fetchTodaySnapshot(userId: context.userId!)
    }
}
```

`HandlerContext` provides:
- `connection: Connection` -- the WebSocket connection actor
- `userId: UUID?` -- from the authenticate closure

### Routing

```swift
let router = TypedRouter()
await router.register(SendMessageHandler())
await router.register(GetTodayHandler())

app.sockit(path: "socket", router: router) { req in
    // Extract user ID from token -- supports both query param and header
    if let token = req.query[String.self, at: "token"] {
        return try await validateJWT(token)
    }
    guard let bearer = req.headers.bearerAuthorization else { return nil }
    return try await validateJWT(bearer.token)
}
```

### Push Events (Server to Client)

`app.connectionManager` and `app.channelRegistry` are available anywhere in your Vapor app:

```swift
// Push to a specific connection (e.g. inside a handler)
try await context.connection.push(event: "chat.message", payload: chatMessage, channel: "room:general")
await context.connection.push(event: "typing.started", channel: "room:general") // No payload

// Push to a specific user (all their connections) -- from anywhere with access to app
try await app.connectionManager.sendToUser(userId, event: "notification", payload: notification)
await app.connectionManager.sendToUser(userId, event: "refresh")

// Push to all subscribers of a channel
let members = await app.channelRegistry.subscribers(for: "room:general")
for connectionId in members {
    if let conn = await app.connectionManager.connection(for: connectionId) {
        try await conn.push(event: "chat.message", payload: chatMessage, channel: "room:general")
    }
}

// Broadcast to all connections
try await app.connectionManager.broadcast(event: "system.maintenance", payload: maintenanceInfo)
```

### Shared DTOs

Define request/response types in a shared module imported by both client and server:

```swift
// SharedContracts/Sources/Messages.swift
import Foundation

struct SendMessageRequest: Codable, Sendable {
    let text: String
    let channel: String
}

struct SendMessageResponse: Codable, Sendable {
    let id: UUID
    let sentAt: Date
}
```

The same types are used by `SockitCommand` on the client and `SockitHandler` on the server -- true end-to-end type safety with zero duplication.

## Package Structure

| Module               | Depends on             | Description                                       |
|----------------------|------------------------|---------------------------------------------------|
| `SockitCore`         | Foundation             | Shared types, wire protocol, transport abstraction |
| `SockitClient`       | SockitCore             | WebSocket client (URLSession on Apple, NIO on Linux) |
| `SockitNIOTransport` | SockitCore, WebSocketKit | NIO transport, auto-linked on Linux              |
| `SockitServer`       | SockitCore, Vapor      | Vapor WebSocket server with typed routing         |

```
Sources/
  SockitCore/            -- Shared types, wire protocol, TransportProtocol
  SockitClient/          -- Client actor, reducer, URLSession transport
  SockitNIOTransport/    -- NIO transport (conditionally linked on Linux)
  SockitServer/          -- Connection, ConnectionManager, ChannelRegistry, TypedRouter
```

## Testing

```bash
swift build    # Build all targets
swift test     # Run all 157 tests
```

Reducer tests are plain functions -- no server or connection needed:

```swift
@Test func connectFromDisconnected() {
    var state = ClientState()
    let effects = clientReducer(state: &state, action: .connect(config))

    #expect(state.connection == .connecting(attempt: 1))
    #expect(effects.contains(.openConnection(url, token: nil)))
}
```

Integration tests verify both transports against a real WebSocket server:

```swift
@Test func fullLifecycle() async throws {
    try await withEchoServer { port in
        let client = Client()
        try await client.connect(config: ClientConfig(
            url: URL(string: "ws://127.0.0.1:\(port)")!,
            reconnectStrategy: .none
        ))
        await client.send(SendableRequest(event: "echo"))
        await client.disconnect()
    }
}
```

## Performance

Benchmarks on Apple Silicon:

| Operation        | Throughput     |
|------------------|---------------|
| Message creation | ~570K msgs/sec |
| JSON encoding    | ~46K msgs/sec  |
| JSON decoding    | ~45K msgs/sec  |

Use typed commands (`SockitCommand`) for single-parse decoding rather than double-parsing through intermediate types.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for build instructions, test guidelines, and PR process.

## License

MIT. See [LICENSE](LICENSE).
