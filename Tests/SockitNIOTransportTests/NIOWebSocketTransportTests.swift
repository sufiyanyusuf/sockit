import Testing
import Foundation
import SockitCore
@testable import SockitNIOTransport

@Suite("NIOWebSocketTransport")
struct NIOWebSocketTransportTests {

    @Test("initializes in disconnected state")
    func initialState() {
        let transport = NIOWebSocketTransport()
        #expect(transport.isConnected == false)
    }

    @Test("events stream is available immediately")
    func eventsStream() {
        let transport = NIOWebSocketTransport()
        // events should be a valid AsyncStream even before connect
        _ = transport.events
        #expect(transport.isConnected == false)
    }

    @Test("send throws when not connected")
    func sendWhenDisconnected() async throws {
        let transport = NIOWebSocketTransport()
        let data = Data("hello".utf8)

        await #expect(throws: WebSocketError.self) {
            try await transport.send(data)
        }
    }

    @Test("disconnect when not connected is safe")
    func disconnectWhenNotConnected() {
        let transport = NIOWebSocketTransport()
        // Should not crash or throw
        transport.disconnect(code: 1000, reason: "test")
        #expect(transport.isConnected == false)
    }

    @Test("connect to invalid host throws")
    func connectToInvalidHost() async {
        let transport = NIOWebSocketTransport()
        let url = URL(string: "ws://localhost:1")!

        await #expect(throws: Error.self) {
            try await transport.connect(to: url, headers: [:])
        }

        #expect(transport.isConnected == false)
    }

    @Test("multiple disconnects are safe")
    func multipleDisconnects() {
        let transport = NIOWebSocketTransport()
        transport.disconnect(code: 1000, reason: "first")
        transport.disconnect(code: 1000, reason: "second")
        transport.disconnect(code: 1000, reason: "third")
        #expect(transport.isConnected == false)
    }
}

@Suite("NIOWebSocketTransport - TLS")
struct NIOWebSocketTransportTLSTests {

    @Test("wss scheme triggers TLS configuration")
    func wssScheme() async {
        let transport = NIOWebSocketTransport()
        let url = URL(string: "wss://localhost:1")!

        // Should attempt TLS connection (will fail due to invalid host, but shouldn't crash)
        await #expect(throws: Error.self) {
            try await transport.connect(to: url, headers: [:])
        }
    }

    @Test("https scheme is treated as wss")
    func httpsScheme() async {
        let transport = NIOWebSocketTransport()
        let url = URL(string: "https://localhost:1")!

        await #expect(throws: Error.self) {
            try await transport.connect(to: url, headers: [:])
        }
    }
}

@Suite("LockedValue")
struct LockedValueTests {

    @Test("basic read and write")
    func basicReadWrite() {
        let value = LockedValue(0)
        #expect(value.withLock { $0 } == 0)

        value.withLock { $0 = 42 }
        #expect(value.withLock { $0 } == 42)
    }

    @Test("returns value from withLock")
    func returnsValue() {
        let value = LockedValue("hello")
        let result = value.withLock { val -> Int in
            val = "world"
            return val.count
        }
        #expect(result == 5)
        #expect(value.withLock { $0 } == "world")
    }

    @Test("concurrent access is safe")
    func concurrentAccess() async {
        let counter = LockedValue(0)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<1000 {
                group.addTask {
                    counter.withLock { $0 += 1 }
                }
            }
        }

        #expect(counter.withLock { $0 } == 1000)
    }
}
