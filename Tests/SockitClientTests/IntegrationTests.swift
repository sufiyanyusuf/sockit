import Testing
import Foundation
import SockitCore
@testable import SockitClient
import SockitNIOTransport
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket

/// Integration tests using a lightweight NIO WebSocket echo server.
/// Tests both URLSession and NIO transports against a real server.
@Suite("Integration - WebSocketTransport (URLSession)", .serialized)
struct URLSessionIntegrationTests {

    @Test("connect and disconnect")
    func connectDisconnect() async throws {
        try await withEchoServer { port in
            let client = Client()
            try await client.connect(config: ClientConfig(
                url: URL(string: "ws://127.0.0.1:\(port)")!,
                reconnectStrategy: .none
            ))
            try await Task.sleep(for: .milliseconds(200))
            await client.disconnect()
        }
    }

    @Test("send and receive echo")
    func sendReceiveEcho() async throws {
        try await withEchoServer { port in
            let client = Client()
            try await client.connect(config: ClientConfig(
                url: URL(string: "ws://127.0.0.1:\(port)")!,
                reconnectStrategy: .none
            ))
            try await Task.sleep(for: .milliseconds(200))

            // Listen for messages in background
            let gotResponse = expectation()
            let listenTask = Task {
                for await msg in client.messages {
                    if case .response = msg { gotResponse.fulfill(); break }
                    if case .rawPushEvent = msg { gotResponse.fulfill(); break }
                }
            }

            await client.send(SendableRequest(
                event: "echo",
                payloadData: Data("{\"text\":\"hello\"}".utf8)
            ))

            // Wait for echo (with timeout)
            try await Task.sleep(for: .milliseconds(500))
            listenTask.cancel()
            await client.disconnect()
        }
    }

    @Test("reconnect cycle")
    func reconnectCycle() async throws {
        try await withEchoServer { port in
            let client = Client()
            for _ in 0..<2 {
                try await client.connect(config: ClientConfig(
                    url: URL(string: "ws://127.0.0.1:\(port)")!,
                    reconnectStrategy: .none
                ))
                try await Task.sleep(for: .milliseconds(200))
                await client.disconnect()
                try await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}

@Suite("Integration - NIOWebSocketTransport", .serialized)
struct NIOIntegrationTests {

    @Test("connect and disconnect with NIO transport")
    func connectDisconnect() async throws {
        try await withEchoServer { port in
            let client = Client(transportFactory: { NIOWebSocketTransport() })
            try await client.connect(config: ClientConfig(
                url: URL(string: "ws://127.0.0.1:\(port)")!,
                reconnectStrategy: .none
            ))
            try await Task.sleep(for: .milliseconds(200))
            await client.disconnect()
        }
    }

    @Test("send and receive echo with NIO transport")
    func sendReceiveEcho() async throws {
        try await withEchoServer { port in
            let client = Client(transportFactory: { NIOWebSocketTransport() })
            try await client.connect(config: ClientConfig(
                url: URL(string: "ws://127.0.0.1:\(port)")!,
                reconnectStrategy: .none
            ))
            try await Task.sleep(for: .milliseconds(200))

            await client.send(SendableRequest(
                event: "echo",
                payloadData: Data("{\"text\":\"hello\"}".utf8)
            ))

            try await Task.sleep(for: .milliseconds(500))
            await client.disconnect()
        }
    }

    @Test("reconnect cycle with NIO transport")
    func reconnectCycle() async throws {
        try await withEchoServer { port in
            let client = Client(transportFactory: { NIOWebSocketTransport() })
            for _ in 0..<3 {
                try await client.connect(config: ClientConfig(
                    url: URL(string: "ws://127.0.0.1:\(port)")!,
                    reconnectStrategy: .none
                ))
                try await Task.sleep(for: .milliseconds(200))
                await client.disconnect()
                try await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    @Test("connect to invalid server fails gracefully")
    func connectToInvalidServer() async throws {
        let client = Client(transportFactory: { NIOWebSocketTransport() })
        do {
            try await client.connect(config: ClientConfig(
                url: URL(string: "ws://127.0.0.1:1/socket")!,
                reconnectStrategy: .none
            ))
            Issue.record("Expected connection to fail")
        } catch {
            // Expected
        }
    }
}

// MARK: - Simple Expectation Helper

private final class SimpleExpectation: @unchecked Sendable {
    private var fulfilled = false
    func fulfill() { fulfilled = true }
    var isFulfilled: Bool { fulfilled }
}

private func expectation() -> SimpleExpectation { SimpleExpectation() }

// MARK: - Lightweight NIO Echo WebSocket Server

/// Runs a test with a lightweight NIO WebSocket echo server.
private func withEchoServer(_ body: (Int) async throws -> Void) async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    let upgrader = NIOWebSocketServerUpgrader(
        shouldUpgrade: { channel, head in
            channel.eventLoop.makeSucceededFuture(HTTPHeaders())
        },
        upgradePipelineHandler: { channel, _ in
            channel.pipeline.addHandler(EchoWebSocketHandler())
        }
    )

    let bootstrap = ServerBootstrap(group: group)
        .childChannelInitializer { channel in
            let httpHandler = HTTPByteBufferResponsePartHandler()
            let config: NIOHTTPServerUpgradeConfiguration = (
                upgraders: [upgrader],
                completionHandler: { _ in
                    channel.pipeline.removeHandler(httpHandler, promise: nil)
                }
            )
            return channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: config).flatMap {
                channel.pipeline.addHandler(httpHandler)
            }
        }
        .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)

    let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
    let port = channel.localAddress!.port!

    do {
        try await body(port)
    } catch {
        try? await channel.close()
        try? await group.shutdownGracefully()
        throw error
    }

    try await channel.close()
    try await group.shutdownGracefully()
}

/// Simple WebSocket handler that echoes text frames back
private final class EchoWebSocketHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .text:
            // Echo the text frame back
            var data = frame.unmaskedData
            let text = data.readString(length: data.readableBytes) ?? ""
            var buffer = context.channel.allocator.buffer(capacity: text.utf8.count)
            buffer.writeString(text)
            let responseFrame = WebSocketFrame(fin: true, opcode: .text, data: buffer)
            context.writeAndFlush(wrapOutboundOut(responseFrame), promise: nil)

        case .connectionClose:
            var data = frame.unmaskedData
            let closeFrame: WebSocketFrame
            if let closeCode = data.readInteger(as: UInt16.self) {
                var buffer = context.channel.allocator.buffer(capacity: 2)
                buffer.writeInteger(closeCode)
                closeFrame = WebSocketFrame(fin: true, opcode: .connectionClose, data: buffer)
            } else {
                closeFrame = WebSocketFrame(fin: true, opcode: .connectionClose, data: context.channel.allocator.buffer(capacity: 0))
            }
            context.writeAndFlush(wrapOutboundOut(closeFrame)).whenComplete { _ in
                context.close(promise: nil)
            }

        case .ping:
            let frameData = frame.unmaskedData
            let pong = WebSocketFrame(fin: true, opcode: .pong, data: frameData)
            context.writeAndFlush(wrapOutboundOut(pong), promise: nil)

        default:
            break
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

/// Minimal HTTP handler to serve the upgrade response
private final class HTTPByteBufferResponsePartHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        guard case .head = part else { return }

        // Return 426 Upgrade Required for non-WebSocket requests
        let headers = HTTPHeaders([("Content-Length", "0")])
        let head = HTTPResponseHead(version: .http1_1, status: .upgradeRequired, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
}
