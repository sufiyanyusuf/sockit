import Foundation
import SockitCore

// MARK: - Connection Status (State Machine)

/// Connection status - exactly one state at a time (impossible states impossible)
public enum ConnectionStatus: Sendable, Equatable {
    case disconnected
    case connecting(attempt: Int)
    case connected(since: Date)
    case reconnecting(attempt: Int, lastError: Error?)

    public static func == (lhs: ConnectionStatus, rhs: ConnectionStatus) -> Bool {
        switch (lhs, rhs) {
        case (.disconnected, .disconnected):
            return true
        case let (.connecting(a1), .connecting(a2)):
            return a1 == a2
        case let (.connected(d1), .connected(d2)):
            return d1 == d2
        case let (.reconnecting(a1, _), .reconnecting(a2, _)):
            return a1 == a2
        default:
            return false
        }
    }
}

// MARK: - Channel State (State Machine)

/// Channel state - exactly one state at a time
public enum ChannelState: Sendable, Equatable {
    case joining(joinRef: String)
    case joined(joinRef: String)
    case leaving
    case left
    case error(code: String, message: String)
}

// MARK: - Client State

/// Internal state for the client reducer
public struct ClientState: Sendable, Equatable {
    /// Current connection status
    public var connection: ConnectionStatus = .disconnected

    /// Configuration (set on connect)
    public var config: ClientConfig?

    /// Per-channel state
    public var channels: [String: ChannelState] = [:]

    /// Pending requests awaiting response
    public var pendingRequests: [String: PendingRequest] = [:]

    /// Counter for generating unique refs
    public var refCounter: Int = 0

    /// Number of missed heartbeats
    public var missedHeartbeats: Int = 0

    public init() {}
}

// MARK: - Pending Request

/// Tracks an in-flight request
public struct PendingRequest: Sendable, Equatable {
    public let id: String
    public let event: String
    public let channel: String?
    public let sentAt: Date

    public init(id: String, event: String, channel: String?, sentAt: Date) {
        self.id = id
        self.event = event
        self.channel = channel
        self.sentAt = sentAt
    }
}

// MARK: - Reconnect Strategy

/// Strategy for reconnecting after disconnection
public enum ReconnectStrategy: Sendable, Equatable {
    case exponentialBackoff(baseDelay: TimeInterval, maxDelay: TimeInterval, maxAttempts: Int)
    case linear(delay: TimeInterval, maxAttempts: Int)
    case none

    /// Calculate delay for the given attempt number
    public func delay(forAttempt attempt: Int) -> TimeInterval? {
        switch self {
        case let .exponentialBackoff(baseDelay, maxDelay, maxAttempts):
            guard attempt <= maxAttempts else { return nil }
            let delay = baseDelay * pow(2.0, Double(attempt - 1))
            let jitter = Double.random(in: 0...0.3) * delay
            return min(delay + jitter, maxDelay)

        case let .linear(delay, maxAttempts):
            guard attempt <= maxAttempts else { return nil }
            return delay

        case .none:
            return nil
        }
    }

    /// Maximum number of reconnect attempts
    public var maxAttempts: Int {
        switch self {
        case let .exponentialBackoff(_, _, max):
            return max
        case let .linear(_, max):
            return max
        case .none:
            return 0
        }
    }
}

// MARK: - Disconnect Reason

/// Reason for disconnection
public enum DisconnectReason: Sendable, Equatable {
    case userInitiated
    case transportError(String)
    case heartbeatTimeout
    case serverClosed(code: UInt16, reason: String)
}
