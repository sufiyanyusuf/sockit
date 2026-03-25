import Foundation
import SockitCore

/// All possible actions that can be dispatched to the client reducer.
/// Exhaustive enum ensures all cases are handled.
public enum ClientAction: Sendable {
    // MARK: - External Actions (from public API)

    /// Connect to the server
    case connect(ClientConfig)

    /// Disconnect from the server
    case disconnect(DisconnectReason)

    /// Join a channel (with optional typed join parameters as Data)
    case joinChannel(String, Data)

    /// Leave a channel
    case leaveChannel(String)

    /// Send a request (type-erased for reducer use)
    case send(SendableRequest)

    // MARK: - Internal Actions (from transport/timers)

    /// Transport connected successfully
    case transportConnected

    /// Transport disconnected
    case transportDisconnected(Error?)

    /// Received a message from transport
    case transportMessageReceived(SockitMessage)

    /// Heartbeat timer tick
    case heartbeatTick

    /// Request timed out
    case requestTimeout(String)

    /// Reconnect timer fired
    case reconnect

    /// Channel joined successfully
    case channelJoined(String)

    /// Channel left
    case channelLeft(String)

    /// Channel error
    case channelError(String, String, String) // channel, code, message
}
