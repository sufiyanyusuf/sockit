import Foundation
import SockitCore

/// Pure reducer function: (state, action) -> [effect]
/// No side effects, no async - just state transitions.
/// This is the testable core of the client.
public func clientReducer(
    state: inout ClientState,
    action: ClientAction
) -> [ClientEffect] {
    switch action {
    case let .connect(config):
        return handleConnect(state: &state, config: config)

    case let .disconnect(reason):
        return handleDisconnect(state: &state, reason: reason)

    case .transportConnected:
        return handleTransportConnected(state: &state)

    case let .transportDisconnected(error):
        return handleTransportDisconnected(state: &state, error: error)

    case let .transportMessageReceived(message):
        return handleMessageReceived(state: &state, message: message)

    case let .joinChannel(channel, payloadData):
        return handleJoinChannel(state: &state, channel: channel, payloadData: payloadData)

    case let .leaveChannel(channel):
        return handleLeaveChannel(state: &state, channel: channel)

    case let .channelJoined(channel):
        return handleChannelJoined(state: &state, channel: channel)

    case let .channelLeft(channel):
        return handleChannelLeft(state: &state, channel: channel)

    case let .channelError(channel, code, message):
        return handleChannelError(state: &state, channel: channel, code: code, message: message)

    case let .send(request):
        return handleSend(state: &state, request: request)

    case let .requestTimeout(requestId):
        return handleRequestTimeout(state: &state, requestId: requestId)

    case .heartbeatTick:
        return handleHeartbeatTick(state: &state)

    case .reconnect:
        return handleReconnect(state: &state)
    }
}

// MARK: - Connection Handlers

private func handleConnect(state: inout ClientState, config: ClientConfig) -> [ClientEffect] {
    // Only connect from disconnected state
    guard case .disconnected = state.connection else {
        return []
    }

    state.connection = .connecting(attempt: 1)
    state.config = config
    state.missedHeartbeats = 0

    return [
        .openConnection(config.url, token: config.token),
        .emit(.connectionStateChanged(.connecting))
    ]
}

private func handleDisconnect(state: inout ClientState, reason: DisconnectReason) -> [ClientEffect] {
    state.connection = .disconnected
    state.channels.removeAll()
    state.pendingRequests.removeAll()

    return [
        .stopHeartbeat,
        .cancelReconnect,
        .closeConnection(code: 1000, reason: reason.description),
        .emit(.connectionStateChanged(.disconnected))
    ]
}

private func handleTransportConnected(state: inout ClientState) -> [ClientEffect] {
    guard case .connecting = state.connection else {
        return []
    }

    state.connection = .connected(since: Date())
    state.missedHeartbeats = 0

    let heartbeatInterval = state.config?.heartbeatInterval ?? 30.0

    return [
        .startHeartbeat(interval: heartbeatInterval),
        .emit(.connectionStateChanged(.connected))
    ]
}

private func handleTransportDisconnected(state: inout ClientState, error: Error?) -> [ClientEffect] {
    // Clear pending requests
    let pendingIds = Array(state.pendingRequests.keys)
    state.pendingRequests.removeAll()

    // Cancel all pending timeouts
    var effects: [ClientEffect] = pendingIds.map { .cancelRequestTimeout(requestId: $0) }
    effects.append(.stopHeartbeat)

    // Check if we should reconnect
    guard let config = state.config,
          let delay = config.reconnectStrategy.delay(forAttempt: 1) else {
        state.connection = .disconnected
        // Clear channels when going to disconnected — stale channel entries
        // cause rejoin to be silently dropped after external reconnect.
        // (When using auto-reconnect, channels persist for sockit's own rejoin logic.)
        state.channels.removeAll()
        effects.append(.emit(.connectionStateChanged(.disconnected)))
        return effects
    }

    state.connection = .reconnecting(attempt: 1, lastError: error)
    effects.append(.scheduleReconnect(delay: delay))
    effects.append(.emit(.connectionStateChanged(.reconnecting(attempt: 1))))

    return effects
}

private func handleReconnect(state: inout ClientState) -> [ClientEffect] {
    guard case let .reconnecting(attempt, _) = state.connection,
          let config = state.config else {
        return []
    }

    let nextAttempt = attempt + 1

    // Check if we've exceeded max attempts
    if nextAttempt > config.reconnectStrategy.maxAttempts {
        state.connection = .disconnected
        return [.emit(.connectionStateChanged(.disconnected))]
    }

    state.connection = .connecting(attempt: nextAttempt)

    return [
        .openConnection(config.url, token: config.token),
        .emit(.connectionStateChanged(.connecting))
    ]
}

// MARK: - Channel Handlers

private func handleJoinChannel(
    state: inout ClientState,
    channel: String,
    payloadData: Data
) -> [ClientEffect] {
    // Must be connected to join
    guard case .connected = state.connection else {
        return []
    }

    // Already joining or joined
    if state.channels[channel] != nil {
        return []
    }

    state.refCounter += 1
    let joinRef = String(state.refCounter)
    state.channels[channel] = .joining(joinRef: joinRef)

    let message = SockitMessage.join(channel: channel, requestId: joinRef)

    return [
        .sendMessage(message),
        .emit(.channelStateChanged(channel, .joining))
    ]
}

