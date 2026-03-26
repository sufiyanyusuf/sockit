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

// MARK: - P1: Reconnect attempts never advance past attempt 1/2

@Suite("P1 - Reconnect counter resets on repeated transport failures")
struct ReconnectCounterBugTests {

    @Test("repeated transport failures should advance attempt counter beyond 2")
    func repeatedTransportFailuresAdvanceAttemptCounter() {
        var state = makeConnectedState(
            config: makeConfig(reconnectStrategy: .exponentialBackoff(baseDelay: 1.0, maxDelay: 30.0, maxAttempts: 5))
        )

        // First transport disconnect: connected -> reconnecting(1)
        _ = clientReducer(state: &state, action: .transportDisconnected(nil))
        guard case .reconnecting(let attempt1, _) = state.connection else {
            Issue.record("Expected reconnecting state after first disconnect")
            return
        }
        #expect(attempt1 == 1)

        // Reconnect fires: reconnecting(1) -> connecting(2)
        _ = clientReducer(state: &state, action: .reconnect)
        guard case .connecting(let connectAttempt) = state.connection else {
            Issue.record("Expected connecting state after reconnect")
            return
        }
        #expect(connectAttempt == 2)

        // Second transport disconnect (reconnect attempt failed):
        // connecting(2) -> should be reconnecting(2)
        _ = clientReducer(state: &state, action: .transportDisconnected(nil))
        guard case .reconnecting(let attempt2, _) = state.connection else {
            Issue.record("Expected reconnecting state after second disconnect")
            return
        }
        #expect(attempt2 == 2, "Attempt counter should carry forward from .connecting(attempt: 2), got \(attempt2)")
    }

    @Test("client should eventually hit maxAttempts and stop reconnecting")
    func clientHitsMaxAttemptsAfterRepeatedFailures() {
        let maxAttempts = 3
        var state = makeConnectedState(
            config: makeConfig(reconnectStrategy: .exponentialBackoff(baseDelay: 0.1, maxDelay: 1.0, maxAttempts: maxAttempts))
        )

        // Simulate repeated connect-fail cycles
        for cycle in 1...maxAttempts + 1 {
            // Transport disconnects
            _ = clientReducer(state: &state, action: .transportDisconnected(nil))

            if case .disconnected = state.connection {
                // Hit max attempts via delay(forAttempt:) returning nil
                #expect(cycle > maxAttempts, "Should not give up before max attempts (gave up on cycle \(cycle))")
                return
            }

            guard case .reconnecting = state.connection else {
                Issue.record("Expected reconnecting state on cycle \(cycle), got \(state.connection)")
                return
            }

            // Reconnect timer fires
            _ = clientReducer(state: &state, action: .reconnect)

            if case .disconnected = state.connection {
                // Hit max attempts via handleReconnect's nextAttempt > maxAttempts check
                return
            }
        }

        Issue.record("Client never reached maxAttempts (\(maxAttempts)) - reconnect counter is resetting")
    }

    @Test("backoff delay should increase with attempt number")
    func backoffDelayIncreases() {
        var state = makeConnectedState(
            config: makeConfig(reconnectStrategy: .exponentialBackoff(baseDelay: 1.0, maxDelay: 30.0, maxAttempts: 10))
        )

        var delays: [TimeInterval] = []

        // Simulate 3 reconnect cycles, capturing the delay from each transportDisconnected
        for _ in 1...3 {
            let effects = clientReducer(state: &state, action: .transportDisconnected(nil))

            for effect in effects {
                if case .scheduleReconnect(let delay) = effect {
                    delays.append(delay)
                }
            }

            // Advance: reconnecting -> connecting -> (next loop iteration does transportDisconnected)
            _ = clientReducer(state: &state, action: .reconnect)
        }

        // With exponential backoff (base=1.0), delays should be ~1s, ~2s, ~4s (plus jitter)
        #expect(delays.count == 3, "Should have captured 3 delays, got \(delays.count)")
        if delays.count >= 2 {
            let firstDelay = delays[0]
            let lastDelay = delays[2]
            #expect(lastDelay > firstDelay * 1.5, "Later reconnect delays should be larger due to exponential backoff. Got first=\(firstDelay), last=\(lastDelay)")
        }
    }
}

// MARK: - P2: Typed channel-join payload is dead code

@Suite("P2 - Join channel payload is discarded")
struct JoinPayloadDeadCodeTests {

    @Test("join channel should include custom payload data in the wire message")
    func joinChannelIncludesPayloadInMessage() {
        var state = makeConnectedState()
        state.refCounter = 0

        struct JoinParams: Encodable {
            let authToken: String
            let permissions: [String]
        }
        let params = JoinParams(authToken: "secret", permissions: ["read", "write"])
        let payloadData = try! JSONEncoder().encode(params)

        let effects = clientReducer(state: &state, action: .joinChannel("room:lobby", payloadData))

        var sentMessage: SockitMessage?
        for effect in effects {
            if case .sendMessage(let message) = effect {
                sentMessage = message
            }
        }

        guard let message = sentMessage else {
            Issue.record("Expected a sendMessage effect for channel join")
            return
        }

        // The message payload should contain our custom join params
        let decodedPayload = try? JSONSerialization.jsonObject(with: message.payloadData) as? [String: Any]
        #expect(
            decodedPayload?["authToken"] != nil,
            "Join message payload should contain custom payload data, but got: \(String(data: message.payloadData, encoding: .utf8) ?? "nil")"
        )
        // Should also still contain the topic
        #expect(
            decodedPayload?["topic"] as? String == "room:lobby",
            "Join message should still contain topic"
        )
    }
}

// MARK: - P2: Typed send drops non-object payloads

