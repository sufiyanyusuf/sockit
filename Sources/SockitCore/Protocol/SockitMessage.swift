import Foundation

/// Wire format for all WebSocket messages.
///
/// Simple JSON object structure:
/// ```json
/// {
///   "event": "home.get_today",
///   "payload": { ... },
///   "requestId": "uuid-string",  // optional
///   "channel": "user:123"        // optional
/// }
/// ```
///
/// Payload is stored as raw Data to enable single-pass decoding to typed DTOs.
public struct SockitMessage: Sendable, Equatable {
    /// Event name for routing (e.g., "home.get_today", "delivery.skip")
    public let event: String

    /// Raw JSON payload data - decode directly to your typed DTO
    public let payloadData: Data

    /// Optional request ID for request/response correlation
    public let requestId: String?

    /// Optional channel/topic for subscription-based routing
    public let channel: String?

    /// Optional response status (for responses only)
    public let status: ResponseStatus?

    public init(
        event: String,
        payloadData: Data = "{}".data(using: .utf8)!,
        requestId: String? = nil,
        channel: String? = nil,
        status: ResponseStatus? = nil
    ) {
        self.event = event
        self.payloadData = payloadData
        self.requestId = requestId
        self.channel = channel
        self.status = status
    }

    /// Convenience init with an Encodable payload
    public init<T: Encodable>(
        event: String,
        payload: T,
        requestId: String? = nil,
        channel: String? = nil,
        status: ResponseStatus? = nil
    ) throws {
        self.event = event
        self.payloadData = try JSONEncoder().encode(payload)
        self.requestId = requestId
        self.channel = channel
        self.status = status
    }

    /// Decode payload to a typed DTO
    public func decodePayload<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: payloadData)
    }
}

// MARK: - Codable

extension SockitMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case event
        case payload
        case requestId
        case channel
        case status
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.event = try container.decode(String.self, forKey: .event)
        self.requestId = try container.decodeIfPresent(String.self, forKey: .requestId)
        self.channel = try container.decodeIfPresent(String.self, forKey: .channel)
        self.status = try container.decodeIfPresent(ResponseStatus.self, forKey: .status)

        // Decode payload as raw JSON data using a pass-through wrapper
        let payloadValue = try container.decode(RawJSON.self, forKey: .payload)
        self.payloadData = payloadValue.data
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(event, forKey: .event)
        try container.encode(RawJSON(data: payloadData), forKey: .payload)
        try container.encodeIfPresent(requestId, forKey: .requestId)
        try container.encodeIfPresent(channel, forKey: .channel)
        try container.encodeIfPresent(status, forKey: .status)
    }
}

/// Helper to capture raw JSON during decoding
private struct RawJSON: Codable, Equatable {
    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(from decoder: Decoder) throws {
        // Decode to a generic JSON structure, then re-encode to get raw bytes
        // This is still one extra encode, but unavoidable with standard JSONDecoder
        let value = try JSONValue(from: decoder)
        self.data = try JSONEncoder().encode(value)
    }

    func encode(to encoder: Encoder) throws {
        // Decode the raw data back to JSONValue, then encode it
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        try value.encode(to: encoder)
    }
}

// MARK: - JSONValue (minimal, for raw JSON capture only)

/// Internal type for capturing arbitrary JSON structure
private enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            self = .int(int)
        } else if let double = try? container.decode(Double.self) {
            self = .double(double)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Cannot decode JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let v):
            try container.encode(v)
        case .int(let v):
            try container.encode(v)
        case .double(let v):
            try container.encode(v)
        case .string(let v):
            try container.encode(v)
        case .array(let v):
            try container.encode(v)
        case .object(let v):
            try container.encode(v)
        }
    }
}

// MARK: - Factory Methods

extension SockitMessage {
    /// Create a heartbeat message
    public static func heartbeat() -> SockitMessage {
        SockitMessage(event: "heartbeat")
    }

    /// Create a channel join request
    public static func join(channel: String, requestId: String, payloadData: Data = Data("{}".utf8)) -> SockitMessage {
        // Merge the topic into the payload. If the caller provided custom payload,
        // decode it, add "topic", and re-encode. Otherwise use {"topic": channel}.
        let mergedPayload: Data
        if var dict = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] {
            dict["topic"] = channel
            mergedPayload = (try? JSONSerialization.data(withJSONObject: dict)) ?? payloadData
        } else {
            let fallback = ["topic": channel]
            mergedPayload = (try? JSONEncoder().encode(fallback)) ?? Data()
        }
        return SockitMessage(
            event: "channel.join",
            payloadData: mergedPayload,
            requestId: requestId,
            channel: channel
        )
    }

    /// Create a channel leave request
    public static func leave(channel: String) -> SockitMessage {
        SockitMessage(
            event: "channel.leave",
            channel: channel
        )
    }
}

// MARK: - Convenience

extension SockitMessage {
    /// Check if this is a response to a request
    public var isResponse: Bool {
        requestId != nil && !isRequest
    }

    /// Check if this is a request (has requestId and is not a response event)
    public var isRequest: Bool {
        requestId != nil && !event.hasSuffix(".reply") && !event.hasSuffix(".response")
    }

    /// Check if this is a server push (no requestId)
    public var isPush: Bool {
        requestId == nil
    }

    /// Check if this is a heartbeat
    public var isHeartbeat: Bool {
        event == "heartbeat"
    }

    /// Check if this is a channel join
    public var isJoin: Bool {
        event == "channel.join"
    }

    /// Check if this is a channel leave
    public var isLeave: Bool {
        event == "channel.leave"
    }
}
