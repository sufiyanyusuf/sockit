import Foundation
import SockitCore

/// Manages all active WebSocket connections
public actor ConnectionManager {
    private var connections: [UUID: Connection] = [:]
    private var userConnections: [UUID: Set<UUID>] = [:]  // userId -> connectionIds

    public init() {}

    /// Register a new connection
    public func register(_ connection: Connection, userId: UUID?) {
        connections[connection.id] = connection
        if let userId = userId {
            userConnections[userId, default: []].insert(connection.id)
        }
    }

    /// Unregister a connection
    public func unregister(_ connectionId: UUID, userId: UUID?) {
        connections.removeValue(forKey: connectionId)
        if let userId = userId {
            userConnections[userId]?.remove(connectionId)
            if userConnections[userId]?.isEmpty == true {
                userConnections.removeValue(forKey: userId)
            }
        }
    }

    /// Get a connection by ID
    public func connection(for id: UUID) -> Connection? {
        connections[id]
    }

    /// Get all connection IDs
    public var allConnectionIds: [UUID] {
        Array(connections.keys)
    }

    /// Broadcast a message to all connections (no payload)
    public func broadcast(event: String) async {
        for connection in connections.values {
            await connection.push(event: event)
        }
    }

    /// Broadcast a message with typed payload to all connections
    public func broadcast<T: Encodable & Sendable>(event: String, payload: T) async throws {
        for connection in connections.values {
            try await connection.push(event: event, payload: payload)
        }
    }

    /// Send to a specific connection (no payload)
    public func send(to connectionId: UUID, event: String) async {
        await connections[connectionId]?.push(event: event)
    }

    /// Send to a specific connection with typed payload
    public func send<T: Encodable & Sendable>(to connectionId: UUID, event: String, payload: T)
        async throws
    {
        try await connections[connectionId]?.push(event: event, payload: payload)
    }

    /// Send to all connections for a specific user (no payload)
    public func sendToUser(_ userId: UUID, event: String) async {
        guard let connectionIds = userConnections[userId] else { return }
        for connectionId in connectionIds {
            await connections[connectionId]?.push(event: event)
        }
    }

    /// Send to all connections for a specific user with typed payload
    public func sendToUser<T: Encodable & Sendable>(_ userId: UUID, event: String, payload: T)
        async throws
    {
        guard let connectionIds = userConnections[userId] else { return }
        for connectionId in connectionIds {
            try await connections[connectionId]?.push(event: event, payload: payload)
        }
    }

    /// Check if a user has any active connections
    public func isUserConnected(_ userId: UUID) -> Bool {
        !(userConnections[userId]?.isEmpty ?? true)
    }
}
