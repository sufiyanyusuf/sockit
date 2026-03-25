import Testing
import Foundation
@testable import SockitServer
@testable import SockitCore

// MARK: - Test Helpers

private let testConnectionId = UUID()
private let testUserId = UUID()

private func makeState(
    id: UUID = testConnectionId,
    userId: UUID? = nil,
    channels: Set<String> = []
) -> ConnectionState {
    var state = ConnectionState(id: id, userId: userId)
    state.channels = channels
    return state
}

// MARK: - Connection Lifecycle Tests

@Suite("ConnectionReducer - Connection Lifecycle")
struct ConnectionReducerLifecycleTests {

    @Test("connected sets userId and resets heartbeat")
    func connectedSetsUserIdAndResetsHeartbeat() {
        var state = makeState()
        state.missedHeartbeats = 5

        let effects = connectionReducer(state: &state, action: .connected(userId: testUserId))

        #expect(state.userId == testUserId)
        #expect(state.missedHeartbeats == 0)

        let hasOnConnect = effects.contains { effect in
            if case .onConnect(let userId) = effect {
                return userId == testUserId
            }
            return false
        }
        #expect(hasOnConnect)
    }

    @Test("connected with nil userId")
    func connectedWithNilUserId() {
        var state = makeState()

        let effects = connectionReducer(state: &state, action: .connected(userId: nil))

        #expect(state.userId == nil)

        let hasOnConnect = effects.contains { effect in
            if case .onConnect(let userId) = effect {
                return userId == nil
            }
            return false
        }
        #expect(hasOnConnect)
    }

    @Test("disconnected clears channels and unsubscribes")
    func disconnectedClearsChannels() {
        var state = makeState(channels: ["user:123", "lobby", "admin:456"])

        let effects = connectionReducer(state: &state, action: .disconnected)

        #expect(state.channels.isEmpty)

        // Should have one unsubscribe per channel plus onDisconnect
        let unsubscribeEffects = effects.filter { effect in
            if case .unsubscribeFromChannel = effect { return true }
            return false
        }
        #expect(unsubscribeEffects.count == 3)

        let hasOnDisconnect = effects.contains { effect in
            if case .onDisconnect = effect { return true }
            return false
        }
        #expect(hasOnDisconnect)
    }

    @Test("disconnected with no channels only emits onDisconnect")
    func disconnectedNoChannels() {
        var state = makeState()

        let effects = connectionReducer(state: &state, action: .disconnected)

        #expect(effects.count == 1)

        let hasOnDisconnect = effects.contains { effect in
            if case .onDisconnect = effect { return true }
            return false
        }
        #expect(hasOnDisconnect)
    }
}

// MARK: - Message Received Tests

@Suite("ConnectionReducer - Message Received")
struct ConnectionReducerMessageReceivedTests {

    @Test("heartbeat message resets counter and sends heartbeat response")
    func heartbeatMessage() {
        var state = makeState()
        state.missedHeartbeats = 2

        let message = SockitMessage(event: "heartbeat")
        let effects = connectionReducer(state: &state, action: .messageReceived(message))

        #expect(state.missedHeartbeats == 0)

        let hasSendHeartbeat = effects.contains { effect in
            if case .sendMessage(let msg) = effect {
                return msg.event == "heartbeat"
            }
            return false
        }
        #expect(hasSendHeartbeat)
    }

    @Test("channel.join message produces validateJoin effect")
    func channelJoinMessage() {
        var state = makeState()

        let message = SockitMessage(
            event: "channel.join",
            payloadData: Data("{\"topic\":\"user:123\"}".utf8),
            requestId: "req-1",
            channel: "user:123"
        )

        let effects = connectionReducer(state: &state, action: .messageReceived(message))

        let hasValidateJoin = effects.contains { effect in
            if case .validateJoin(let channel, _, let requestId) = effect {
                return channel == "user:123" && requestId == "req-1"
            }
            return false
        }
        #expect(hasValidateJoin)
    }

    @Test("channel.join without requestId routes as normal event")
    func channelJoinWithoutRequestId() {
        var state = makeState()

        let message = SockitMessage(
            event: "channel.join",
            channel: "user:123"
        )

        let effects = connectionReducer(state: &state, action: .messageReceived(message))

        // Without requestId, it should route as a normal event, not validateJoin
        let hasRouteEvent = effects.contains { effect in
            if case .routeEvent(let event, _, _, _) = effect {
                return event == "channel.join"
            }
            return false
        }
        #expect(hasRouteEvent)
    }

