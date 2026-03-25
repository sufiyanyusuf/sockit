import Testing
import Foundation
@testable import SockitCore

// MARK: - Test Payload Types

private struct TestPayload: Codable, Sendable, Equatable {
    let key: String
}

private struct ReasonPayload: Codable, Sendable {
    let reason: String
}

private struct WeekPayload: Codable, Sendable, Equatable {
    let week: Int
    let includeSwaps: Bool
}

// MARK: - SockitMessage Encoding Tests

@Suite("SockitMessage Encoding")
struct SockitMessageEncodingTests {

    @Test("encodes to JSON with all fields")
    func encodesAllFields() throws {
        let message = try SockitMessage(
            event: "home.get_today",
            payload: TestPayload(key: "value"),
            requestId: "req-123",
            channel: "user:456"
        )

        let data = try JSONEncoder().encode(message)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(json?["event"] as? String == "home.get_today")
        #expect(json?["requestId"] as? String == "req-123")
        #expect(json?["channel"] as? String == "user:456")

        let payload = json?["payload"] as? [String: Any]
        #expect(payload?["key"] as? String == "value")
    }

    @Test("encodes with nil optional fields omitted")
    func encodesNilFieldsOmitted() throws {
        let message = SockitMessage(
            event: "test.event",
            requestId: nil,
            channel: nil
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(message)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(json?["event"] as? String == "test.event")
        #expect(json?["payload"] != nil)
        #expect(json?["requestId"] == nil)
        #expect(json?["channel"] == nil)
    }

    @Test("decodes from JSON with all fields")
    func decodesAllFields() throws {
        let json = """
        {
            "event": "delivery.skip",
            "payload": {"reason": "vacation"},
            "requestId": "req-789",
            "channel": "user:self"
        }
        """.data(using: .utf8)!

        let message = try JSONDecoder().decode(SockitMessage.self, from: json)

        #expect(message.event == "delivery.skip")
        #expect(message.requestId == "req-789")
        #expect(message.channel == "user:self")

        let payload = try message.decodePayload(ReasonPayload.self)
        #expect(payload.reason == "vacation")
    }

    @Test("decodes from JSON with missing optional fields")
    func decodesMissingOptionalFields() throws {
        let json = """
        {
            "event": "heartbeat",
            "payload": {}
        }
        """.data(using: .utf8)!

        let message = try JSONDecoder().decode(SockitMessage.self, from: json)

        #expect(message.event == "heartbeat")
        #expect(message.requestId == nil)
        #expect(message.channel == nil)
    }

    @Test("roundtrip encoding preserves data")
    func roundtripPreservesData() throws {
        let original = try SockitMessage(
            event: "menu.get_week",
            payload: WeekPayload(week: 1, includeSwaps: true),
            requestId: "uuid-123",
            channel: "user:42"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SockitMessage.self, from: data)

        #expect(decoded.event == original.event)
        #expect(decoded.requestId == original.requestId)
        #expect(decoded.channel == original.channel)

        let originalPayload = try original.decodePayload(WeekPayload.self)
        let decodedPayload = try decoded.decodePayload(WeekPayload.self)
        #expect(decodedPayload == originalPayload)
    }
}

// MARK: - SockitMessage Equatable Tests

@Suite("SockitMessage Equatable")
struct SockitMessageEquatableTests {

    @Test("equal messages are equal")
    func equalMessagesAreEqual() {
        let msg1 = SockitMessage(event: "test", requestId: "1", channel: nil)
        let msg2 = SockitMessage(event: "test", requestId: "1", channel: nil)

        #expect(msg1 == msg2)
    }

    @Test("different events are not equal")
    func differentEventsNotEqual() {
        let msg1 = SockitMessage(event: "event.a", requestId: nil, channel: nil)
        let msg2 = SockitMessage(event: "event.b", requestId: nil, channel: nil)

        #expect(msg1 != msg2)
    }
}

// MARK: - Typed Payload Tests

@Suite("Typed Payload")
struct TypedPayloadTests {

    @Test("decodePayload decodes to typed struct")
    func decodePayloadDecodesToTypedStruct() throws {
        let json = """
        {"event":"test","payload":{"week":1,"includeSwaps":true}}
        """.data(using: .utf8)!

        let message = try JSONDecoder().decode(SockitMessage.self, from: json)
        let payload = try message.decodePayload(WeekPayload.self)

        #expect(payload.week == 1)
        #expect(payload.includeSwaps == true)
    }

    @Test("typed init encodes payload correctly")
    func typedInitEncodesPayloadCorrectly() throws {
        let message = try SockitMessage(
            event: "test",
            payload: TestPayload(key: "myvalue"),
            requestId: "1"
        )

        let decoded = try message.decodePayload(TestPayload.self)
        #expect(decoded.key == "myvalue")
    }

    @Test("nested types decode correctly")
    func nestedTypesDecodeCorrectly() throws {
        struct Outer: Codable {
            struct Inner: Codable {
                let value: Int
            }
            let inner: Inner
        }

        let json = """
        {"event":"test","payload":{"inner":{"value":42}}}
        """.data(using: .utf8)!

        let message = try JSONDecoder().decode(SockitMessage.self, from: json)
        let payload = try message.decodePayload(Outer.self)

        #expect(payload.inner.value == 42)
    }

    @Test("array payload decodes correctly")
    func arrayPayloadDecodesCorrectly() throws {
        let json = """
        {"event":"test","payload":[1,2,3]}
        """.data(using: .utf8)!

        let message = try JSONDecoder().decode(SockitMessage.self, from: json)
        let payload = try message.decodePayload([Int].self)

        #expect(payload == [1, 2, 3])
    }
}
