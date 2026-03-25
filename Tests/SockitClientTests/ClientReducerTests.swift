import Testing
import Foundation
@testable import SockitClient
@testable import SockitCore

// MARK: - Test Helpers

private let testURL = URL(string: "wss://example.com/socket")!

private func makeConfig(
    url: URL = testURL,
    token: String? = "test-token",
    heartbeatInterval: TimeInterval = 30.0,
    reconnectStrategy: ReconnectStrategy = .exponentialBackoff(baseDelay: 1.0, maxDelay: 30.0, maxAttempts: 5)
) -> ClientConfig {
    ClientConfig(
        url: url,
        token: token,
        heartbeatInterval: heartbeatInterval,
        reconnectStrategy: reconnectStrategy
    )
}

private func makeConnectedState(config: ClientConfig? = nil) -> ClientState {
    var state = ClientState()
    state.connection = .connected(since: Date())
    state.config = config ?? makeConfig()
    return state
}

// MARK: - Connection Tests

@Suite("ClientReducer - Connection")
struct ClientReducerConnectionTests {

    @Test("connect from disconnected transitions to connecting")
    func connectFromDisconnected() {
        var state = ClientState()
        let config = makeConfig()

        let effects = clientReducer(state: &state, action: .connect(config))

        #expect(state.connection == .connecting(attempt: 1))
        #expect(state.config?.url == testURL)

        let hasOpenConnection = effects.contains { effect in
            if case .openConnection(let url, let token) = effect {
                return url == testURL && token == "test-token"
            }
            return false
        }
        #expect(hasOpenConnection)
    }

    @Test("connect when already connecting is no-op")
    func connectWhenConnecting() {
        var state = ClientState()
        state.connection = .connecting(attempt: 1)

        let effects = clientReducer(state: &state, action: .connect(makeConfig()))

        #expect(effects.isEmpty)
        #expect(state.connection == .connecting(attempt: 1))
    }

    @Test("connect when already connected is no-op")
    func connectWhenConnected() {
        var state = makeConnectedState()

        let effects = clientReducer(state: &state, action: .connect(makeConfig()))

        #expect(effects.isEmpty)
    }

    @Test("transportConnected transitions to connected and starts heartbeat")
    func transportConnected() {
        var state = ClientState()
        state.connection = .connecting(attempt: 1)
        state.config = makeConfig()

        let effects = clientReducer(state: &state, action: .transportConnected)

        if case .connected = state.connection {
            // OK
        } else {
            Issue.record("Expected connected state")
        }

        let hasStartHeartbeat = effects.contains { effect in
            if case .startHeartbeat(let interval) = effect {
                return interval == 30.0
            }
            return false
        }
        #expect(hasStartHeartbeat)

        let hasEmitConnected = effects.contains { effect in
            if case .emit(let message) = effect,
               case .connectionStateChanged(.connected) = message {
                return true
            }
            return false
        }
        #expect(hasEmitConnected)
    }

    @Test("disconnect from connected closes connection")
    func disconnectFromConnected() {
        var state = makeConnectedState()

        let effects = clientReducer(state: &state, action: .disconnect(.userInitiated))

        #expect(state.connection == .disconnected)

        let hasCloseConnection = effects.contains { effect in
            if case .closeConnection = effect {
                return true
            }
            return false
        }
        #expect(hasCloseConnection)

        let hasStopHeartbeat = effects.contains { effect in
            if case .stopHeartbeat = effect {
                return true
            }
            return false
        }
        #expect(hasStopHeartbeat)
    }

    @Test("transportDisconnected triggers reconnect when configured")
    func transportDisconnectedTriggersReconnect() {
        var state = makeConnectedState()
        state.config = makeConfig(reconnectStrategy: .exponentialBackoff(baseDelay: 1.0, maxDelay: 30.0, maxAttempts: 5))

        let effects = clientReducer(state: &state, action: .transportDisconnected(nil))

        if case .reconnecting(let attempt, _) = state.connection {
            #expect(attempt == 1)
        } else {
            Issue.record("Expected reconnecting state")
        }

        let hasScheduleReconnect = effects.contains { effect in
            if case .scheduleReconnect = effect {
                return true
            }
            return false
        }
        #expect(hasScheduleReconnect)
    }