    @Test("channel.leave message removes channel and unsubscribes")
    func channelLeaveMessage() {
        var state = makeState(channels: ["user:123"])

        let message = SockitMessage(
            event: "channel.leave",
            channel: "user:123"
        )

        let effects = connectionReducer(state: &state, action: .messageReceived(message))

        #expect(!state.channels.contains("user:123"))

        let hasUnsubscribe = effects.contains { effect in
            if case .unsubscribeFromChannel(let ch) = effect {
                return ch == "user:123"
            }
            return false
        }
        #expect(hasUnsubscribe)
    }

    @Test("channel.leave for non-joined channel is no-op")
    func channelLeaveNotJoined() {
        var state = makeState()

        let message = SockitMessage(
            event: "channel.leave",
            channel: "user:123"
        )

        let effects = connectionReducer(state: &state, action: .messageReceived(message))

        #expect(effects.isEmpty)
    }

    @Test("regular event message routes to handler")
    func regularEventMessage() {
        var state = makeState()

        let message = SockitMessage(
            event: "home.get_today",
            payloadData: Data("{\"date\":\"2026-03-25\"}".utf8),
            requestId: "req-42",
            channel: "user:self"
        )

        let effects = connectionReducer(state: &state, action: .messageReceived(message))

        let hasRouteEvent = effects.contains { effect in
            if case .routeEvent(let event, _, let requestId, let channel) = effect {
                return event == "home.get_today" && requestId == "req-42" && channel == "user:self"
            }
            return false
        }
        #expect(hasRouteEvent)
    }

    @Test("push event (no requestId) routes to handler")
    func pushEventRoutes() {
        var state = makeState()

        let message = SockitMessage(
            event: "notification.new",
            payloadData: Data("{\"count\":5}".utf8)
        )

        let effects = connectionReducer(state: &state, action: .messageReceived(message))

        let hasRouteEvent = effects.contains { effect in
            if case .routeEvent(let event, _, let requestId, _) = effect {
                return event == "notification.new" && requestId == nil
            }
            return false
        }
        #expect(hasRouteEvent)
    }
}

// MARK: - Send Response Tests

@Suite("ConnectionReducer - Send Response")
struct ConnectionReducerSendResponseTests {

    @Test("sendResponse with ok status creates send message effect")
    func sendResponseOk() {
        var state = makeState()
        state.pendingResponses["req-1"] = PendingResponse(
            requestId: "req-1",
            event: "home.get_today",
            channel: "user:123"
        )

        let responseData = Data("{\"items\":[]}".utf8)
        let effects = connectionReducer(
            state: &state,
            action: .sendResponse(requestId: "req-1", status: .ok, data: responseData, error: nil)
        )

        // Pending response should be cleared
        #expect(state.pendingResponses["req-1"] == nil)

        let hasSendMessage = effects.contains { effect in
            if case .sendMessage(let msg) = effect {
                return msg.event == "home.get_today"
                    && msg.requestId == "req-1"
                    && msg.channel == "user:123"
                    && msg.status == .ok
            }
            return false
        }
        #expect(hasSendMessage)
    }

    @Test("sendResponse with error status includes error payload")
    func sendResponseError() {
        var state = makeState()
        state.pendingResponses["req-1"] = PendingResponse(
            requestId: "req-1",
            event: "home.get_today",
            channel: nil
        )

        let error = ResponseError(code: "not_found", message: "Item not found")
        let effects = connectionReducer(
            state: &state,
            action: .sendResponse(
                requestId: "req-1", status: .error, data: Data("{}".utf8), error: error)
        )

        #expect(state.pendingResponses["req-1"] == nil)

        let hasSendMessage = effects.contains { effect in
            if case .sendMessage(let msg) = effect {
                return msg.status == .error && msg.requestId == "req-1"
            }
            return false
        }
        #expect(hasSendMessage)
    }

    @Test("sendResponse for unknown requestId still sends message with fallback event")
    func sendResponseUnknownRequestId() {
        var state = makeState()
        // No pending response for "req-unknown"

        let effects = connectionReducer(
            state: &state,
            action: .sendResponse(requestId: "req-unknown", status: .ok, data: Data("{}".utf8), error: nil)
        )

        let hasSendMessage = effects.contains { effect in
            if case .sendMessage(let msg) = effect {
                // Falls back to "response" when no pending response found
                return msg.event == "response" && msg.requestId == "req-unknown"
            }
            return false
        }
        #expect(hasSendMessage)
    }
}

// MARK: - Send Push Tests

@Suite("ConnectionReducer - Send Push")
struct ConnectionReducerSendPushTests {

