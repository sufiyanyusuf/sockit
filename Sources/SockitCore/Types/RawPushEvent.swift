import Foundation

/// A server-initiated push event (no request correlation), with raw Data payload for deferred decoding.
///
/// Unlike `PushEvent` which uses `JSONPayload`, this type keeps the payload
/// as raw `Data` to avoid double-parsing. The caller can decode to a specific type
/// using `decodePayload(_:)`.
public struct RawPushEvent: Sendable, Equatable, Codable {
    /// Event name
    public let event: String

    /// Raw event payload as JSON Data
    public let payloadData: Data

    /// Optional channel this event came from
    public let channel: String?

    public init(
        event: String,
        payloadData: Data,
        channel: String? = nil
    ) {
        self.event = event
        self.payloadData = payloadData
        self.channel = channel
    }

    /// Creates from raw JSON data for the entire message.
    /// Extracts the payload portion and stores it for deferred decoding.
    public init(event: String, channel: String?, rawPayloadData: Data) {
        self.event = event
        self.payloadData = rawPayloadData
        self.channel = channel
    }

    /// Decode the payload to a specific type.
    public func decodePayload<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: payloadData)
    }

    /// Decode the payload to a specific type, returning nil if decoding fails.
    public func decodePayloadIfPresent<T: Decodable>(_ type: T.Type) -> T? {
        try? decodePayload(type)
    }
}
