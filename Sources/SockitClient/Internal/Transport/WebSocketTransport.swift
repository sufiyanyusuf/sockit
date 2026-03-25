#if canImport(Darwin)
import Foundation
import SockitCore

/// URLSession-based WebSocket transport implementation (Apple platforms)
// @unchecked Sendable: All mutable state protected by LockedValue
public final class WebSocketTransport: TransportProtocol, @unchecked Sendable {
    private struct State: Sendable {
        var isConnected: Bool = false
        var task: URLSessionWebSocketTask? = nil
    }

    private let session: URLSession
    private let state = LockedValue(State())
    private let continuation: AsyncStream<TransportEvent>.Continuation

    public let events: AsyncStream<TransportEvent>

    public var isConnected: Bool {
        state.withLock { $0.isConnected }
    }

    public init(session: URLSession = .shared) {
        self.session = session
        let (stream, continuation) = AsyncStream.makeStream(of: TransportEvent.self)
        self.events = stream
        self.continuation = continuation
    }

    public func connect(to url: URL, headers: [String: String]) async throws {
        var request = URLRequest(url: url)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let task = session.webSocketTask(with: request)
        state.withLock {
            $0.task = task
            $0.isConnected = true
        }

        task.resume()

        continuation.yield(.connected)
        startReceiving()
    }

    public func send(_ data: Data) async throws {
        guard let task = state.withLock({ $0.task }) else {
            throw WebSocketError.notConnected
        }

        guard let text = String(data: data, encoding: .utf8) else {
            throw WebSocketError.encodingFailed
        }

        try await task.send(.string(text))
    }

    public func disconnect(code: UInt16, reason: String) {
        let task = state.withLock { s -> URLSessionWebSocketTask? in
            s.isConnected = false
            let t = s.task
            s.task = nil
            return t
        }

        let closeCode = URLSessionWebSocketTask.CloseCode(rawValue: Int(code)) ?? .normalClosure
        task?.cancel(with: closeCode, reason: reason.data(using: .utf8))
    }

    private func startReceiving() {
        Task { [weak self] in
            guard let self = self,
                  let task = self.state.withLock({ $0.task })
            else { return }

            do {
                while true {
                    let message = try await task.receive()

                    switch message {
                    case .string(let text):
                        if let data = text.data(using: .utf8) {
                            self.continuation.yield(.message(data))
                        }
                    case .data(let data):
                        self.continuation.yield(.message(data))
                    @unknown default:
                        break
                    }
                }
            } catch {
                self.state.withLock { $0.isConnected = false }
                self.continuation.yield(.disconnected(error))
            }
        }
    }
}
#endif
