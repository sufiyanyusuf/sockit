import Foundation
import SockitCore
import Vapor

/// A single WebSocket connection managed by the server
public actor Connection {
    public let id: UUID
    private var state: ConnectionState
    private let ws: WebSocket
    private let typedRouter: TypedRouter
    private let channelRegistry: ChannelRegistry

    /// Initialize with a TypedRouter for type-safe handler routing
    public init(
        id: UUID = UUID(),
        ws: WebSocket,
        typedRouter: TypedRouter,
        channelRegistry: ChannelRegistry,
        userId: UUID? = nil
    ) {
        self.id = id
        self.ws = ws
        self.typedRouter = typedRouter
        self.channelRegistry = channelRegistry
        self.state = ConnectionState(id: id, userId: userId)
    }

    /// Start handling messages from this connection.
    ///
    /// - Parameter externalMessageHandling: When `true`, skips registering `ws.onText`
    ///   so the caller can route messages externally (e.g. via `MessageBuffer`).
    ///   Messages should be forwarded via `handleBufferedText(_:)`.
    public func start(externalMessageHandling: Bool = false) async {
        // Handle connected
        let connectEffects = connectionReducer(
            state: &state, action: .connected(userId: state.userId))
        await execute(connectEffects)

        // Listen for messages (unless handled externally to avoid double registration)
        if !externalMessageHandling {
            ws.onText { [weak self] _, text in
                await self?.handleText(text)
            }
        }

        // Handle disconnect
        ws.onClose.whenComplete { [weak self] _ in
            Task {
                await self?.handleDisconnect()
            }
        }
    }

    /// Send a push event with typed payload to this connection
    public func push<T: Encodable>(event: String, payload: T, channel: String? = nil) async throws {
        let payloadData = try JSONEncoder().encode(payload)
        let effects = connectionReducer(
            state: &state,
            action: .sendPush(event: event, payloadData: payloadData, channel: channel))
        await execute(effects)
    }

    /// Send a push event with no payload to this connection
    public func push(event: String, channel: String? = nil) async {
        let effects = connectionReducer(
            state: &state,
            action: .sendPush(event: event, payloadData: Data("{}".utf8), channel: channel))
        await execute(effects)
    }

    /// Send a push event with raw JSON data payload (for non-Encodable types like Conduit Partials)
    public func pushRawData(event: String, data: Data, channel: String? = nil) async {
        let effects = connectionReducer(
            state: &state, action: .sendPush(event: event, payloadData: data, channel: channel))
        await execute(effects)
    }

    /// Send a response with typed data to a pending request
    public func respond<T: Encodable>(
        requestId: String,
        status: ResponseStatus = .ok,
        data: T
    ) async throws {
        let dataBytes = try JSONEncoder().encode(data)
        let effects = connectionReducer(
            state: &state,
            action: .sendResponse(requestId: requestId, status: status, data: dataBytes, error: nil)
        )
        await execute(effects)
    }

    /// Send an error response to a pending request
    public func respond(
        requestId: String,
        error: ResponseError
    ) async {
        let effects = connectionReducer(
            state: &state,
            action: .sendResponse(
                requestId: requestId, status: .error, data: Data("{}".utf8), error: error)
        )
        await execute(effects)
    }

    /// Handle text messages from external buffer (used for early message handling)
    public func handleBufferedText(_ text: String) async {
        await handleText(text)
    }

    // MARK: - Private

    private func handleText(_ text: String) async {
        guard let data = text.data(using: .utf8) else {
            return
        }

        guard let message = try? JSONDecoder().decode(SockitMessage.self, from: data) else {
            return
        }

        let effects = connectionReducer(state: &state, action: .messageReceived(message))
        await execute(effects)
    }

    private func handleDisconnect() async {
        let effects = connectionReducer(state: &state, action: .disconnected)
        await execute(effects)
    }

    private func execute(_ effects: [ServerEffect]) async {
        for effect in effects {
            await executeEffect(effect)
        }
    }

    private func executeEffect(_ effect: ServerEffect) async {
        switch effect {
        case .sendMessage(let message):
            await sendMessage(message)

        case .closeConnection(let code, _):
            try? await ws.close(code: .init(codeNumber: Int(code)))

        case .routeEvent(let event, let payloadData, let requestId, let channel):
            await routeEvent(
                event: event, payloadData: payloadData, requestId: requestId, channel: channel)

        case .validateJoin(let channel, let payloadData, let requestId):
            await validateJoin(channel: channel, payloadData: payloadData, requestId: requestId)

        case .subscribeToChannel(let channel):
            await channelRegistry.subscribe(connectionId: id, to: channel)

        case .unsubscribeFromChannel(let channel):
            await channelRegistry.unsubscribe(connectionId: id, from: channel)

        case .onConnect:
            // Hook for custom connect logic
            break

        case .onDisconnect:
            // Hook for custom disconnect logic
            break
        }
    }

    private func sendMessage(_ message: SockitMessage) async {
        do {
            let data = try JSONEncoder().encode(message)
            guard let text = String(data: data, encoding: .utf8) else {
                return
            }
            try? await ws.send(text)
        } catch {
            assertionFailure("[Sockit] Failed to encode message: \(error)")
        }
    }

    private func routeEvent(event: String, payloadData: Data, requestId: String?, channel: String?)
        async
    {
        // Track pending response if this is a request
        if let requestId = requestId {
            state.pendingResponses[requestId] = PendingResponse(
                requestId: requestId,
                event: event,
                channel: channel
            )
        }

        // Route to handler
        do {
            let userId = state.userId
            let context = HandlerContext(connection: self, userId: userId)
            let responseData = try await typedRouter.route(
                event: event, payloadData: payloadData, context: context)

            if let requestId = requestId {
                // Send success response with the data
                let effects = connectionReducer(
                    state: &state,
                    action: .sendResponse(
                        requestId: requestId, status: .ok, data: responseData, error: nil)
                )
                await execute(effects)
            }
        } catch {
            if let requestId = requestId {
                let effects = connectionReducer(
                    state: &state,
                    action: .sendResponse(
                        requestId: requestId, status: .error, data: Data("{}".utf8),
                        error: ResponseError(
                            code: "handler_error", message: error.localizedDescription))
                )
                await execute(effects)
            }
        }
    }

    private func validateJoin(channel: String, payloadData: Data, requestId: String) async {
        // For now, allow all joins - override for custom validation
        let effects = connectionReducer(state: &state, action: .channelJoined(channel))
        await execute(effects)

        // Send success response
        let responsePayload = ChannelJoinSuccessPayload(status: "ok")
        if let message = try? SockitMessage(
            event: "channel.join",
            payload: responsePayload,
            requestId: requestId,
            channel: channel
        ) {
            await sendMessage(message)
        }
    }
}

// MARK: - Internal Types

private struct ChannelJoinSuccessPayload: Encodable {
    let status: String
}
