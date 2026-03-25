import Foundation

/// A server-initiated push event (no request correlation).
///
/// Decode the payload to your typed DTO:
/// ```swift
/// let update = try push.decodePayload(DeliveryUpdateDTO.self)
/// ```
public struct PushEvent: Sendable, Equatable {
    /// Event name
    public let event: String

    /// Raw event payload data - decode to your typed DTO
    public let payloadData: Data

    /// Optional channel this event came from
    public let channel: String?

    public init(
        event: String,
        payloadData: Data = "{}".data(using: .utf8)!,
        channel: String? = nil
    ) {
        self.event = event
        self.payloadData = payloadData
        self.channel = channel
    }

    /// Creates with a typed payload
    public init<T: Encodable>(
        event: String,
        payload: T,
        channel: String? = nil
    ) throws {
        self.event = event
        self.payloadData = try JSONEncoder().encode(payload)
        self.channel = channel
    }

    /// Creates from a SockitMessage
    public init(from message: SockitMessage) {
        self.event = message.event
        self.payloadData = message.payloadData
        self.channel = message.channel
    }

    /// Decode payload to a typed DTO
    public func decodePayload<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: payloadData)
    }
}