    @Test("sendPush creates send message effect")
    func sendPush() {
        var state = makeState()

        let payloadData = Data("{\"status\":\"delivered\"}".utf8)
        let effects = connectionReducer(
            state: &state,
            action: .sendPush(event: "delivery.updated", payloadData: payloadData, channel: "user:123")
        )

        let hasSendMessage = effects.contains { effect in
            if case .sendMessage(let msg) = effect {
                return msg.event == "delivery.updated"
                    && msg.channel == "user:123"
                    && msg.requestId == nil
            }
            return false
        }
        #expect(hasSendMessage)
    }

    @Test("sendPush without channel")
    func sendPushNoChannel() {
        var state = makeState()

        let effects = connectionReducer(
            state: &state,
            action: .sendPush(event: "system.alert", payloadData: Data("{}".utf8), channel: nil)
        )

        let hasSendMessage = effects.contains { effect in
            if case .sendMessage(let msg) = effect {
                return msg.event == "system.alert" && msg.channel == nil
            }
            return false
        }
        #expect(hasSendMessage)
    }
}

// MARK: - Channel Management Tests

@Suite("ConnectionReducer - Channel Management")
struct ConnectionReducerChannelTests {

    @Test("joinChannel for new channel produces validateJoin effect")
    func joinNewChannel() {
        var state = makeState()

        let effects = connectionReducer(
            state: &state,
            action: .joinChannel("user:123", payloadData: Data("{}".utf8), requestId: "req-1")
        )

        let hasValidateJoin = effects.contains { effect in
            if case .validateJoin(let channel, _, let requestId) = effect {
                return channel == "user:123" && requestId == "req-1"
            }
            return false
        }
        #expect(hasValidateJoin)
    }

    @Test("joinChannel for already-joined channel sends ok response without validateJoin")
    func joinAlreadyJoinedChannel() {
        var state = makeState(channels: ["user:123"])

        let effects = connectionReducer(
            state: &state,
            action: .joinChannel("user:123", payloadData: Data("{}".utf8), requestId: "req-1")
        )

        // Should send an ok message, not validateJoin
        let hasValidateJoin = effects.contains { effect in
            if case .validateJoin = effect { return true }
            return false
        }
        #expect(!hasValidateJoin)

        let hasSendMessage = effects.contains { effect in
            if case .sendMessage(let msg) = effect {
                return msg.event == "channel.join"
                    && msg.requestId == "req-1"
                    && msg.channel == "user:123"
            }
            return false
        }
        #expect(hasSendMessage)
    }

    @Test("leaveChannel removes channel and unsubscribes")
    func leaveChannel() {
        var state = makeState(channels: ["user:123"])

        let effects = connectionReducer(state: &state, action: .leaveChannel("user:123"))

        #expect(!state.channels.contains("user:123"))

        let hasUnsubscribe = effects.contains { effect in
            if case .unsubscribeFromChannel(let ch) = effect {
                return ch == "user:123"
            }
            return false
        }
        #expect(hasUnsubscribe)

        let hasSendLeaveMessage = effects.contains { effect in
            if case .sendMessage(let msg) = effect {
                return msg.event == "channel.leave" && msg.channel == "user:123"
            }
            return false
        }
        #expect(hasSendLeaveMessage)
    }

    @Test("leaveChannel for non-joined channel is no-op")
    func leaveNonJoinedChannel() {
        var state = makeState()

        let effects = connectionReducer(state: &state, action: .leaveChannel("user:123"))

        #expect(effects.isEmpty)
    }

    @Test("channelJoined adds channel to state and subscribes")
    func channelJoined() {
        var state = makeState()

        let effects = connectionReducer(state: &state, action: .channelJoined("user:123"))

        #expect(state.channels.contains("user:123"))

        let hasSubscribe = effects.contains { effect in
            if case .subscribeToChannel(let ch) = effect {
                return ch == "user:123"
            }
            return false
        }
        #expect(hasSubscribe)
    }

    @Test("channelJoinFailed sends error message")
    func channelJoinFailed() {
        var state = makeState()

        let effects = connectionReducer(
            state: &state,
            action: .channelJoinFailed("user:123", code: "unauthorized", message: "Not allowed")
        )

        // Channel should NOT be added to state
        #expect(!state.channels.contains("user:123"))

        let hasSendMessage = effects.contains { effect in
            if case .sendMessage(let msg) = effect {
                return msg.event == "channel.join" && msg.channel == "user:123"
            }
            return false
        }
        #expect(hasSendMessage)
    }
}

