import Foundation
import SockitCore

/// State for a single WebSocket connection
public struct ConnectionState: Sendable, Equatable {
    /// Unique connection identifier
    public let id: UUID

    /// Authenticated user ID (if any)
    public var userId: UUID?

    /// Channels this connection has joined
    public var channels: Set<String> = []

    /// Pending requests awaiting response
    public var pendingResponses: [String: PendingResponse] = [:]

    /// Connection metadata
    public var metadata: [String: String] = [:]

    /// Number of missed heartbeats
    public var missedHeartbeats: Int = 0

    public init(id: UUID = UUID(), userId: UUID? = nil) {
        self.id = id
        self.userId = userId
    }
}

/// Tracks a pending response to be sent
public struct PendingResponse: Sendable, Equatable {
    public let requestId: String
    public let event: String
    public let channel: String?
    public let receivedAt: Date

    public init(requestId: String, event: String, channel: String?, receivedAt: Date = Date()) {
        self.requestId = requestId
        self.event = event
        self.channel = channel
        self.receivedAt = receivedAt
    }
}
