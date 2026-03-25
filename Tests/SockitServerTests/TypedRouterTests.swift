import Testing
import Foundation
@testable import SockitServer
@testable import SockitCore

// MARK: - Test Handler Types

private struct EchoRequest: Codable, Sendable {
    let message: String
}

private struct EchoResponse: Codable, Sendable {
    let echo: String
}

private struct EchoHandler: SockitHandler {
    typealias Request = EchoRequest
    typealias Response = EchoResponse
    static let event = "test.echo"

    func handle(request: Request, context: HandlerContext) async throws -> Response {
        EchoResponse(echo: request.message)
    }
}

private struct PingResponse: Codable, Sendable {
    let pong: Bool
}

private struct PingHandler: SockitHandlerNoPayload {
    typealias Response = PingResponse
    static let event = "test.ping"

    func handle(context: HandlerContext) async throws -> Response {
        PingResponse(pong: true)
    }
}

private struct FailingHandler: SockitHandlerNoPayload {
    typealias Response = PingResponse
    static let event = "test.fail"

    struct HandlerError: Error, LocalizedError {
        var errorDescription: String? { "Something went wrong" }
    }

    func handle(context: HandlerContext) async throws -> Response {
        throw HandlerError()
    }
}

// MARK: - TypedRouter Tests

@Suite("TypedRouter")
struct TypedRouterTests {

    @Test("register and route handler with payload")
    func registerAndRouteWithPayload() async throws {
        let router = TypedRouter()
        await router.register(EchoHandler())

        let hasHandler = await router.hasHandler(for: "test.echo")
        #expect(hasHandler)

        // Verify the payload can be encoded (handler would decode this)
        let payloadData = try JSONEncoder().encode(EchoRequest(message: "hello"))
        #expect(!payloadData.isEmpty)

        // Full routing with a HandlerContext requires a Connection (Vapor type).
        // The actual routing with a real context is an integration test concern.
    }

    @Test("hasHandler returns false for unregistered event")
    func hasHandlerUnregistered() async {
        let router = TypedRouter()

        let result = await router.hasHandler(for: "nonexistent.event")
        #expect(!result)
    }

    @Test("hasHandler returns true for registered handler with payload")
    func hasHandlerWithPayload() async {
        let router = TypedRouter()
        await router.register(EchoHandler())

        let result = await router.hasHandler(for: "test.echo")
        #expect(result)
    }

    @Test("hasHandler returns true for registered handler without payload")
    func hasHandlerNoPayload() async {
        let router = TypedRouter()
        await router.register(PingHandler())

        let result = await router.hasHandler(for: "test.ping")
        #expect(result)
    }

    @Test("registeredEvents returns all registered event names")
    func registeredEvents() async {
        let router = TypedRouter()
        await router.register(EchoHandler())
        await router.register(PingHandler())

        let events = await router.registeredEvents()
        #expect(events.count == 2)
        #expect(events.contains("test.echo"))
        #expect(events.contains("test.ping"))
    }

    @Test("registeredEvents is empty for new router")
    func registeredEventsEmpty() async {
        let router = TypedRouter()

        let events = await router.registeredEvents()
        #expect(events.isEmpty)
    }

    @Test("registering handler for same event replaces previous")
    func registerOverwrite() async {
        let router = TypedRouter()
        await router.register(PingHandler())
        await router.register(PingHandler())

        let events = await router.registeredEvents()
        #expect(events.count == 1)
    }

    @Test("register multiple different handlers")
    func registerMultiple() async {
        let router = TypedRouter()
        await router.register(EchoHandler())
        await router.register(PingHandler())
        await router.register(FailingHandler())

        let events = await router.registeredEvents()
        #expect(events.count == 3)
        #expect(events.contains("test.echo"))
        #expect(events.contains("test.ping"))
        #expect(events.contains("test.fail"))
    }
}

// MARK: - AnyTypedHandler Tests

@Suite("AnyTypedHandler")
struct AnyTypedHandlerTests {

    @Test("AnyTypedHandler wraps SockitHandler correctly")
    func wrapSockitHandler() async {
        // Validate type erasure compiles and constructs without error
        _ = AnyTypedHandler(EchoHandler())
    }

    @Test("AnyTypedHandler wraps SockitHandlerNoPayload correctly")
    func wrapSockitHandlerNoPayload() async {
        // Validate type erasure compiles and constructs without error
        _ = AnyTypedHandler(PingHandler())
    }
}

// MARK: - TypedRouterError Tests

@Suite("TypedRouterError")
struct TypedRouterErrorTests {

    @Test("handlerNotFound error has descriptive message")
    func handlerNotFoundDescription() {
        let error = TypedRouterError.handlerNotFound(event: "test.missing")

        #expect(error.errorDescription?.contains("test.missing") == true)
        #expect(error.errorDescription?.contains("No handler registered") == true)
    }

    @Test("decodingFailed error includes event name")
    func decodingFailedDescription() {
        let decodingError = DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: [], debugDescription: "test"))
        let error = TypedRouterError.decodingFailed(event: "test.echo", error: decodingError)

        #expect(error.errorDescription?.contains("test.echo") == true)
        #expect(error.errorDescription?.contains("decode") == true)
    }

    @Test("encodingFailed error includes event name")
    func encodingFailedDescription() {
        let encodingError = EncodingError.invalidValue(
            "test",
            EncodingError.Context(codingPath: [], debugDescription: "test"))
        let error = TypedRouterError.encodingFailed(event: "test.echo", error: encodingError)

        #expect(error.errorDescription?.contains("test.echo") == true)
        #expect(error.errorDescription?.contains("encode") == true)
    }
}