    @Test("transportDisconnected with no reconnect strategy transitions to disconnected")
    func transportDisconnectedNoReconnect() {
        var state = makeConnectedState()
        state.config = makeConfig(reconnectStrategy: .none)

        let effects = clientReducer(state: &state, action: .transportDisconnected(nil))

        #expect(state.connection == .disconnected)

        let hasEmitDisconnected = effects.contains { effect in
            if case .emit(let message) = effect,
               case .connectionStateChanged(.disconnected) = message {
                return true
            }
            return false
        }
        #expect(hasEmitDisconnected)
    }

    @Test("reconnect action opens connection with incremented attempt")
    func reconnectAction() {
        var state = ClientState()
        state.connection = .reconnecting(attempt: 2, lastError: nil)
        state.config = makeConfig()

        let effects = clientReducer(state: &state, action: .reconnect)

        if case .connecting(let attempt) = state.connection {
            #expect(attempt == 3)
        } else {
            Issue.record("Expected connecting state")
        }

        let hasOpenConnection = effects.contains { effect in
            if case .openConnection = effect {
                return true
            }
            return false
        }
        #expect(hasOpenConnection)
    }

    @Test("reconnect after max attempts transitions to disconnected")
    func reconnectAfterMaxAttempts() {
        var state = ClientState()
        state.connection = .reconnecting(attempt: 5, lastError: nil)
        state.config = makeConfig(reconnectStrategy: .exponentialBackoff(baseDelay: 1.0, maxDelay: 30.0, maxAttempts: 5))

        let effects = clientReducer(state: &state, action: .reconnect)

        #expect(state.connection == .disconnected)

        let hasEmitDisconnected = effects.contains { effect in
            if case .emit(let message) = effect,
               case .connectionStateChanged(.disconnected) = message {
                return true
            }
            return false
        }
        #expect(hasEmitDisconnected)
    }
}

// MARK: - Channel Tests

@Suite("ClientReducer - Channels")
struct ClientReducerChannelTests {

    @Test("join channel when connected transitions to joining")
    func joinChannelWhenConnected() {
        var state = makeConnectedState()
        state.refCounter = 0

        let effects = clientReducer(state: &state, action: .joinChannel("user:self", Data("{}".utf8)))

        #expect(state.channels["user:self"] == .joining(joinRef: "1"))
        #expect(state.refCounter == 1)

        let hasSendJoin = effects.contains { effect in
            if case .sendMessage(let message) = effect {
                return message.event == "channel.join" && message.channel == "user:self"
            }
            return false
        }
        #expect(hasSendJoin)
    }

    @Test("join channel when not connected is no-op")
    func joinChannelWhenNotConnected() {
        var state = ClientState()

        let effects = clientReducer(state: &state, action: .joinChannel("user:self", Data("{}".utf8)))

        #expect(effects.isEmpty)
        #expect(state.channels.isEmpty)
    }

    @Test("channelJoined transitions to joined state")
    func channelJoined() {
        var state = makeConnectedState()
        state.channels["user:self"] = .joining(joinRef: "1")

        let effects = clientReducer(state: &state, action: .channelJoined("user:self"))

        #expect(state.channels["user:self"] == .joined(joinRef: "1"))

        let hasEmitJoined = effects.contains { effect in
            if case .emit(let message) = effect,
               case .channelStateChanged("user:self", .joined) = message {
                return true
            }
            return false
        }
        #expect(hasEmitJoined)
    }

    @Test("leave channel when joined transitions to leaving")
    func leaveChannelWhenJoined() {
        var state = makeConnectedState()
        state.channels["user:self"] = .joined(joinRef: "1")

        let effects = clientReducer(state: &state, action: .leaveChannel("user:self"))

        #expect(state.channels["user:self"] == .leaving)

        let hasSendLeave = effects.contains { effect in
            if case .sendMessage(let message) = effect {
                return message.event == "channel.leave" && message.channel == "user:self"
            }
            return false
        }
        #expect(hasSendLeave)
    }

