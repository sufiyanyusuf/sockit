import Foundation

/// Configuration for the WebSocket client
public struct ClientConfig: Sendable, Equatable {
    /// WebSocket URL to connect to
    public let url: URL

    /// Optional authentication token
    public let token: String?

    /// Heartbeat interval in seconds (default: 30)
    public let heartbeatInterval: TimeInterval

    /// Strategy for reconnecting after disconnection
    public let reconnectStrategy: ReconnectStrategy

    /// Request timeout in seconds (default: 30)
    public let defaultTimeout: TimeInterval

    public init(
        url: URL,
        token: String? = nil,
        heartbeatInterval: TimeInterval = 30.0,
        reconnectStrategy: ReconnectStrategy = .exponentialBackoff(
            baseDelay: 1.0,
            maxDelay: 30.0,
            maxAttempts: 5
        ),
        defaultTimeout: TimeInterval = 30.0
    ) {
        self.url = url
        self.token = token
        self.heartbeatInterval = heartbeatInterval
        self.reconnectStrategy = reconnectStrategy
        self.defaultTimeout = defaultTimeout
    }
}
