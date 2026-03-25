import Foundation

/// Events emitted by the transport layer
public enum TransportEvent: Sendable {
    case connected
    case disconnected(Error?)
    case message(Data)
    case ping
    case pong
}

/// Protocol abstracting WebSocket transport for testability
public protocol TransportProtocol: AnyObject, Sendable {
    /// Stream of transport events
    var events: AsyncStream<TransportEvent> { get }

    /// Whether the transport is currently connected
    var isConnected: Bool { get }

    /// Connect to the given URL with optional headers
    func connect(to url: URL, headers: [String: String]) async throws

    /// Send data over the transport
    func send(_ data: Data) async throws

    /// Disconnect with optional close code and reason
    func disconnect(code: UInt16, reason: String)
}

/// Errors from the WebSocket transport layer
public enum WebSocketError: Error, Sendable {
    case notConnected
    case encodingFailed
}

/// Thread-safe mutable state container using NSLock.
/// Used by transport implementations to protect mutable state across threads.
// @unchecked Sendable: Thread safety guaranteed by NSLock
public final class LockedValue<T: Sendable>: @unchecked Sendable {
    private var _value: T
    private let lock = NSLock()

    public init(_ value: T) {
        self._value = value
    }

    public func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&_value)
    }
}