// MARK: - Heartbeat Tests

@Suite("ConnectionReducer - Heartbeat")
struct ConnectionReducerHeartbeatTests {

    @Test("heartbeatReceived resets missed heartbeats")
    func heartbeatReceived() {
        var state = makeState()
        state.missedHeartbeats = 3

        let effects = connectionReducer(state: &state, action: .heartbeatReceived)

        #expect(state.missedHeartbeats == 0)
        #expect(effects.isEmpty)
    }

    @Test("heartbeatTick increments missed heartbeats")
    func heartbeatTick() {
        var state = makeState()
        state.missedHeartbeats = 0

        let effects = connectionReducer(state: &state, action: .heartbeatTick)

        #expect(state.missedHeartbeats == 1)
        #expect(effects.isEmpty)
    }

    @Test("heartbeatTick under threshold does not close connection")
    func heartbeatTickUnderThreshold() {
        var state = makeState()
        state.missedHeartbeats = 2

        let effects = connectionReducer(state: &state, action: .heartbeatTick)

        #expect(state.missedHeartbeats == 3)

        let hasClose = effects.contains { effect in
            if case .closeConnection = effect { return true }
            return false
        }
        #expect(!hasClose)
    }

    @Test("heartbeatTick exceeding threshold closes connection")
    func heartbeatTickExceedsThreshold() {
        var state = makeState()
        state.missedHeartbeats = 3

        let effects = connectionReducer(state: &state, action: .heartbeatTick)

        #expect(state.missedHeartbeats == 4)

        let hasClose = effects.contains { effect in
            if case .closeConnection(let code, let reason) = effect {
                return code == 1002 && reason == "Heartbeat timeout"
            }
            return false
        }
        #expect(hasClose)
    }

    @Test("heartbeat timeout after exactly 3 missed does not close yet")
    func heartbeatTimeoutBoundary() {
        var state = makeState()
        state.missedHeartbeats = 2

        // Third tick: missedHeartbeats becomes 3, threshold is > 3
        let effects = connectionReducer(state: &state, action: .heartbeatTick)
        #expect(state.missedHeartbeats == 3)

        let hasClose = effects.contains { effect in
            if case .closeConnection = effect { return true }
            return false
        }
        #expect(!hasClose, "Should not close at exactly 3 missed heartbeats, only when > 3")
    }
}

// MARK: - State Integrity Tests

@Suite("ConnectionReducer - State Integrity")
struct ConnectionReducerStateIntegrityTests {

    @Test("multiple channel joins and leaves maintain correct state")
    func multipleChannelOperations() {
        var state = makeState()

        // Join three channels
        _ = connectionReducer(state: &state, action: .channelJoined("ch1"))
        _ = connectionReducer(state: &state, action: .channelJoined("ch2"))
        _ = connectionReducer(state: &state, action: .channelJoined("ch3"))

        #expect(state.channels == Set(["ch1", "ch2", "ch3"]))

        // Leave one
        _ = connectionReducer(state: &state, action: .leaveChannel("ch2"))
        #expect(state.channels == Set(["ch1", "ch3"]))

        // Disconnect clears all remaining
        let effects = connectionReducer(state: &state, action: .disconnected)
        #expect(state.channels.isEmpty)

        let unsubscribeCount = effects.filter { effect in
            if case .unsubscribeFromChannel = effect { return true }
            return false
        }.count
        #expect(unsubscribeCount == 2)
    }

    @Test("pending responses are cleaned up on send")
    func pendingResponseCleanup() {
        var state = makeState()
        state.pendingResponses["req-1"] = PendingResponse(
            requestId: "req-1", event: "test", channel: nil)
        state.pendingResponses["req-2"] = PendingResponse(
            requestId: "req-2", event: "test2", channel: nil)

        _ = connectionReducer(
            state: &state,
            action: .sendResponse(requestId: "req-1", status: .ok, data: Data("{}".utf8), error: nil)
        )

        #expect(state.pendingResponses["req-1"] == nil)
        #expect(state.pendingResponses["req-2"] != nil)
    }

    @Test("connection ID is preserved through lifecycle")
    func connectionIdPreserved() {
        let specificId = UUID()
        var state = ConnectionState(id: specificId, userId: nil)

        _ = connectionReducer(state: &state, action: .connected(userId: testUserId))
        #expect(state.id == specificId)

        _ = connectionReducer(state: &state, action: .channelJoined("test"))
        #expect(state.id == specificId)

        _ = connectionReducer(state: &state, action: .disconnected)
        #expect(state.id == specificId)
    }
}