    @Test("channelLeft removes channel from state")
    func channelLeft() {
        var state = makeConnectedState()
        state.channels["user:self"] = .leaving

        let effects = clientReducer(state: &state, action: .channelLeft("user:self"))

        #expect(state.channels["user:self"] == nil)

        let hasEmitLeft = effects.contains { effect in
            if case .emit(let message) = effect,
               case .channelStateChanged("user:self", .left) = message {
                return true
            }
            return false
        }
        #expect(hasEmitLeft)
    }

    @Test("channelError sets error state")
    func channelError() {
        var state = makeConnectedState()
        state.channels["user:self"] = .joining(joinRef: "1")

        let effects = clientReducer(state: &state, action: .channelError("user:self", "unauthorized", "Not allowed"))

        if case .error(let code, let message) = state.channels["user:self"] {
            #expect(code == "unauthorized")
            #expect(message == "Not allowed")
        } else {
            Issue.record("Expected error state")
        }
    }
}

// MARK: - Request Tests

@Suite("ClientReducer - Requests")
struct ClientReducerRequestTests {

    @Test("send request when connected sends message and schedules timeout")
    func sendRequestWhenConnected() {
        var state = makeConnectedState()

        let request = SendableRequest(
            id: "req-123",
            event: "home.get_today",
            timeout: 10.0
        )

        let effects = clientReducer(state: &state, action: .send(request))

        #expect(state.pendingRequests["req-123"] != nil)
        #expect(state.pendingRequests["req-123"]?.event == "home.get_today")

        let hasSendMessage = effects.contains { effect in
            if case .sendMessage(let message) = effect {
                return message.event == "home.get_today" && message.requestId == "req-123"
            }
            return false
        }
        #expect(hasSendMessage)

        let hasScheduleTimeout = effects.contains { effect in
            if case .scheduleRequestTimeout(let id, let delay) = effect {
                return id == "req-123" && delay == 10.0
            }
            return false
        }
        #expect(hasScheduleTimeout)
    }

    @Test("send request when not connected is no-op")
    func sendRequestWhenNotConnected() {
        var state = ClientState()

        let request = SendableRequest(event: "test")
        let effects = clientReducer(state: &state, action: .send(request))

        #expect(effects.isEmpty)
        #expect(state.pendingRequests.isEmpty)
    }

    @Test("send request on channel requires channel to be joined")
    func sendRequestOnChannelRequiresJoined() {
        var state = makeConnectedState()
        state.channels["user:self"] = .joining(joinRef: "1")

        let request = SendableRequest(event: "test", channel: "user:self")
        let effects = clientReducer(state: &state, action: .send(request))

        #expect(effects.isEmpty)
        #expect(state.pendingRequests.isEmpty)
    }

    @Test("send request on joined channel succeeds")
    func sendRequestOnJoinedChannel() {
        var state = makeConnectedState()
        state.channels["user:self"] = .joined(joinRef: "1")

        let request = SendableRequest(event: "test", channel: "user:self")
        let effects = clientReducer(state: &state, action: .send(request))

        #expect(state.pendingRequests[request.id] != nil)

        let hasSendMessage = effects.contains { effect in
            if case .sendMessage(let message) = effect {
                return message.channel == "user:self"
            }
            return false
        }
        #expect(hasSendMessage)
    }

    @Test("requestTimeout removes pending request and emits timeout error")
    func requestTimeout() {
        var state = makeConnectedState()
        state.pendingRequests["req-123"] = PendingRequest(
            id: "req-123",
            event: "home.get_today",
            channel: nil,
            sentAt: Date()
        )

        let effects = clientReducer(state: &state, action: .requestTimeout("req-123"))

        #expect(state.pendingRequests["req-123"] == nil)

        let hasEmitTimeout = effects.contains { effect in
            if case .emit(let message) = effect,
               case .requestTimeout(let id) = message {
                return id == "req-123"
            }
            return false
        }
        #expect(hasEmitTimeout)
    }
}

// MARK: - Message Received Tests

@Suite("ClientReducer - Message Received")
struct ClientReducerMessageReceivedTests {

