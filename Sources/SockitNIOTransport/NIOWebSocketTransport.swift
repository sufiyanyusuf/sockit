import Foundation
import SockitCore
import WebSocketKit
import NIOCore
import NIOPosix
import NIOSSL
import NIOWebSocket

/// NIO-based WebSocket transport for Linux (and any platform with WebSocketKit).
/// Mirrors the behavior of `WebSocketTransport` but uses websocket-kit instead of URLSession.
// @unchecked Sendable: All mutable state protected by LockedValue
public final class NIOWebSocketTransport: TransportProtocol, @unchecked Sendable {
    private struct State: Sendable {
        var isConnected: Bool = false
    }

    // WebSocket and EventLoopGroup are not Sendable, protected by access patterns:
    // - ws is only set in onUpgrade (EL thread) and read/nil'd in send/disconnect (caller thread)
    // - eventLoopGroup is set in connect() and nil'd in disconnect(), both from caller thread
    // These are guarded by the state lock for the connected flag, ensuring happens-before ordering.
    private var ws: WebSocket?
    private var eventLoopGroup: (any EventLoopGroup)?

    private let state = LockedValue(State())
    private let continuation: AsyncStream<TransportEvent>.Continuation

    public let events: AsyncStream<TransportEvent>

    public var isConnected: Bool {
        state.withLock { $0.isConnected }
    }

    public init() {
        let (stream, continuation) = AsyncStream.makeStream(of: TransportEvent.self)
        self.events = stream
        self.continuation = continuation
    }

    public func connect(to url: URL, headers: [String: String]) async throws {
        let scheme = url.scheme ?? "ws"
        let host = url.host ?? "localhost"
        let defaultPort = (scheme == "wss" || scheme == "https") ? 443 : 80
        let port = url.port ?? defaultPort
        let path = url.path.isEmpty ? "/" : url.path
        let query = url.query

        var httpHeaders = HTTPHeaders()
        for (key, value) in headers {
            httpHeaders.add(name: key, value: value)
        }

        var configuration = WebSocketClient.Configuration()
        if scheme == "wss" || scheme == "https" {
            configuration.tlsConfiguration = .clientDefault
        }

        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.eventLoopGroup = elg

        try await withCheckedThrowingContinuation { (checkedContinuation: CheckedContinuation<Void, Error>) in
            WebSocket.connect(
                scheme: scheme == "https" ? "wss" : scheme,
                host: host,
                port: port,
                path: path,
                query: query,
                headers: httpHeaders,
                configuration: configuration,
                on: elg
            ) { [weak self] ws in
                guard let self = self else {
                    // Self deallocated during connect — close orphaned WebSocket and resume
                    _ = ws.close(code: .goingAway)
                    checkedContinuation.resume(throwing: WebSocketError.notConnected)
                    return
                }
                self.ws = ws
                self.state.withLock { $0.isConnected = true }
                self.continuation.yield(.connected)
                self.setupHandlers(ws)
                checkedContinuation.resume()
            }.whenFailure { error in
                checkedContinuation.resume(throwing: error)
            }
        }
    }

    public func send(_ data: Data) async throws {
        guard let ws = ws else {
            throw WebSocketError.notConnected
        }

        guard let text = String(data: data, encoding: .utf8) else {
            throw WebSocketError.encodingFailed
        }

        try await ws.send(text)
    }

    public func disconnect(code: UInt16, reason: String) {
        state.withLock { $0.isConnected = false }

        let closeCode: WebSocketErrorCode = code == 1000 ? .normalClosure : .unknown(code)
        _ = ws?.close(code: closeCode)
        ws = nil

        // Shut down the event loop group asynchronously
        let elg = eventLoopGroup
        eventLoopGroup = nil
        if let elg = elg {
            Task.detached {
                try? await elg.shutdownGracefully()
            }
        }
    }

    private func setupHandlers(_ ws: WebSocket) {
        ws.onText { [weak self] _, text in
            guard let self = self else { return }
            if let data = text.data(using: .utf8) {
                self.continuation.yield(.message(data))
            }
        }

        ws.onBinary { [weak self] _, buffer in
            guard let self = self else { return }
            let data = Data(buffer: buffer)
            self.continuation.yield(.message(data))
        }

        ws.onClose.whenComplete { [weak self] result in
            guard let self = self else { return }
            let wasConnected = self.state.withLock { s -> Bool in
                let was = s.isConnected
                s.isConnected = false
                return was
            }
            if wasConnected {
                switch result {
                case .success:
                    self.continuation.yield(.disconnected(nil))
                case .failure(let error):
                    self.continuation.yield(.disconnected(error))
                }
            }
        }
    }
}
