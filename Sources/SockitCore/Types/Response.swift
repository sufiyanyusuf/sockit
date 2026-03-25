import Foundation

/// Response status indicating success or failure
public enum ResponseStatus: String, Sendable, Equatable, Codable {
    case ok
    case error
}

/// An inbound response received over WebSocket.
///
/// Decode the response data to your typed DTO:
/// ```swift
/// let profile = try response.decodeData(ProfileDTO.self)
/// ```
public struct Response: Sendable, Equatable, Codable {
    /// Request ID this response correlates to
    public let requestId: String

    /// Event name from the request
    public let event: String

    /// Response status
    public let status: ResponseStatus

    /// Raw response data - decode to your typed DTO with decodeData()
    public let data: Data

    /// Error details (only present for error responses)
    public let error: ResponseError?

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

    /// Decode the data payload to a typed DTO
    public func decodeData<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    /// Creates a new response
    public init(
        requestId: String,
        event: String,
        status: ResponseStatus,
        data: Data = "{}".data(using: .utf8)!,
        error: ResponseError? = nil,
        channel: String? = nil
    ) {
        self.requestId = requestId
        self.event = event
        self.status = status
        self.data = data
        self.error = error
        self.channel = channel
    }

    /// Creates a response with typed data
    public init<T: Encodable>(
        requestId: String,
        event: String,
        status: ResponseStatus = .ok,
        typedData: T,
        channel: String? = nil
    ) throws {
        self.requestId = requestId
        self.event = event
        self.status = status
        self.data = try JSONEncoder().encode(typedData)
        self.error = nil
        self.channel = channel
    }

    /// Parses a response from a SockitMessage
    public init(from message: SockitMessage) throws {
        guard let requestId = message.requestId else {
            throw ResponseParseError.missingRequestId
        }

        self.requestId = requestId
        self.event = message.event
        self.channel = message.channel

        // Get status directly from message, default to ok
        self.status = message.status ?? .ok

        // For error responses, try to decode error from payload
        if self.status == .error {
            let errorResponse = try? JSONDecoder().decode(ErrorResponse.self, from: message.payloadData)
            self.error = errorResponse?.error
            self.data = "{}".data(using: .utf8)!
        } else {
            // For success, payload IS the data - direct typed response
            self.data = message.payloadData
            self.error = nil
        }
    }
}

/// Internal type for parsing error responses
private struct ErrorResponse: Decodable {
    let error: ResponseError?
}

/// Error parsing a response from a message
public enum ResponseParseError: Error, Sendable {
    case missingRequestId
    case invalidStatus
}

/// Error details from a failed response
public struct ResponseError: Sendable, Equatable, Codable {
    /// Error code (e.g., "not_found", "unauthorized")
    public let code: String

    /// Human-readable error message
    public let message: String

    /// Optional additional details as raw JSON
    public let details: Data?

    public init(code: String, message: String, details: Data? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }

    /// Decode details to a typed DTO
    public func decodeDetails<T: Decodable>(_ type: T.Type) throws -> T? {
        guard let data = details else { return nil }
        return try JSONDecoder().decode(type, from: data)
    }
}

