import Foundation
import SockitCore

/// Effects produced by the server connection reducer
public enum ServerEffect: Sendable, Equatable {
    // MARK: - Message Effects

    /// Send a message to the client
    case sendMessage(SockitMessage)

    /// Close the connection
    case closeConnection(code: UInt16, reason: String)

    // MARK: - Routing Effects

    /// Route an event to a handler (payloadData is raw JSON)
    case routeEvent(event: String, payloadData: Data, requestId: String?, channel: String?)

    /// Validate channel join (payloadData is raw JSON)
    case validateJoin(channel: String, payloadData: Data, requestId: String)

    // MARK: - Channel Effects

    /// Subscribe connection to a channel
    case subscribeToChannel(String)

    /// Unsubscribe connection from a channel
    case unsubscribeFromChannel(String)

    // MARK: - Lifecycle Effects

    /// Connection established - perform any setup
    case onConnect(userId: UUID?)

    /// Connection closed - perform any cleanup
    case onDisconnect
}
