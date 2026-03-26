import Foundation
import SockitCore
import Vapor

// MARK: - Application Storage

private struct ConnectionManagerKey: StorageKey {
    typealias Value = ConnectionManager
}

private struct ChannelRegistryKey: StorageKey {
    typealias Value = ChannelRegistry
}

extension Application {
    /// Global connection manager for WebSocket connections.
    /// Automatically created on first access. Use this to push events, broadcast,
    /// and track connections from anywhere in your Vapor app.
    public var connectionManager: ConnectionManager {
        get {
            if let existing = storage[ConnectionManagerKey.self] {
                return existing
            }
            let manager = ConnectionManager()
            storage[ConnectionManagerKey.self] = manager
            return manager
        }
        set {
            storage[ConnectionManagerKey.self] = newValue
        }
    }

    /// Global channel registry for pub/sub.
    /// Automatically created on first access.
    public var channelRegistry: ChannelRegistry {
        get {
            if let existing = storage[ChannelRegistryKey.self] {
                return existing
            }
            let registry = ChannelRegistry()
            storage[ChannelRegistryKey.self] = registry
            return registry
        }
        set {
            storage[ChannelRegistryKey.self] = newValue
        }
    }
}

// MARK: - Message Buffer

/// Buffers messages received before the connection is fully established.
/// This prevents message loss during authentication.
actor MessageBuffer {
    private var messages: [String] = []
    private var isReady = false
    private var connection: Connection?

    func buffer(_ text: String) async {
        if isReady, let connection = connection {
            await connection.handleBufferedText(text)
        } else {
            messages.append(text)
        }
    }

    func setReady(connection: Connection) async {
        self.connection = connection
        self.isReady = true
        for text in messages {
            await connection.handleBufferedText(text)
        }
        messages.removeAll()
    }
}

// MARK: - Vapor Integration

extension Application {
    /// Configure a Sockit WebSocket endpoint with TypedRouter.
    ///
    /// Uses `app.connectionManager` and `app.channelRegistry` which are accessible
    /// anywhere in your Vapor app for pushing events, broadcasting, and managing channels.
    ///
    /// Example:
    /// ```swift
    /// app.sockit(path: "socket", router: router) { req in
    ///     try await authenticateToken(req) // Returns UUID?
    /// }
    ///
    /// // Later, anywhere in your app:
    /// try await app.connectionManager.sendToUser(userId, event: "update", payload: data)
    /// let members = await app.channelRegistry.subscribers(for: "room:general")
    /// ```
    public func sockit(
        path: PathComponent...,
        router: TypedRouter,
        authenticate: @Sendable @escaping (Vapor.Request) async throws -> UUID? = { _ in nil },
        joinValidator: JoinValidator? = nil
    ) {
        let manager = self.connectionManager
        let registry = self.channelRegistry

        webSocket(path) { req, ws in
            // Buffer messages immediately to prevent loss during auth
            let buffer = MessageBuffer()

            ws.onText { _, text in
                Task {
                    await buffer.buffer(text)
                }
            }

            Task {
                // Authenticate (nil userId = anonymous connection)
                let userId = try? await authenticate(req)

                // Create connection
                let connection = Connection(
                    ws: ws,
                    typedRouter: router,
                    channelRegistry: registry,
                    userId: userId,
                    joinValidator: joinValidator
                )

                // Register
                await manager.register(connection, userId: userId)

                // Start handling (skip onText -- buffer handles message routing)
                await connection.start(externalMessageHandling: true)

                // Replay buffered messages
                await buffer.setReady(connection: connection)

                // Wait for close
                _ = try? await ws.onClose.get()

                // Cleanup
                await manager.unregister(connection.id, userId: userId)
                await registry.unsubscribeAll(connectionId: connection.id)
            }
        }
    }
}
