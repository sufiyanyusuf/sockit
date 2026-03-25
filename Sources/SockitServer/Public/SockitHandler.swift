import Foundation

/// Protocol for type-safe WebSocket event handlers with request payloads.
///
/// Use this protocol when your handler expects a typed request payload:
/// ```swift
/// struct UpdateProfileHandler: SockitHandler {
///     typealias Request = UpdateProfileRequest
///     typealias Response = UpdateProfileResponse
///     static let event = "profile.update"
///
///     func handle(request: Request, context: HandlerContext) async throws -> Response {
///         // Handle the request
///     }
/// }
/// ```
public protocol SockitHandler: Sendable {
    /// The typed request payload (decoded from JSON)
    associatedtype Request: Decodable & Sendable

    /// The typed response payload (encoded to JSON)
    associatedtype Response: Encodable & Sendable

    /// The event name this handler responds to (e.g., "profile.update")
    static var event: String { get }

    /// Handle the request and return a typed response
    func handle(request: Request, context: HandlerContext) async throws -> Response
}

/// Protocol for type-safe WebSocket event handlers without request payloads.
///
/// Use this protocol when your handler doesn't need any request data:
/// ```swift
/// struct GetProfileHandler: SockitHandlerNoPayload {
///     typealias Response = GetProfileResponse
///     static let event = "profile.get"
///
///     func handle(context: HandlerContext) async throws -> Response {
///         // Handle the request
///     }
/// }
/// ```
public protocol SockitHandlerNoPayload: Sendable {
    /// The typed response payload (encoded to JSON)
    associatedtype Response: Encodable & Sendable

    /// The event name this handler responds to (e.g., "profile.get")
    static var event: String { get }

    /// Handle the request and return a typed response
    func handle(context: HandlerContext) async throws -> Response
}

/// Context provided to handlers for accessing connection info and services.
public struct HandlerContext: Sendable {
    /// The connection that sent the request
    public let connection: Connection

    /// User ID associated with the connection (if authenticated)
    public let userId: UUID?

    public init(connection: Connection, userId: UUID?) {
        self.connection = connection
        self.userId = userId
    }
}