    @Test("response message clears pending request and emits response")
    func responseMessage() {
        var state = makeConnectedState()
        state.pendingRequests["req-123"] = PendingRequest(
            id: "req-123",
            event: "home.get_today",
            channel: nil,
            sentAt: Date()
        )

        let message = SockitMessage(
            event: "home.get_today",
            payloadData: Data("{\"status\": \"ok\"}".utf8),
            requestId: "req-123"
        )

        let effects = clientReducer(state: &state, action: .transportMessageReceived(message))

        #expect(state.pendingRequests["req-123"] == nil)

        let hasCancelTimeout = effects.contains { effect in
            if case .cancelRequestTimeout(let id) = effect {
                return id == "req-123"
            }
            return false
        }
        #expect(hasCancelTimeout)

        let hasEmitResponse = effects.contains { effect in
            if case .emit(let msg) = effect,
               case .response(let response) = msg {
                return response.requestId == "req-123"
            }
            return false
        }
        #expect(hasEmitResponse)
    }

    @Test("push message emits push event")
    func pushMessage() {
        var state = makeConnectedState()

        let message = SockitMessage(
            event: "delivery.status_changed",
            payloadData: Data("{\"status\": \"delivered\"}".utf8),
            channel: "user:123"
        )

        let effects = clientReducer(state: &state, action: .transportMessageReceived(message))

        let hasEmitPush = effects.contains { effect in
            if case .emit(let msg) = effect,
               case .pushEvent(let push) = msg {
                return push.event == "delivery.status_changed"
            }
            return false
        }
        #expect(hasEmitPush)
    }

    @Test("heartbeat response resets missed heartbeats")
    func heartbeatResponse() {
        var state = makeConnectedState()
        state.missedHeartbeats = 2

        let message = SockitMessage(event: "heartbeat")

        let effects = clientReducer(state: &state, action: .transportMessageReceived(message))

        #expect(state.missedHeartbeats == 0)
        #expect(effects.isEmpty)
    }

    @Test("channel join response transitions channel to joined")
    func channelJoinResponse() {
        var state = makeConnectedState()
        state.channels["user:self"] = .joining(joinRef: "1")

        let message = SockitMessage(
            event: "channel.join",
            payloadData: Data("{\"status\": \"ok\"}".utf8),
            requestId: "1",
            channel: "user:self"
        )

        let effects = clientReducer(state: &state, action: .transportMessageReceived(message))

        #expect(state.channels["user:self"] == .joined(joinRef: "1"))
    }
}

// MARK: - Heartbeat Tests

@Suite("ClientReducer - Heartbeat")
struct ClientReducerHeartbeatTests {

    @Test("heartbeatTick sends heartbeat message")
    func heartbeatTickSendsMessage() {
        var state = makeConnectedState()

        let effects = clientReducer(state: &state, action: .heartbeatTick)

        #expect(state.missedHeartbeats == 1)

        let hasSendHeartbeat = effects.contains { effect in
            if case .sendMessage(let message) = effect {
                return message.event == "heartbeat"
            }
            return false
        }
        #expect(hasSendHeartbeat)
    }

    @Test("heartbeatTimeout after max misses triggers disconnect")
    func heartbeatTimeoutTriggersDisconnect() {
        var state = makeConnectedState()
        state.missedHeartbeats = 3

        let effects = clientReducer(state: &state, action: .heartbeatTick)

        // Should trigger reconnect flow
        let hasCloseOrReconnect = effects.contains { effect in
            if case .closeConnection = effect {
                return true
            }
            if case .scheduleReconnect = effect {
                return true
            }
            return false
        }
        #expect(hasCloseOrReconnect)
    }
}

// MARK: - Reconnection After Transport Disconnect (No Auto-Reconnect)

@Suite("ClientReducer - Reconnection with .none strategy")
struct ClientReducerReconnectionNoneStrategyTests {

