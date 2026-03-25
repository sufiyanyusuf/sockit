import Foundation
import SockitCore

/// Pure reducer for server-side connection state
public func connectionReducer(
    state: inout ConnectionState,
    action: ServerAction
) -> [ServerEffect] {
    switch action {
    case let .connected(userId):
        return handleConnected(state: &state, userId: userId)

    case .disconnected:
        return handleDisconnected(state: &state)

    case let .messageReceived(message):
        return handleMessageReceived(state: &state, message: message)

    case let .sendResponse(requestId, status, data, error):
        return handleSendResponse(state: &state, requestId: requestId, status: status, data: data, error: error)

    case let .sendPush(event, payloadData, channel):
        return handleSendPush(event: event, payloadData: payloadData, channel: channel)

    case let .joinChannel(channel, payloadData, requestId):
        return handleJoinChannel(state: &state, channel: channel, payloadData: payloadData, requestId: requestId)

    case let .leaveChannel(channel):
        return handleLeaveChannel(state: &state, channel: channel)

    case let .channelJoined(channel):
        return handleChannelJoined(state: &state, channel: channel)

    case let .channelJoinFailed(channel, code, message):
        return handleChannelJoinFailed(channel: channel, code: code, message: message)

    case .heartbeatReceived:
        return handleHeartbeatReceived(state: &state)

    case .heartbeatTick:
        return handleHeartbeatTick(state: &state)
    }
}

// MARK: - Handlers

private func handleConnected(state: inout ConnectionState, userId: UUID?) -> [ServerEffect] {
    state.userId = userId
    state.missedHeartbeats = 0
    return [.onConnect(userId: userId)]
}

private func handleDisconnected(state: inout ConnectionState) -> [ServerEffect] {
    let channels = state.channels
    state.channels.removeAll()

    var effects: [ServerEffect] = channels.map { .unsubscribeFromChannel($0) }
    effects.append(.onDisconnect)
    return effects
}

private func handleMessageReceived(state: inout ConnectionState, message: SockitMessage) -> [ServerEffect] {
    // Handle heartbeat
    if message.event == "heartbeat" {
        state.missedHeartbeats = 0
        let response = SockitMessage(event: "heartbeat")
        return [.sendMessage(response)]
    }

    // Handle channel join
    if message.event == "channel.join", let channel = message.channel, let requestId = message.requestId {
        return [.validateJoin(channel: channel, payloadData: message.payloadData, requestId: requestId)]
    }

    // Handle channel leave
    if message.event == "channel.leave", let channel = message.channel {
        return handleLeaveChannel(state: &state, channel: channel)
    }

    // Route to handler
    return [.routeEvent(
        event: message.event,
        payloadData: message.payloadData,
        requestId: message.requestId,
        channel: message.channel
    )]
}

private func handleSendResponse(
    state: inout ConnectionState,
    requestId: String,
    status: ResponseStatus,
    data: Data,
    error: ResponseError?
) -> [ServerEffect] {
    let pending = state.pendingResponses[requestId]
    state.pendingResponses.removeValue(forKey: requestId)

    // For errors, encode the error payload
    // For success, data is already the encoded typed response - send directly
    let payloadData: Data
    if let error = error {
        payloadData = (try? JSONEncoder().encode(ErrorPayload(error: error))) ?? Data("{}".utf8)
    } else {
        payloadData = data
    }

    let message = SockitMessage(
        event: pending?.event ?? "response",
        payloadData: payloadData,
        requestId: requestId,
        channel: pending?.channel,
        status: status
    )

    return [.sendMessage(message)]
}

private func handleSendPush(
    event: String,
    payloadData: Data,
    channel: String?
) -> [ServerEffect] {
    let message = SockitMessage(
        event: event,
        payloadData: payloadData,
        requestId: nil,
        channel: channel
    )
    return [.sendMessage(message)]
}

private func handleJoinChannel(
    state: inout ConnectionState,
    channel: String,
    payloadData: Data,
    requestId: String
) -> [ServerEffect] {
    // Already joined
    if state.channels.contains(channel) {
        guard let responseData = try? JSONEncoder().encode(StatusResponse(status: "ok")) else {
            return []
        }
        let message = SockitMessage(
            event: "channel.join",
            payloadData: responseData,
            requestId: requestId,
            channel: channel
        )
        return [.sendMessage(message)]
    }

    return [.validateJoin(channel: channel, payloadData: payloadData, requestId: requestId)]
}

private func handleLeaveChannel(state: inout ConnectionState, channel: String) -> [ServerEffect] {
    guard state.channels.contains(channel) else {
        return []
    }

    state.channels.remove(channel)

    guard let responseData = try? JSONEncoder().encode(StatusResponse(status: "ok")) else {
        return [.unsubscribeFromChannel(channel)]
    }
    let message = SockitMessage(
        event: "channel.leave",
        payloadData: responseData,
        requestId: nil,
        channel: channel
    )
    return [
        .unsubscribeFromChannel(channel),
        .sendMessage(message)
    ]
}

private func handleChannelJoined(state: inout ConnectionState, channel: String) -> [ServerEffect] {
    state.channels.insert(channel)
    return [.subscribeToChannel(channel)]
}

private func handleChannelJoinFailed(
    channel: String,
    code: String,
    message: String
) -> [ServerEffect] {
    let errorPayload = ErrorDetail(code: code, message: message)
    guard let payloadData = try? JSONEncoder().encode(["error": errorPayload]) else {
        return []
    }
    let msg = SockitMessage(
        event: "channel.join",
        payloadData: payloadData,
        requestId: nil,
        channel: channel
    )
    return [.sendMessage(msg)]
}

private func handleHeartbeatReceived(state: inout ConnectionState) -> [ServerEffect] {
    state.missedHeartbeats = 0
    return []
}

private func handleHeartbeatTick(state: inout ConnectionState) -> [ServerEffect] {
    state.missedHeartbeats += 1

    if state.missedHeartbeats > 3 {
        return [.closeConnection(code: 1002, reason: "Heartbeat timeout")]
    }

    return []
}

// MARK: - Internal Types

private struct StatusResponse: Encodable {
    let status: String
}

private struct ErrorPayload: Encodable {
    let error: ErrorDetail

    init(error: ResponseError) {
        self.error = ErrorDetail(code: error.code, message: error.message)
    }
}

private struct ErrorDetail: Encodable {
    let code: String
    let message: String
}
