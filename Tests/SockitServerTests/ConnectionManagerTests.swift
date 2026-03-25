import Testing
import Foundation
@testable import SockitServer
@testable import SockitCore

// MARK: - ConnectionManager Tests
//
// ConnectionManager stores Connection actors which require Vapor's WebSocket.
// These tests validate the pure data tracking logic (user mappings, connection lookups)
// by registering/unregistering with known IDs and verifying the bookkeeping.
// We cannot create real Connection objects without Vapor, so we test what we can:
// the methods that don't send messages.

@Suite("ConnectionManager - User Tracking")
struct ConnectionManagerUserTrackingTests {

    @Test("isUserConnected returns false for unknown user")
    func isUserConnectedUnknown() async {
        let manager = ConnectionManager()

        let result = await manager.isUserConnected(UUID())
        #expect(!result)
    }

    @Test("allConnectionIds is empty initially")
    func allConnectionIdsEmpty() async {
        let manager = ConnectionManager()

        let ids = await manager.allConnectionIds
        #expect(ids.isEmpty)
    }

    @Test("connection for unknown ID returns nil")
    func connectionForUnknownId() async {
        let manager = ConnectionManager()

        let conn = await manager.connection(for: UUID())
        #expect(conn == nil)
    }

    @Test("unregister unknown connection does not crash")
    func unregisterUnknown() async {
        let manager = ConnectionManager()

        // Should not crash
        await manager.unregister(UUID(), userId: nil)
        await manager.unregister(UUID(), userId: UUID())
    }

    @Test("isUserConnected returns false after unregister with userId")
    func isUserConnectedAfterUnregister() async {
        let manager = ConnectionManager()
        let userId = UUID()
        let connId = UUID()

        // We cannot register a real Connection, but we can test unregister logic
        // by verifying user tracking is cleaned up
        await manager.unregister(connId, userId: userId)

        let result = await manager.isUserConnected(userId)
        #expect(!result)
    }
}

// MARK: - ConnectionState Tests

@Suite("ConnectionState")
struct ConnectionStateTests {

    @Test("default state initializes correctly")
    func defaultState() {
        let state = ConnectionState()

        #expect(state.channels.isEmpty)
        #expect(state.pendingResponses.isEmpty)
        #expect(state.metadata.isEmpty)
        #expect(state.missedHeartbeats == 0)
        #expect(state.userId == nil)
    }

    @Test("state with userId")
    func stateWithUserId() {
        let userId = UUID()
        let state = ConnectionState(id: UUID(), userId: userId)

        #expect(state.userId == userId)
    }

    @Test("state equality")
    func stateEquality() {
        let id = UUID()
        let state1 = ConnectionState(id: id, userId: nil)
        let state2 = ConnectionState(id: id, userId: nil)

        #expect(state1 == state2)
    }

    @Test("state inequality with different channels")
    func stateInequalityChannels() {
        let id = UUID()
        var state1 = ConnectionState(id: id)
        let state2 = ConnectionState(id: id)

        state1.channels.insert("lobby")

        #expect(state1 != state2)
    }
}

// MARK: - PendingResponse Tests

@Suite("PendingResponse")
struct PendingResponseTests {

    @Test("PendingResponse initializes with correct values")
    func pendingResponseInit() {
        let pending = PendingResponse(
            requestId: "req-1",
            event: "home.get_today",
            channel: "user:123"
        )

        #expect(pending.requestId == "req-1")
        #expect(pending.event == "home.get_today")
        #expect(pending.channel == "user:123")
    }

    @Test("PendingResponse with nil channel")
    func pendingResponseNilChannel() {
        let pending = PendingResponse(
            requestId: "req-1",
            event: "test",
            channel: nil
        )

        #expect(pending.channel == nil)
    }

    @Test("PendingResponse receivedAt defaults to now")
    func pendingResponseReceivedAt() {
        let before = Date()
        let pending = PendingResponse(requestId: "req-1", event: "test", channel: nil)
        let after = Date()

        #expect(pending.receivedAt >= before)
        #expect(pending.receivedAt <= after)
    }

    @Test("PendingResponse equality")
    func pendingResponseEquality() {
        let date = Date()
        let p1 = PendingResponse(requestId: "req-1", event: "test", channel: nil, receivedAt: date)
        let p2 = PendingResponse(requestId: "req-1", event: "test", channel: nil, receivedAt: date)

        #expect(p1 == p2)
    }
}

// MARK: - ServerAction Tests

@Suite("ServerAction")
struct ServerActionTests {

    @Test("ServerAction cases are constructable")
    func actionCases() {
        // Verify all action cases can be constructed (compile-time check + runtime validation)
        let actions: [ServerAction] = [
            .connected(userId: UUID()),
            .connected(userId: nil),
            .disconnected,
            .messageReceived(SockitMessage(event: "test")),
            .sendResponse(requestId: "req-1", status: .ok, data: Data("{}".utf8), error: nil),
            .sendResponse(
                requestId: "req-2", status: .error, data: Data("{}".utf8),
                error: ResponseError(code: "err", message: "fail")),
            .sendPush(event: "push", payloadData: Data("{}".utf8), channel: nil),
            .sendPush(event: "push", payloadData: Data("{}".utf8), channel: "ch"),
            .joinChannel("ch", payloadData: Data("{}".utf8), requestId: "req-3"),
            .leaveChannel("ch"),
            .channelJoined("ch"),
            .channelJoinFailed("ch", code: "err", message: "fail"),
            .heartbeatReceived,
            .heartbeatTick,
        ]

        #expect(actions.count == 14)
    }
}

// MARK: - ServerEffect Tests

@Suite("ServerEffect")
struct ServerEffectTests {

    @Test("ServerEffect cases are constructable and equatable")
    func effectCases() {
        let effect1 = ServerEffect.sendMessage(SockitMessage(event: "test"))
        let effect2 = ServerEffect.sendMessage(SockitMessage(event: "test"))
        #expect(effect1 == effect2)

        let close1 = ServerEffect.closeConnection(code: 1002, reason: "timeout")
        let close2 = ServerEffect.closeConnection(code: 1002, reason: "timeout")
        #expect(close1 == close2)

        let subscribe1 = ServerEffect.subscribeToChannel("ch1")
        let subscribe2 = ServerEffect.subscribeToChannel("ch1")
        #expect(subscribe1 == subscribe2)

        let unsubscribe1 = ServerEffect.unsubscribeFromChannel("ch1")
        let unsubscribe2 = ServerEffect.unsubscribeFromChannel("ch1")
        #expect(unsubscribe1 == unsubscribe2)

        let onConnect1 = ServerEffect.onConnect(userId: nil)
        let onConnect2 = ServerEffect.onConnect(userId: nil)
        #expect(onConnect1 == onConnect2)

        let onDisconnect1 = ServerEffect.onDisconnect
        let onDisconnect2 = ServerEffect.onDisconnect
        #expect(onDisconnect1 == onDisconnect2)
    }

    @Test("ServerEffect inequality")
    func effectInequality() {
        let effect1 = ServerEffect.subscribeToChannel("ch1")
        let effect2 = ServerEffect.subscribeToChannel("ch2")
        #expect(effect1 != effect2)

        let close1 = ServerEffect.closeConnection(code: 1000, reason: "normal")
        let close2 = ServerEffect.closeConnection(code: 1002, reason: "timeout")
        #expect(close1 != close2)
    }
}
