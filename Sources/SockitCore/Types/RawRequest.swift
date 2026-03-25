import Foundation

/// An outbound request to be sent over WebSocket, with raw Data payload.
///
/// Unlike `Request` which uses `JSONPayload`, this type uses pre-encoded
/// `Data` for the payload, avoiding the overhead of JSON encoding.
///
/// Requests are automatically correlated with responses via the `id` field.
public struct RawRequest: Sendable, Equatable {
    /// Unique identifier for correlating responses
    public let id: String

    /// Event name for routing (e.g., "home.get_today", "delivery.skip")
    public let event: String

    /// Raw request payload as JSON Data
    public let payloadData: Data

    /// Optional channel/topic for scoped requests
    public let channel: String?

    /// Timeout in seconds (default: 30)
    public let timeout: TimeInterval

    /// Creates a new request with auto-generated ID from an Encodable payload.
    public init<T: Encodable>(
        event: String,
        payload: T,
        channel: String? = nil,
        timeout: TimeInterval = 30.0
    ) throws {
        self.id = UUID().uuidString
        self.event = event
        self.payloadData = try JSONEncoder().encode(payload)
        self.channel = channel
        self.timeout = timeout
    }

    /// Creates a new request with custom ID from an Encodable payload.
    public init<T: Encodable>(
        id: String,
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

    /// Creates a new request with auto-generated ID from raw Data payload.
    public init(
        event: String,
        payloadData: Data,
        channel: String? = nil,
        timeout: TimeInterval = 30.0
    ) {
        self.id = UUID().uuidString
        self.event = event
        self.payloadData = payloadData
        self.channel = channel
        self.timeout = timeout
    }

    /// Creates a new request with custom ID from raw Data payload.
    public init(
        id: String,
        event: String,
        payloadData: Data,
        channel: String? = nil,
        timeout: TimeInterval = 30.0
    ) {
        self.id = id
        self.event = event
        self.payloadData = payloadData
        self.channel = channel
        self.timeout = timeout
    }

    /// Creates a new request with empty payload.
    public init(
        event: String,
        channel: String? = nil,
        timeout: TimeInterval = 30.0
    ) {
        self.id = UUID().uuidString
        self.event = event
        self.payloadData = Data("{}".utf8)
        self.channel = channel
        self.timeout = timeout
    }

    /// Creates a new request with custom ID and empty payload.
    public init(
        id: String,
        event: String,
        channel: String? = nil,
        timeout: TimeInterval = 30.0
    ) {
        self.id = id
        self.event = event
        self.payloadData = Data("{}".utf8)
        self.channel = channel
        self.timeout = timeout
    }
}
