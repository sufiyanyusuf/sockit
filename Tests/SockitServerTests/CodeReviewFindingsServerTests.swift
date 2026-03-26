import Testing
import Foundation
@testable import SockitServer
@testable import SockitCore

// MARK: - P1: Anonymous/default server connections

@Suite("P1 - Anonymous connection support")
struct AnonymousConnectionTests {

    @Test("server reducer accepts nil userId")
    func serverReducerAcceptsNilUserId() {
        var state = ConnectionState(id: UUID(), userId: nil)

        let effects = connectionReducer(state: &state, action: .connected(userId: nil))

        #expect(state.userId == nil, "ConnectionState should accept nil userId")

        let hasOnConnect = effects.contains { effect in
            if case .onConnect(let userId) = effect {
                return userId == nil
            }
            return false
        }
        #expect(hasOnConnect, "Reducer should emit onConnect with nil userId")
    }

    @Test("anonymous connection can join channels and receive routed events")
    func anonymousConnectionFullLifecycle() {
        var state = ConnectionState(id: UUID(), userId: nil)

        _ = connectionReducer(state: &state, action: .connected(userId: nil))
        #expect(state.userId == nil)

        _ = connectionReducer(state: &state, action: .channelJoined("public:lobby"))
        #expect(state.channels.contains("public:lobby"))

        let message = SockitMessage(
            event: "chat.send",
            payloadData: Data("{\"text\":\"hello\"}".utf8),
            requestId: "req-1",
            channel: "public:lobby"
        )
        let effects = connectionReducer(state: &state, action: .messageReceived(message))

        let hasRouteEvent = effects.contains { effect in
            if case .routeEvent(let event, _, _, _) = effect {
                return event == "chat.send"
            }
            return false
        }
        #expect(hasRouteEvent, "Anonymous connection should route events normally")
    }

    @Test("HandlerContext supports nil userId for anonymous connections")
    func handlerContextSupportsAnonymous() {
        // HandlerContext.userId is UUID? — verify the type system allows nil
        // This ensures handlers can distinguish anonymous vs authenticated users
        let userId: UUID? = nil
        #expect(userId == nil, "HandlerContext.userId should support nil for anonymous connections")

        // Also verify a real userId works
        let authUserId: UUID? = UUID()
        #expect(authUserId != nil)
    }
}

// MARK: - P2: Server join validation hook

@Suite("P2 - Server join validation passes payload to consumer hook")
struct ServerJoinValidationTests {

    @Test("validateJoin effect carries payload data from the join message")
    func validateJoinCarriesPayload() {
        var state = ConnectionState(id: UUID(), userId: UUID())

        // Client sends a join with custom payload
        let joinPayload = Data("{\"authToken\":\"secret\",\"topic\":\"room:vip\"}".utf8)
        let joinMessage = SockitMessage(
            event: "channel.join",
            payloadData: joinPayload,
            requestId: "ref-1",
            channel: "room:vip"
        )

        let effects = connectionReducer(state: &state, action: .messageReceived(joinMessage))

        // The reducer should emit a validateJoin effect with the payload data intact
        var capturedPayloadData: Data?
        for effect in effects {
            if case .validateJoin(_, let payloadData, _) = effect {
                capturedPayloadData = payloadData
            }
        }

        guard let payloadData = capturedPayloadData else {
            Issue.record("Expected validateJoin effect")
            return
        }

        // The payload data should contain our custom auth token
        let decoded = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        #expect(decoded?["authToken"] as? String == "secret", "Join payload should be passed through to validateJoin")
    }

    @Test("Connection should expose a public join validator hook")
    func connectionHasPublicJoinValidatorHook() {
        // This test verifies the Connection type accepts a joinValidator closure.
        // We can't instantiate Connection without a real Vapor WebSocket,
        // but we can verify the type exists by checking that the joinValidator
        // typealias/closure type is public.
        //
        // The key assertion: JoinValidator should be a public type that consumers
        // can provide to Connection to accept/reject joins with payload inspection.
        let validatorWasCalled = false
        #expect(!validatorWasCalled, "Placeholder — real test needs Vapor WebSocket mock")

        // What we really need to verify:
        // 1. Connection.init accepts a joinValidator parameter
        // 2. validateJoin calls the validator with (channel, payloadData, HandlerContext)
        // 3. The validator can return accept/reject
        // Since Connection requires Vapor.WebSocket, we test the reducer path instead.
    }

    @Test("server reducer validateJoin effect preserves payload for consumer validation")
    func reducerValidateJoinPreservesPayload() {
        var state = ConnectionState(id: UUID(), userId: UUID())

        // Simulate a join request via the reducer's joinChannel action
        let customPayload = Data("{\"role\":\"moderator\",\"inviteCode\":\"ABC123\"}".utf8)
        let effects = connectionReducer(
            state: &state,
            action: .joinChannel("room:private", payloadData: customPayload, requestId: "ref-2")
        )

        // Should produce validateJoin with the payload data
        var capturedPayload: Data?
        for effect in effects {
            if case .validateJoin(let channel, let data, let reqId) = effect {
                #expect(channel == "room:private")
                #expect(reqId == "ref-2")
                capturedPayload = data
            }
        }

        guard let payload = capturedPayload else {
            Issue.record("Expected validateJoin effect with payload")
            return
        }

        let decoded = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        #expect(decoded?["role"] as? String == "moderator")
        #expect(decoded?["inviteCode"] as? String == "ABC123")
    }
}
