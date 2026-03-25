import Foundation
import SockitCore

/// Protocol for type-safe WebSocket commands.
/// Each command declares its response type at compile time.
public protocol SockitCommand: Sendable {
    /// The response type returned by this command
    associatedtype Response: Decodable & Sendable

    /// The event name for routing (e.g., "profile.get")
    static var event: String { get }

    /// Optional channel/scope for the request (default: nil)
    var channel: String? { get }

    /// Request timeout in seconds (default: 30)
    var timeout: TimeInterval { get }
}

// Default implementations
extension SockitCommand {
    public var channel: String? { nil }
    public var timeout: TimeInterval { 30.0 }
}

/// Commands that send a payload in the request body
public protocol SockitCommandWithPayload: SockitCommand, Encodable {}