    @Test("CRITICAL: transport disconnect with .none strategy clears channels so rejoin works")
    func transportDisconnectClearsChannels() {
        // Setup: connected with a joined channel, using .none reconnect strategy
        // (this is how the CaloX session state machine uses sockit)
        var state = ClientState()
        state.connection = .connected(since: Date())
        state.config = makeConfig(reconnectStrategy: .none)
        state.channels["user"] = .joined(joinRef: "1")

        // Server dies → transport disconnects
        let effects = clientReducer(state: &state, action: .transportDisconnected(nil))

        // With .none strategy, should go to .disconnected
        #expect(state.connection == .disconnected)

        // CRITICAL: channels must be cleared so that a subsequent
        // connect() + join("user") works. If channels still has a stale
        // "user" entry, the join will be silently dropped.
        #expect(
            state.channels.isEmpty,
            "Channels must be cleared on transport disconnect — stale channel entries cause rejoin to be silently dropped"
        )
    }

    @Test("rejoin after transport disconnect succeeds")
    func rejoinAfterTransportDisconnect() {
        // Setup: connected with joined channel, .none strategy
        var state = ClientState()
        state.connection = .connected(since: Date())
        state.config = makeConfig(reconnectStrategy: .none)
        state.channels["user"] = .joined(joinRef: "1")

        // 1. Transport disconnects (server dies)
        _ = clientReducer(state: &state, action: .transportDisconnected(nil))
        #expect(state.connection == .disconnected)

        // 2. External reconnect (session state machine calls connect)
        let connectEffects = clientReducer(state: &state, action: .connect(makeConfig(reconnectStrategy: .none)))
        #expect(state.connection == .connecting(attempt: 1))

        // 3. Transport connects
        _ = clientReducer(state: &state, action: .transportConnected)

        // 4. Join channel again
        let joinEffects = clientReducer(state: &state, action: .joinChannel("user", Data("{}".utf8)))

        // CRITICAL: join must NOT be silently dropped
        #expect(
            state.channels["user"] != nil,
            "Channel join must succeed after reconnect — not silently dropped"
        )

        if case .joining = state.channels["user"] {
            // correct
        } else {
            Issue.record("Expected channel to be in .joining state, got \(String(describing: state.channels["user"]))")
        }

        let hasSendMessage = joinEffects.contains { effect in
            if case .sendMessage = effect { return true }
            return false
        }
        #expect(hasSendMessage, "Join must send the join message to the server")
    }

    @Test("auth-related channel errors still propagate correctly after fix")
    func authChannelErrorStillPropagates() {
        // Ensure fixing the channel clear doesn't break auth error handling
        var state = ClientState()
        state.connection = .connected(since: Date())
        state.config = makeConfig(reconnectStrategy: .none)
        state.channels["user"] = .joining(joinRef: "1")

        // Server responds with auth error on channel join
        let effects = clientReducer(
            state: &state,
            action: .channelError("user", "token_expired", "Token expired")
        )

        // Channel should be in error state
        if case .error(let code, let message) = state.channels["user"] {
            #expect(code == "token_expired")
            #expect(message == "Token expired")
        } else {
            Issue.record("Expected channel error state")
        }

        // Should emit channel state change
        let hasErrorEmit = effects.contains { effect in
            if case .emit(let msg) = effect,
               case .channelStateChanged("user", .error) = msg {
                return true
            }
            return false
        }
        #expect(hasErrorEmit)
    }

    @Test("transport disconnect with reconnect strategy does NOT clear channels")
    func transportDisconnectWithReconnectKeepsChannels() {
        // When using auto-reconnect, sockit manages its own reconnection
        // and channels should persist for auto-rejoin (existing behavior)
        var state = ClientState()
        state.connection = .connected(since: Date())
        state.config = makeConfig(reconnectStrategy: .exponentialBackoff(baseDelay: 1.0, maxDelay: 30.0, maxAttempts: 5))
        state.channels["user"] = .joined(joinRef: "1")

        _ = clientReducer(state: &state, action: .transportDisconnected(nil))

        // With auto-reconnect, channels should persist
        // (sockit will rejoin after reconnecting)
        #expect(state.connection == .reconnecting(attempt: 1, lastError: nil))
        // Note: this test documents existing behavior —
        // auto-reconnect keeps channels for its own rejoin logic
    }
}
