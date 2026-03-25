import Foundation
import SockitCore

/// Actions for the server connection reducer
public enum ServerAction: Sendable {
    // MARK: - Connection Lifecycle

    /// Client connected
    case connected(userId: UUID?)

    /// Client disconnected
    case disconnected

    // MARK: - Message Handling

    /// Received a message from the client
    case messageReceived(SockitMessage)

    /// Send a response to a request (data is pre-encoded)
    case sendResponse(requestId: String, status: ResponseStatus, data: Data, error: ResponseError?)

    /// Send a push event to the client (payload is pre-encoded)
    case sendPush(event: String, payloadData: Data, channel: String?)

    // MARK: - Channel Management

    /// Client wants to join a channel
    case joinChannel(String, payloadData: Data, requestId: String)

    /// Client wants to leave a channel
    case leaveChannel(String)

    /// Channel join succeeded
    case channelJoined(String)

    /// Channel join failed
    case channelJoinFailed(String, code: String, message: String)

    // MARK: - Heartbeat

    /// Heartbeat received from client
    case heartbeatReceived

    /// Heartbeat timer tick (server-side timeout check)
    case heartbeatTick
}