private func handleLeaveChannel(state: inout ClientState, channel: String) -> [ClientEffect] {
    guard case .joined = state.channels[channel] else {
        return []
    }

    state.channels[channel] = .leaving

    let message = SockitMessage.leave(channel: channel)

    return [
        .sendMessage(message),
        .emit(.channelStateChanged(channel, .leaving))
    ]
}

private func handleChannelJoined(state: inout ClientState, channel: String) -> [ClientEffect] {
    guard case let .joining(joinRef) = state.channels[channel] else {
        return []
    }

    state.channels[channel] = .joined(joinRef: joinRef)

    return [.emit(.channelStateChanged(channel, .joined))]
}

private func handleChannelLeft(state: inout ClientState, channel: String) -> [ClientEffect] {
    state.channels.removeValue(forKey: channel)
    return [.emit(.channelStateChanged(channel, .left))]
}

private func handleChannelError(
    state: inout ClientState,
    channel: String,
    code: String,
    message: String
) -> [ClientEffect] {
    state.channels[channel] = .error(code: code, message: message)
    return [.emit(.channelStateChanged(channel, .error(code: code, message: message)))]
}

// MARK: - Request Handlers

private func handleSend(state: inout ClientState, request: SendableRequest) -> [ClientEffect] {
    // Must be connected
    guard case .connected = state.connection else {
        return []
    }

    // If channel specified, must be joined
    if let channel = request.channel {
        guard case .joined = state.channels[channel] else {
            return []
        }
    }

    // Track pending request
    state.pendingRequests[request.id] = PendingRequest(
        id: request.id,
        event: request.event,
        channel: request.channel,
        sentAt: Date()
    )

    let message = request.toMessage()

    return [
        .sendMessage(message),
        .scheduleRequestTimeout(requestId: request.id, delay: request.timeout)
    ]
}

private func handleRequestTimeout(state: inout ClientState, requestId: String) -> [ClientEffect] {
    guard state.pendingRequests.removeValue(forKey: requestId) != nil else {
        return []
    }

    return [.emit(.requestTimeout(requestId: requestId))]
}

// MARK: - Message Handlers

private func handleMessageReceived(state: inout ClientState, message: SockitMessage) -> [ClientEffect] {
    // Handle heartbeat response
    if message.event == "heartbeat" {
        state.missedHeartbeats = 0
        return []
    }

    // Handle channel join response
    if message.event == "channel.join", let channel = message.channel {
        if let envelope = try? message.decodePayload(ChannelJoinResponse.self) {
            if envelope.status == "ok" {
                return handleChannelJoined(state: &state, channel: channel)
            } else if let error = envelope.error {
                return handleChannelError(state: &state, channel: channel, code: error.code, message: error.message)
            }
        }
    }

    // Handle channel leave response
    if message.event == "channel.leave", let channel = message.channel {
        return handleChannelLeft(state: &state, channel: channel)
    }

    // Handle request response
    if let requestId = message.requestId,
       let pending = state.pendingRequests.removeValue(forKey: requestId) {
        // Build response - pass raw payload data through
        let response: Response
        if let parsed = try? Response(from: message) {
            response = parsed
        } else {
            // Fallback: treat entire payload as data
            response = Response(
                requestId: requestId,
                event: pending.event,
                status: .ok,
                data: message.payloadData,
                error: nil,
                channel: pending.channel
            )
        }

        return [
            .cancelRequestTimeout(requestId: requestId),
            .emit(.response(response))
        ]
    }

    // Handle push event (no requestId)
    let push = PushEvent(from: message)
    return [.emit(.pushEvent(push))]
}

// MARK: - Heartbeat Handlers

private func handleHeartbeatTick(state: inout ClientState) -> [ClientEffect] {
    guard case .connected = state.connection else {
        return []
    }

    state.missedHeartbeats += 1

    // Check for heartbeat timeout (3 missed = timeout)
    if state.missedHeartbeats > 3 {
        // Trigger reconnect flow
        return handleTransportDisconnected(state: &state, error: nil)
    }

    let heartbeat = SockitMessage.heartbeat()
    return [.sendMessage(heartbeat)]
}

// MARK: - Internal Types

/// Response structure for channel join
private struct ChannelJoinResponse: Decodable {
    let status: String
    let error: ChannelError?

    struct ChannelError: Decodable {
        let code: String
        let message: String
    }
}

// MARK: - DisconnectReason Description

extension DisconnectReason {
    var description: String {
        switch self {
        case .userInitiated:
            return "User initiated disconnect"
        case let .transportError(msg):
            return "Transport error: \(msg)"
        case .heartbeatTimeout:
            return "Heartbeat timeout"
        case let .serverClosed(code, reason):
            return "Server closed: \(code) - \(reason)"
        }
    }
}
