import Testing
import Foundation
@testable import SockitCore

// MARK: - Request Tests

/// Test payload for Request tests
private struct TestPayload: Codable, Sendable, Equatable {
    let week: Int
}

@Suite("Request")
struct RequestTests {

    @Test("creates with auto-generated ID")
    func createsWithAutoId() {
        let request = Request<EmptyPayload>(event: "home.get_today")

        #expect(!request.id.isEmpty)
        #expect(request.event == "home.get_today")
    }

    @Test("creates with custom ID")
    func createsWithCustomId() {
        let request = Request<EmptyPayload>(id: "custom-id", event: "test")

        #expect(request.id == "custom-id")
    }

    @Test("has default timeout of 30 seconds")
    func hasDefaultTimeout() {
        let request = Request<EmptyPayload>(event: "test")

        #expect(request.timeout == 30.0)
    }

    @Test("accepts custom timeout")
    func acceptsCustomTimeout() {
        let request = Request<EmptyPayload>(event: "test", timeout: 60.0)

        #expect(request.timeout == 60.0)
    }

    @Test("accepts channel")
    func acceptsChannel() {
        let request = Request<EmptyPayload>(event: "test", channel: "user:123")

        #expect(request.channel == "user:123")
    }

    @Test("converts to SockitMessage")
    func convertsToSockitMessage() throws {
        let request = Request(
            id: "req-123",
            event: "menu.get_week",
            payload: TestPayload(week: 1),
            channel: "user:self"
        )

        let message = try request.toMessage()

        #expect(message.event == "menu.get_week")
        #expect(message.requestId == "req-123")
        #expect(message.channel == "user:self")

        let decoded = try message.decodePayload(TestPayload.self)
        #expect(decoded.week == 1)
    }

    @Test("different requests have different IDs")
    func differentRequestsHaveDifferentIds() {
        let request1 = Request<EmptyPayload>(event: "test")
        let request2 = Request<EmptyPayload>(event: "test")

        #expect(request1.id != request2.id)
    }

    @Test("is Sendable")
    func isSendable() async {
        let request = Request<EmptyPayload>(event: "test")

        // Should compile - Request is Sendable
        await Task {
            _ = request.id
        }.value
    }
}

// MARK: - Response Tests

/// Test response data type
private struct DateResponse: Codable, Equatable {
    let date: String
}

@Suite("Response")
struct ResponseTests {

    @Test("creates success response")
    func createsSuccessResponse() throws {
        let responseData = try JSONEncoder().encode(DateResponse(date: "2024-01-14"))
        let response = Response(
            requestId: "req-123",
            event: "home.get_today",
            status: .ok,
            data: responseData
        )

        #expect(response.requestId == "req-123")
        #expect(response.event == "home.get_today")
        #expect(response.status == .ok)
        #expect(response.isSuccess)
        #expect(!response.isError)

        let decoded = try response.decodeData(DateResponse.self)
        #expect(decoded.date == "2024-01-14")
    }

    @Test("creates error response")
    func createsErrorResponse() {
        let response = Response(
            requestId: "req-456",
            event: "delivery.skip",
            status: .error,
            error: ResponseError(code: "not_found", message: "Delivery not found")
        )

        #expect(response.requestId == "req-456")
        #expect(response.status == .error)
        #expect(response.isError)
        #expect(!response.isSuccess)
        #expect(response.error?.code == "not_found")
        #expect(response.error?.message == "Delivery not found")
    }

    @Test("parses from SockitMessage with ok status")
    func parsesFromOkMessage() throws {
        // Create payload JSON with status and data
        let payloadJSON = """
        {"status": "ok", "data": {"date": "2024-01-14"}}
        """
        let message = SockitMessage(
            event: "home.get_today",
            payloadData: Data(payloadJSON.utf8),
            requestId: "req-789"
        )

        let response = try Response(from: message)

        #expect(response.requestId == "req-789")
        #expect(response.status == .ok)
        #expect(response.isSuccess)
    }

    @Test("parses from SockitMessage with error status")
    func parsesFromErrorMessage() throws {
        // Error responses have status in message and error details in payload
        let payloadJSON = """
        {"error": {"code": "unauthorized", "message": "Not allowed"}}
        """
        let message = SockitMessage(
            event: "delivery.skip",
            payloadData: Data(payloadJSON.utf8),
            requestId: "req-101",
            status: .error
        )

        let response = try Response(from: message)

        #expect(response.status == .error)
        #expect(response.isError)
        #expect(response.error?.code == "unauthorized")
    }

    @Test("throws when parsing message without requestId")
    func throwsWithoutRequestId() {
        let payloadJSON = """
        {"status": "ok"}
        """
        let message = SockitMessage(
            event: "test",
            payloadData: Data(payloadJSON.utf8),
            requestId: nil
        )

        #expect(throws: ResponseParseError.self) {
            _ = try Response(from: message)
        }
    }

    @Test("accepts optional channel")
    func acceptsOptionalChannel() {
        let response = Response(
            requestId: "req-1",
            event: "test",
            status: .ok,
            channel: "user:123"
        )

        #expect(response.channel == "user:123")
    }
}

// MARK: - PushEvent Tests

/// Test push payload type
private struct StatusPayload: Codable, Equatable {
    let status: String
}

private struct OrderPayload: Codable, Equatable {
    let orderId: String
}

@Suite("PushEvent")
struct PushEventTests {

    @Test("creates push event")
    func createsPushEvent() throws {
        let push = try PushEvent(
            event: "delivery.status_changed",
            payload: StatusPayload(status: "delivered"),
            channel: "user:123"
        )

        #expect(push.event == "delivery.status_changed")
        #expect(push.channel == "user:123")

        let decoded = try push.decodePayload(StatusPayload.self)
        #expect(decoded.status == "delivered")
    }

    @Test("parses from SockitMessage")
    func parsesFromMessage() throws {
        let message = try SockitMessage(
            event: "order.updated",
            payload: OrderPayload(orderId: "order-123"),
            requestId: nil,
            channel: "orders:456"
        )

        let push = PushEvent(from: message)

        #expect(push.event == "order.updated")
        #expect(push.channel == "orders:456")
    }

    @Test("is Sendable")
    func isSendable() async {
        let push = PushEvent(event: "test")

        await Task {
            _ = push.event
        }.value
    }
}

// MARK: - ResponseError Tests

@Suite("ResponseError")
struct ResponseErrorTests {

    @Test("creates with code and message")
    func createsWithCodeAndMessage() {
        let error = ResponseError(code: "invalid_input", message: "Email is invalid")

        #expect(error.code == "invalid_input")
        #expect(error.message == "Email is invalid")
    }

    @Test("is Equatable")
    func isEquatable() {
        let error1 = ResponseError(code: "test", message: "Test message")
        let error2 = ResponseError(code: "test", message: "Test message")
        let error3 = ResponseError(code: "other", message: "Other message")

        #expect(error1 == error2)
        #expect(error1 != error3)
    }

    @Test("accepts optional details")
    func acceptsOptionalDetails() throws {
        let detailsData = try JSONEncoder().encode(["field": "email"])
        let error = ResponseError(
            code: "validation_error",
            message: "Validation failed",
            details: detailsData
        )

        let decoded = try error.decodeDetails([String: String].self)
        #expect(decoded?["field"] == "email")
    }
}
