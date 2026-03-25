import Foundation

// MARK: - SendableRequest (Type-Erased)

/// Type-erased request for internal reducer use.
/// This holds the wire-ready payload as Data, independent of the original typed payload.
public struct SendableRequest: Sendable, Equatable {
    public let id: String
    public let event: String
    public let payloadData: Data
    public let channel: String?
    public let timeout: TimeInterval

    public init(
        id: String = UUID().uuidString,
        event: String,
        payloadData: Data = "{}".data(using: .utf8)!,
        channel: String? = nil,
        timeout: TimeInterval = 30.0
    ) {
        self.id = id
        self.event = event
        self.payloadData = payloadData
        self.channel = channel
        self.timeout = timeout
    }

    /// Create a SendableRequest with a typed payload
    public init<T: Encodable>(
        id: String = UUID().uuidString,
        event: String,
        payload: T,
        channel: String? = nil,
        timeout: TimeInterval = 30.0
    ) throws {
        self.id = id
        self.event = event
        self.payloadData = try JSONEncoder().encode(payload)
        self.channel = channel
        self.timeout = timeout
    }

    /// Convert to wire message
    public func toMessage() -> SockitMessage {
        SockitMessage(
            event: event,
            payloadData: payloadData,
            requestId: id,
            channel: channel
        )
    }
}

// MARK: - Request (Typed)

/// An outbound request to be sent over WebSocket.
///
/// Requests are automatically correlated with responses via the `id` field.
/// Use typed payloads for type-safe encoding:
///
/// ```swift
/// struct GetTodayRequest: Encodable {
///     let date: String
/// }
/// let request = Request(event: "home.get_today", payload: GetTodayRequest(date: "2024-01-14"))
/// ```
public struct Request<Payload: Encodable & Sendable>: Sendable {
    /// Unique identifier for correlating responses
    public let id: String

    /// Event name for routing (e.g., "home.get_today", "delivery.skip")
    public let event: String

    /// Typed request payload
    public let payload: Payload

    /// Optional channel/topic for scoped requests
    public let channel: String?

    /// Timeout in seconds (default: 30)
    public let timeout: TimeInterval

    /// Creates a new request with auto-generated ID
    public init(
        event: String,
        payload: Payload,
        channel: String? = nil,
        timeout: TimeInterval = 30.0
    ) {
        self.id = UUID().uuidString
        self.event = event
        self.payload = payload
        self.channel = channel
        self.timeout = timeout
    }

    /// Creates a new request with custom ID
    public init(
        id: String,
        event: String,
        payload: Payload,
        channel: String? = nil,
        timeout: TimeInterval = 30.0
    ) {
        self.id = id
        self.event = event
        self.payload = payload
        self.channel = channel
        self.timeout = timeout
    }

    /// Converts this request to a wire message
    public func toMessage() throws -> SockitMessage {
        try SockitMessage(
            event: event,
            payload: payload,
            requestId: id,
            channel: channel
        )
    }

    /// Convert to type-erased SendableRequest for reducer use
    public func toSendable() throws -> SendableRequest {
        SendableRequest(
            id: id,
            event: event,
            payloadData: try JSONEncoder().encode(payload),
            channel: channel,
            timeout: timeout
        )
    }
}

// MARK: - Empty Payload Support

/// Empty payload for requests that don't need data
public struct EmptyPayload: Codable, Sendable, Equatable {
    public init() {}
}

extension Request where Payload == EmptyPayload {
    /// Creates a request with no payload
    public init(
        event: String,
        channel: String? = nil,
        timeout: TimeInterval = 30.0
    ) {
        self.id = UUID().uuidString
        self.event = event
        self.payload = EmptyPayload()
        self.channel = channel
        self.timeout = timeout
    }

    /// Creates a request with custom ID and no payload
    public init(
        id: String,
        event: String,
        channel: String? = nil,
        timeout: TimeInterval = 30.0
    ) {
        self.id = id
        self.event = event
        self.payload = EmptyPayload()
        self.channel = channel
        self.timeout = timeout
    }
}
