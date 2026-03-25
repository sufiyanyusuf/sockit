import Foundation
import SockitCore

/// Effects produced by the client reducer.
/// These are descriptions of side effects, not the effects themselves.
public enum ClientEffect: Sendable, Equatable {
    // MARK: - Transport Effects

    /// Open a connection to the given URL
    case openConnection(URL, token: String?)

    /// Close the connection
    case closeConnection(code: UInt16, reason: String)

    /// Send a message over the transport
    case sendMessage(SockitMessage)

    // MARK: - Timer Effects

    /// Start the heartbeat timer
    case startHeartbeat(interval: TimeInterval)

    /// Stop the heartbeat timer
    case stopHeartbeat

    /// Schedule a reconnect after delay
    case scheduleReconnect(delay: TimeInterval)

    /// Cancel pending reconnect
    case cancelReconnect

    /// Schedule a request timeout
    case scheduleRequestTimeout(requestId: String, delay: TimeInterval)

    /// Cancel a request timeout
    case cancelRequestTimeout(requestId: String)

    // MARK: - Output Effects

    /// Emit a message to the public stream
    case emit(ClientMessage)
}

// MARK: - Client Message (Public Stream)

/// Messages emitted to the public message stream
public enum ClientMessage: Sendable, Equatable {
    /// Connection state changed
    case connectionStateChanged(ConnectionStateChange)

    /// Channel state changed
    case channelStateChanged(String, ChannelStateChange)

    /// Received a response to a request
    case response(Response)

    /// Received a server push event (legacy - uses AnyCodable)
    case pushEvent(PushEvent)

    /// Received a server push event with raw payload data (preferred - no AnyCodable)
    case rawPushEvent(RawPushEvent)

    /// Request timed out
    case requestTimeout(requestId: String)

    public static func == (lhs: ClientMessage, rhs: ClientMessage) -> Bool {
        switch (lhs, rhs) {
        case let (.connectionStateChanged(a), .connectionStateChanged(b)):
            return a == b
        case let (.channelStateChanged(c1, s1), .channelStateChanged(c2, s2)):
            return c1 == c2 && s1 == s2
        case let (.response(r1), .response(r2)):
            return r1 == r2
        case let (.pushEvent(p1), .pushEvent(p2)):
            return p1 == p2
        case let (.rawPushEvent(p1), .rawPushEvent(p2)):
            return p1 == p2
        case let (.requestTimeout(id1), .requestTimeout(id2)):
            return id1 == id2
        default:
            return false
        }
    }
}

/// Connection state change events
public enum ConnectionStateChange: Sendable, Equatable, Codable {
    case connecting
    case connected
    case reconnecting(attempt: Int)
    case disconnected
}

/// Channel state change events
public enum ChannelStateChange: Sendable, Equatable, Codable {
    case joining
    case joined
    case leaving
    case left
    case error(code: String, message: String)
}
