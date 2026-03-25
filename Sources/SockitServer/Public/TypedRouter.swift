import Foundation
import SockitCore

/// A type-erased handler wrapper that enables heterogeneous storage.
public struct AnyTypedHandler: Sendable {
    private let _handle: @Sendable (Data, HandlerContext) async throws -> Data

    /// Create a type-erased wrapper from a SockitHandler
    public init<H: SockitHandler>(_ handler: H) {
        self._handle = { payloadData, context in
            // Decode directly to the handler's typed Request
            let request = try JSONDecoder().decode(H.Request.self, from: payloadData)
            // Call handler with typed request
            let response = try await handler.handle(request: request, context: context)
            // Encode typed response directly to Data
            return try JSONEncoder().encode(response)
        }
    }

    /// Create a type-erased wrapper from a SockitHandlerNoPayload
    public init<H: SockitHandlerNoPayload>(_ handler: H) {
        self._handle = { _, context in
            // No payload to decode, just call handler
            let response = try await handler.handle(context: context)
            // Encode typed response directly to Data
            return try JSONEncoder().encode(response)
        }
    }

    /// Handle a request and return the encoded response
    public func handle(payloadData: Data, context: HandlerContext) async throws -> Data {
        try await _handle(payloadData, context)
    }
}

/// Errors that can occur during typed routing
public enum TypedRouterError: Error, LocalizedError {
    case handlerNotFound(event: String)
    case decodingFailed(event: String, error: Error)
    case encodingFailed(event: String, error: Error)

    public var errorDescription: String? {
        switch self {
        case .handlerNotFound(let event):
            return "No handler registered for event: \(event)"
        case .decodingFailed(let event, let error):
            return "Failed to decode request for \(event): \(error.localizedDescription)"
        case .encodingFailed(let event, let error):
            return "Failed to encode response for \(event): \(error.localizedDescription)"
        }
    }
}

/// A router that manages type-safe event handlers.
///
/// Register handlers and route incoming events to them:
/// ```swift
/// let router = TypedRouter()
/// await router.register(GetProfileHandler(userRepo: userRepo))
/// await router.register(UpdateProfileHandler(userRepo: userRepo))
/// ```
public actor TypedRouter {
    private var handlers: [String: AnyTypedHandler] = [:]

    public init() {}

    /// Register a handler with a request payload
    public func register<H: SockitHandler>(_ handler: H) {
        handlers[H.event] = AnyTypedHandler(handler)
    }

    /// Register a handler without a request payload
    public func register<H: SockitHandlerNoPayload>(_ handler: H) {
        handlers[H.event] = AnyTypedHandler(handler)
    }

    /// Route an event to its handler
    /// - Parameters:
    ///   - event: The event name to route
    ///   - payloadData: Raw JSON payload data
    ///   - context: Handler context with connection info
    /// - Returns: Encoded response data
    public func route(
        event: String,
        payloadData: Data,
        context: HandlerContext
    ) async throws -> Data {
        guard let handler = handlers[event] else {
            throw TypedRouterError.handlerNotFound(event: event)
        }

        do {
            return try await handler.handle(payloadData: payloadData, context: context)
        } catch let error as DecodingError {
            throw TypedRouterError.decodingFailed(event: event, error: error)
        } catch let error as EncodingError {
            throw TypedRouterError.encodingFailed(event: event, error: error)
        }
    }

    /// Check if a handler is registered for an event
    public func hasHandler(for event: String) -> Bool {
        handlers[event] != nil
    }

    /// Get all registered event names
    public func registeredEvents() -> [String] {
        Array(handlers.keys)
    }
}
