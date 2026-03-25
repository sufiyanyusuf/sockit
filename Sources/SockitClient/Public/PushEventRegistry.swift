import Foundation
import SockitCore

/// Registry for typed push event handlers.
/// Allows registering handlers for specific push event types and routing incoming events.
public actor PushEventRegistry {
    public typealias Handler<P: Decodable & Sendable> = @Sendable (P) async -> Void

    private var handlers: [String: Any] = [:]

    public init() {}

    /// Register a handler for a push event type
    public func on<E: SockitPushEvent>(_ eventType: E.Type, handler: @escaping Handler<E.Payload>) {
        handlers[E.event] = TypedPushHandler(handler: handler)
    }

    /// Remove handler for a push event type
    public func off<E: SockitPushEvent>(_ eventType: E.Type) {
        handlers.removeValue(forKey: E.event)
    }

    /// Route a raw push event to its registered handler
    public func route(_ pushEvent: RawPushEvent) async {
        guard let handler = handlers[pushEvent.event] as? AnyPushHandler else { return }
        await handler.handle(pushEvent.payloadData)
    }

    /// Route using event name and raw data
    public func route(event: String, data: Data) async {
        guard let handler = handlers[event] as? AnyPushHandler else { return }
        await handler.handle(data)
    }
}

// Internal protocol for type erasure
private protocol AnyPushHandler: Sendable {
    func handle(_ data: Data) async
}

private struct TypedPushHandler<P: Decodable & Sendable>: AnyPushHandler, Sendable {
    let handler: @Sendable (P) async -> Void

    func handle(_ data: Data) async {
        guard let payload = try? JSONDecoder().decode(P.self, from: data) else { return }
        await handler(payload)
    }
}