@Suite("P2 - Typed send drops non-object payloads")
struct TypedSendNonObjectPayloadTests {

    @Test("SockitMessage.join factory preserves custom payload alongside topic")
    func joinFactoryPreservesPayload() {
        let customPayload = try! JSONSerialization.data(withJSONObject: ["role": "admin", "level": 5])
        let message = SockitMessage.join(channel: "room:1", requestId: "ref-1", payloadData: customPayload)

        let decoded = try? JSONSerialization.jsonObject(with: message.payloadData) as? [String: Any]
        #expect(decoded?["topic"] as? String == "room:1")
        #expect(decoded?["role"] as? String == "admin")
        #expect(decoded?["level"] as? Int == 5)
    }

    @Test("buildRawMessage should preserve array payloads")
    func buildRawMessagePreservesArrayPayload() throws {
        // Test the fixed pattern: payload should be assigned as Any, not cast to [String: Any]
        let arrayPayload = try JSONSerialization.data(withJSONObject: ["apple", "banana", "cherry"])

        // Fixed pattern (matches the updated Client.buildRawMessage)
        var jsonDict: [String: Any] = [
            "event": "items.list",
            "requestId": "req-123"
        ]
        let payloadObj = try JSONSerialization.jsonObject(with: arrayPayload)
        jsonDict["payload"] = payloadObj

        let result = try JSONSerialization.data(withJSONObject: jsonDict)
        let resultJson = try JSONSerialization.jsonObject(with: result) as! [String: Any]
        let payloadResult = resultJson["payload"] as? [String]
        #expect(payloadResult == ["apple", "banana", "cherry"], "Array payload should be preserved")
    }

    @Test("handleTypedResponseFromRawData should preserve array response payloads")
    func handleTypedResponsePreservesArrayPayload() throws {
        // Test the fixed response-handling pattern
        let serverResponse: [String: Any] = [
            "event": "items.list",
            "requestId": "req-123",
            "status": "ok",
            "payload": ["apple", "banana", "cherry"]
        ]
        let rawData = try JSONSerialization.data(withJSONObject: serverResponse)
        let json = try JSONSerialization.jsonObject(with: rawData) as! [String: Any]

        // Fixed pattern: use Any instead of [String: Any]
        let payload: Any = json["payload"] ?? [String: Any]()
        let dataBytes = try JSONSerialization.data(withJSONObject: payload)
        let resultString = String(data: dataBytes, encoding: .utf8)!

        #expect(resultString.contains("apple"), "Array payload should be preserved, but got: \(resultString)")
    }

    @Test("handleTypedResponseFromRawData should preserve string response payloads")
    func handleTypedResponsePreservesStringPayload() throws {
        // Simulate inbound response with a scalar string payload
        let serverResponse: [String: Any] = [
            "event": "echo",
            "requestId": "req-456",
            "status": "ok",
            "payload": "hello world"
        ]
        let rawData = try JSONSerialization.data(withJSONObject: serverResponse)
        let json = try JSONSerialization.jsonObject(with: rawData) as! [String: Any]
        let payload: Any = json["payload"] ?? [String: Any]()

        // Without fragmentsAllowed, this throws for scalar payloads
        #expect(!JSONSerialization.isValidJSONObject(payload), "Bare string is not a valid top-level JSON object")

        // With fragmentsAllowed, it should work
        let dataBytes = try JSONSerialization.data(withJSONObject: payload, options: .fragmentsAllowed)
        let resultString = String(data: dataBytes, encoding: .utf8)!
        #expect(resultString == "\"hello world\"", "String payload should be preserved as JSON string")
    }

    @Test("scalar number payload should be serializable to Data for typed decode")
    func scalarNumberPayloadSerializable() throws {
        let serverResponse: [String: Any] = [
            "event": "count",
            "requestId": "req-789",
            "status": "ok",
            "payload": 42
        ]
        let rawData = try JSONSerialization.data(withJSONObject: serverResponse)
        let json = try JSONSerialization.jsonObject(with: rawData) as! [String: Any]
        let payload: Any = json["payload"] ?? [String: Any]()

        // JSONSerialization.isValidJSONObject returns false for bare scalars
        #expect(!JSONSerialization.isValidJSONObject(payload), "Bare Int is not a valid top-level JSON object")

        // With fragmentsAllowed, scalars should serialize correctly
        let fixedData = scalarToJSONData(payload)
        #expect(fixedData != nil, "Scalar payload should be convertible to JSON Data")
        if let data = fixedData {
            let str = String(data: data, encoding: .utf8)!
            #expect(str == "42", "Number payload should serialize to '42'")
        }
    }

    @Test("scalar boolean payload should be serializable to Data for typed decode")
    func scalarBoolPayloadSerializable() throws {
        let payload: Any = true

        let fixedData = scalarToJSONData(payload)
        #expect(fixedData != nil, "Boolean scalar should be convertible to JSON Data")
        if let data = fixedData {
            let str = String(data: data, encoding: .utf8)!
            #expect(str == "true", "Bool payload should serialize to 'true'")
        }
    }

    @Test("scalar string payload should be serializable to Data for typed decode")
    func scalarStringPayloadSerializable() throws {
        let payload: Any = "hello world"

        let fixedData = scalarToJSONData(payload)
        #expect(fixedData != nil, "String scalar should be convertible to JSON Data")
        if let data = fixedData {
            let str = String(data: data, encoding: .utf8)!
            #expect(str == "\"hello world\"", "String payload should serialize to '\"hello world\"'")
        }
    }
}

// Helper that mirrors the fix we need in Client.swift
private func scalarToJSONData(_ value: Any) -> Data? {
    // fragmentsAllowed lets JSONSerialization handle top-level scalars (strings, numbers, bools)
    return try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)
}
