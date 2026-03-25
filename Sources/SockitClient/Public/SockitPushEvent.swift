import Foundation
import SockitCore

/// Protocol for type-safe push event handling
public protocol SockitPushEvent: Sendable {
    /// The event name this handler responds to
    static var event: String { get }

    /// The payload type
    associatedtype Payload: Decodable & Sendable
}
