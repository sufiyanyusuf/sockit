import Foundation

/// An inbound response received over WebSocket, with raw Data payload for deferred decoding.
///
/// Unlike `Response` which uses `JSONPayload`, this type keeps the payload
/// as raw `Data` to avoid double-parsing. The caller can decode to a specific type
/// using `decodeData(_:)`.
public struct RawResponse: Sendable, Equatable {
    /// Request ID this response correlates to
    public let requestId: String

    /// Event name from the request
    public let event: String

    /// Response status
    public let status: ResponseStatus

    /// Raw response data (only present for success responses)
    public let dataPayload: Data

    /// Error details (only present for error responses)
    public let error: RawResponseError?

    /// Optional channel this response came from
    public let channel: String?

    /// Whether this is a successful response
    public var isSuccess: Bool {
        status == .ok
    }

    /// Whether this is an error response
    public var isError: Bool {
        status == .error
    }

    /// Creates a new raw response
    public init(
        requestId: String,
        event: String,
        status: ResponseStatus,
        dataPayload: Data = Data("{}".utf8),
        error: RawResponseError? = nil,
        channel: String? = nil
    ) {
        self.requestId = requestId
        self.event = event
        self.status = status
        self.dataPayload = dataPayload
        self.error = error
        self.channel = channel
    }

    /// Decode the data payload to a specific type.
    public func decodeData<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: dataPayload)
    }

    /// Decode the data payload to a specific type, returning nil if decoding fails.
    public func decodeDataIfPresent<T: Decodable>(_ type: T.Type) -> T? {
        try? decodeData(type)
    }
}

/// Error parsing a raw response from a message
public enum RawResponseParseError: Error, Sendable {
    case missingRequestId
    case invalidJSON
}

/// Error details from a failed response, with raw details Data.
public struct RawResponseError: Sendable, Equatable {
    /// Error code (e.g., "not_found", "unauthorized")
    public let code: String

    /// Human-readable error message
    public let message: String

    /// Optional additional details as raw JSON Data
    public let detailsData: Data?

    public init(code: String, message: String, detailsData: Data? = nil) {
        self.code = code
        self.message = message
        self.detailsData = detailsData
    }

    /// Decode the details to a specific type.
    public func decodeDetails<T: Decodable>(_ type: T.Type) throws -> T? {
        guard let data = detailsData else { return nil }
        return try JSONDecoder().decode(type, from: data)
    }
}
