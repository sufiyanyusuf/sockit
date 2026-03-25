import Foundation
import SockitCore
// NIO transport is the default on all non-Apple platforms (Linux, etc.)
#if !canImport(Darwin)
import SockitNIOTransport
#endif

/// WebSocket client with async/await API.
/// Thread-safe actor that manages connection lifecycle.
public actor Client {
    // MARK: - Internal State

    private var state = ClientState()
    private var transport: (any TransportProtocol)?
    private var transportEventsTask: Task<Void, Never>?

    // MARK: - Task Management

    private var heartbeatTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var timeoutTasks: [String: Task<Void, Never>] = [:]

    // MARK: - Typed Request Tracking

    /// Pending typed requests awaiting responses.
    /// Key: requestId, Value: continuation to resume with raw response data
    private var pendingTypedRequests: [String: CheckedContinuation<Data, Error>] = [:]

    // MARK: - Message Stream

    private let continuation: AsyncStream<ClientMessage>.Continuation
    public nonisolated let messages: AsyncStream<ClientMessage>

    // MARK: - Transport Factory

    private let transportFactory: @Sendable () -> any TransportProtocol

    // MARK: - Initialization

    /// Creates a new WebSocket client.
    ///
    /// - Parameter transportFactory: A closure that creates a fresh transport for each connection.
    ///   Defaults to the platform-appropriate transport automatically:
    ///   `WebSocketTransport` (URLSession) on Apple, `NIOWebSocketTransport` on Linux.
    #if canImport(Darwin)
    public init(transportFactory: @escaping @Sendable () -> any TransportProtocol = { WebSocketTransport() }) {
        self.transportFactory = transportFactory
        let (stream, continuation) = AsyncStream.makeStream(of: ClientMessage.self)
        self.messages = stream
        self.continuation = continuation
    }
    #else
    public init(transportFactory: @escaping @Sendable () -> any TransportProtocol = { NIOWebSocketTransport() }) {
        self.transportFactory = transportFactory
        let (stream, continuation) = AsyncStream.makeStream(of: ClientMessage.self)
        self.messages = stream
        self.continuation = continuation
    }
    #endif

    deinit {
        continuation.finish()
        heartbeatTask?.cancel()
        reconnectTask?.cancel()
        transportEventsTask?.cancel()
        timeoutTasks.values.forEach { $0.cancel() }
        // Note: pendingTypedRequests continuations will be resumed with errors
        // when the actor is deallocated and tasks are cancelled
    }

    // MARK: - Public API

    /// Connect to the server.
    ///
    /// If the client is not in `.disconnected` state (e.g., stuck in `.reconnecting`
    /// after a server-initiated close), this method silently resets internal state
    /// before connecting. No `.disconnected` event is emitted during the reset —
    /// only the new connection lifecycle events are emitted.
    public func connect(config: ClientConfig) async throws {
        // If not disconnected, silently reset so the reducer's connect guard passes.
        // This avoids emitting a spurious .disconnected event that would confuse
        // the app's session state machine.
        if case .disconnected = state.connection {
            // Already disconnected — proceed normally
        } else {
            // Silently tear down old connection without emitting events
            transportEventsTask?.cancel()
            transportEventsTask = nil
            transport?.disconnect(code: 1000, reason: "reconnecting")
            transport = nil
            heartbeatTask?.cancel()
            heartbeatTask = nil
            reconnectTask?.cancel()
            reconnectTask = nil
            state.connection = .disconnected
            state.channels.removeAll()
            state.pendingRequests.removeAll()
            state.missedHeartbeats = 0
        }

        let effects = clientReducer(state: &state, action: .connect(config))
        try await execute(effects)
    }

    /// Disconnect from the server
    public func disconnect() async {
        let effects = clientReducer(state: &state, action: .disconnect(.userInitiated))
        await executeNonThrowing(effects)
    }

    /// Join a channel
    public func join(_ channel: String) async {
        let effects = clientReducer(state: &state, action: .joinChannel(channel, Data("{}".utf8)))
        await executeNonThrowing(effects)
    }

    /// Join a channel with typed parameters
    public func join<T: Encodable>(_ channel: String, payload: T) async throws {
        let payloadData = try JSONEncoder().encode(payload)
        let effects = clientReducer(state: &state, action: .joinChannel(channel, payloadData))
        await executeNonThrowing(effects)
    }

    /// Leave a channel
    public func leave(_ channel: String) async {
        let effects = clientReducer(state: &state, action: .leaveChannel(channel))
        await executeNonThrowing(effects)
    }

    /// Send a request (fire-and-forget, response comes via messages stream)
    public func send(_ request: SendableRequest) async {
        let effects = clientReducer(state: &state, action: .send(request))
        await executeNonThrowing(effects)
    }

    /// Send a typed request (fire-and-forget, response comes via messages stream)
    public func send<T: Encodable & Sendable>(_ request: Request<T>) async throws {
        let sendable = try request.toSendable()
        let effects = clientReducer(state: &state, action: .send(sendable))
        await executeNonThrowing(effects)
    }

    /// Send a typed command and await its response.
    ///
    /// This is the typed API that provides compile-time safety for request/response types.
    /// Unlike `send(Request)`, this method awaits the response and decodes it to the
    /// command's declared `Response` type.
    ///
    /// - Parameter command: The command to send
    /// - Returns: The decoded response
    /// - Throws: `SockitError` if the request fails or times out
    ///
    /// Example:
    /// ```swift
    /// struct GetProfile: SockitCommand {
    ///     typealias Response = ProfileDTO
    ///     static let event = "profile.get"
    /// }
    ///
    /// let profile = try await client.send(GetProfile())
    /// ```
    public func send<C: SockitCommand>(_ command: C) async throws -> C.Response {
        // Must be connected to send
        guard case .connected = state.connection else {
            throw SockitError.notConnected
        }

        // If channel specified, must be joined
        if let channel = command.channel {
            guard case .joined = state.channels[channel] else {
                throw SockitError.channelNotJoined(channel)
            }
        }

        let requestId = UUID().uuidString

        // Build the payload data
        let payloadData: Data
        if let commandWithPayload = command as? (any SockitCommandWithPayload) {
            payloadData = try JSONEncoder().encode(commandWithPayload)
        } else {
            payloadData = Data("{}".utf8)
        }

        // Build the raw wire message
        // Format: {"event": "...", "payload": {...}, "requestId": "...", "channel": "..."}
        let rawMessage = try buildRawMessage(
            event: C.event,
            payloadData: payloadData,
            requestId: requestId,
            channel: command.channel
        )

        // Track pending request in state (for timeout handling)
        state.pendingRequests[requestId] = PendingRequest(
            id: requestId,
            event: C.event,
            channel: command.channel,
            sentAt: Date()
        )

        // Set up timeout
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(command.timeout))
            guard !Task.isCancelled else { return }
            await self?.handleTypedRequestTimeout(requestId: requestId)
        }
        timeoutTasks[requestId] = timeoutTask

        // Send the raw message
        guard let transport = transport else {
            state.pendingRequests.removeValue(forKey: requestId)
            timeoutTask.cancel()
            timeoutTasks.removeValue(forKey: requestId)
            throw SockitError.notConnected
        }

        do {
            try await transport.send(rawMessage)
        } catch {
            state.pendingRequests.removeValue(forKey: requestId)
            timeoutTask.cancel()
            timeoutTasks.removeValue(forKey: requestId)
            throw SockitError.sendFailed(error)
        }

        // Wait for response
        let responseData: Data = try await withCheckedThrowingContinuation { continuation in
            pendingTypedRequests[requestId] = continuation
        }

        // Clean up
        timeoutTask.cancel()
        timeoutTasks.removeValue(forKey: requestId)

        // Decode the response
        do {
            return try JSONDecoder().decode(C.Response.self, from: responseData)
        } catch {
            throw SockitError.decodingFailed(error)
        }
    }

    // MARK: - Typed Request Helpers

    /// Build a raw JSON message for typed commands.
    private func buildRawMessage(
        event: String,
        payloadData: Data,
        requestId: String,
        channel: String?
    ) throws -> Data {
        // Build JSON manually to embed pre-encoded payload
        var jsonDict: [String: Any] = [
            "event": event,
            "requestId": requestId
        ]

        if let channel = channel {
            jsonDict["channel"] = channel
        }

        // Parse payload data to merge into message
        if let payloadObj = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any] {
            jsonDict["payload"] = payloadObj
        } else {
            jsonDict["payload"] = [String: Any]()
        }

        return try JSONSerialization.data(withJSONObject: jsonDict)
    }

    /// Handle typed request timeout
    private func handleTypedRequestTimeout(requestId: String) {
        state.pendingRequests.removeValue(forKey: requestId)
        timeoutTasks.removeValue(forKey: requestId)

        if let continuation = pendingTypedRequests.removeValue(forKey: requestId) {
            continuation.resume(throwing: SockitError.timeout(requestId: requestId))
        }
    }

    // MARK: - Effect Execution

    private func execute(_ effects: [ClientEffect]) async throws {
        for effect in effects {
            try await executeEffect(effect)
        }
    }

    private func executeNonThrowing(_ effects: [ClientEffect]) async {
        for effect in effects {
            try? await executeEffect(effect)
        }
    }

    private func executeEffect(_ effect: ClientEffect) async throws {
        switch effect {
        case let .openConnection(url, token):
            try await openConnection(url: url, token: token)

        case let .closeConnection(code, reason):
            closeConnection(code: code, reason: reason)

        case let .sendMessage(message):
            try await sendMessage(message)

        case let .startHeartbeat(interval):
            startHeartbeat(interval: interval)

        case .stopHeartbeat:
            stopHeartbeat()

        case let .scheduleReconnect(delay):
            scheduleReconnect(delay: delay)

        case .cancelReconnect:
            cancelReconnect()

        case let .scheduleRequestTimeout(requestId, delay):
            scheduleRequestTimeout(requestId: requestId, delay: delay)

        case let .cancelRequestTimeout(requestId):
            cancelRequestTimeout(requestId: requestId)

        case let .emit(message):
            continuation.yield(message)
        }
    }

    // MARK: - Connection

    private func openConnection(url: URL, token: String?) async throws {
        let transport = transportFactory()
        self.transport = transport

        // Append token as query parameter for WebSocket compatibility
        // iOS URLSessionWebSocketTask doesn't reliably forward custom headers
        var finalURL = url
        if let token = token {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            var queryItems = components?.queryItems ?? []
            queryItems.append(URLQueryItem(name: "token", value: token))
            components?.queryItems = queryItems
            if let urlWithToken = components?.url {
                finalURL = urlWithToken
            }
        }

        // Start listening for transport events
        transportEventsTask?.cancel()
        transportEventsTask = Task { [weak self] in
            for await event in transport.events {
                await self?.handleTransportEvent(event)
            }
        }

        try await transport.connect(to: finalURL, headers: [:])
    }

    private func closeConnection(code: UInt16, reason: String) {
        transportEventsTask?.cancel()
        transport?.disconnect(code: code, reason: reason)
        transport = nil
    }

    private func sendMessage(_ message: SockitMessage) async throws {
        guard let transport = transport else { return }

        let data = try JSONEncoder().encode(message)
        try await transport.send(data)
    }

    // MARK: - Transport Events

    private func handleTransportEvent(_ event: TransportEvent) {
        let action: ClientAction

        switch event {
        case .connected:
            action = .transportConnected

        case let .disconnected(error):
            // Cancel all pending typed requests on disconnect
            for (requestId, continuation) in pendingTypedRequests {
                continuation.resume(throwing: SockitError.disconnected)
                timeoutTasks[requestId]?.cancel()
                timeoutTasks.removeValue(forKey: requestId)
            }
            pendingTypedRequests.removeAll()
            action = .transportDisconnected(error)

        case let .message(data):
            // Check if this is a response for a typed request
            if let requestId = extractRequestId(from: data),
               pendingTypedRequests[requestId] != nil {
                // Handle as typed response - extract data payload and error
                handleTypedResponseFromRawData(requestId: requestId, rawData: data)
                return // Don't pass to regular reducer flow
            }

            // Check if this is a push event (no requestId) - emit as raw push event
            if extractRequestId(from: data) == nil {
                if let rawPush = createRawPushEvent(from: data) {
                    // Emit raw push event directly (avoids JSON parsing overhead)
                    continuation.yield(.rawPushEvent(rawPush))
                    // Still need to decode for reducer to handle channel-specific logic
                }
            }

            guard let message = try? JSONDecoder().decode(SockitMessage.self, from: data) else {
                return
            }
            action = .transportMessageReceived(message)

        case .ping, .pong:
            return
        }

        let effects = clientReducer(state: &state, action: action)
        Task {
            await executeNonThrowing(effects)
        }
    }

    /// Extract requestId from raw JSON data without full decode
    private func extractRequestId(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let requestId = json["requestId"] as? String else {
            return nil
        }
        return requestId
    }

    /// Create a RawPushEvent from raw message data without full AnyCodable decode
    private func createRawPushEvent(from data: Data) -> RawPushEvent? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = json["event"] as? String else {
            return nil
        }

        // Extract payload as raw Data for deferred decoding
        let payloadData: Data
        if let payload = json["payload"] {
            payloadData = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        } else {
            payloadData = Data()
        }

        let channel = json["channel"] as? String

        return RawPushEvent(event: event, payloadData: payloadData, channel: channel)
    }

    /// Handle a typed response from raw message data
    private func handleTypedResponseFromRawData(requestId: String, rawData: Data) {
        guard let continuation = pendingTypedRequests.removeValue(forKey: requestId) else {
            return
        }

        state.pendingRequests.removeValue(forKey: requestId)
        timeoutTasks[requestId]?.cancel()
        timeoutTasks.removeValue(forKey: requestId)

        // Parse the response to check for errors and extract data
        guard let json = try? JSONSerialization.jsonObject(with: rawData) as? [String: Any] else {
            continuation.resume(throwing: SockitError.invalidResponse)
            return
        }

        // Status is at message level (not inside payload)
        let status = json["status"] as? String

        // Payload IS the typed response data directly (no "data" wrapper)
        let payload = json["payload"] as? [String: Any] ?? [:]

        // Check for error response
        if status == "error", let errorDict = payload["error"] as? [String: Any] {
            let code = errorDict["code"] as? String ?? "unknown"
            let message = errorDict["message"] as? String ?? "Unknown error"
            continuation.resume(throwing: SockitError.serverError(code: code, message: message))
            return
        }

        // Payload IS the data - serialize directly
        do {
            let dataBytes = try JSONSerialization.data(withJSONObject: payload)
            continuation.resume(returning: dataBytes)
        } catch {
            continuation.resume(throwing: SockitError.invalidResponse)
        }
    }

    // MARK: - Heartbeat

    private func startHeartbeat(interval: TimeInterval) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { break }
                await self?.heartbeatTick()
            }
        }
    }

    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    private func heartbeatTick() {
        let effects = clientReducer(state: &state, action: .heartbeatTick)
        Task {
            await executeNonThrowing(effects)
        }
    }

    // MARK: - Reconnect

    private func scheduleReconnect(delay: TimeInterval) {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.reconnect()
        }
    }

    private func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    private func reconnect() {
        let effects = clientReducer(state: &state, action: .reconnect)
        Task {
            await executeNonThrowing(effects)
        }
    }

    // MARK: - Request Timeouts

    private func scheduleRequestTimeout(requestId: String, delay: TimeInterval) {
        timeoutTasks[requestId]?.cancel()
        timeoutTasks[requestId] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.requestTimeout(requestId: requestId)
        }
    }

    private func cancelRequestTimeout(requestId: String) {
        timeoutTasks[requestId]?.cancel()
        timeoutTasks.removeValue(forKey: requestId)
    }

    private func requestTimeout(requestId: String) {
        let effects = clientReducer(state: &state, action: .requestTimeout(requestId))
        Task {
            await executeNonThrowing(effects)
        }
    }
}

// MARK: - SockitError

/// Errors that can occur when using the typed `send` API.
public enum SockitError: Error, Sendable, Equatable, LocalizedError {
    /// Client is not connected to the server
    case notConnected

    /// The specified channel has not been joined
    case channelNotJoined(String)

    /// The request timed out waiting for a response
    case timeout(requestId: String)

    /// Failed to send the message
    case sendFailed(Error)

    /// The connection was closed while waiting for a response
    case disconnected

    /// The server returned an error response
    case serverError(code: String, message: String)

    /// Failed to decode the response to the expected type
    case decodingFailed(Error)

    /// The response format was invalid
    case invalidResponse

    // MARK: - LocalizedError

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "WebSocket not connected"
        case .channelNotJoined(let channel):
            return "Channel '\(channel)' not joined"
        case .timeout(let requestId):
            return "Request timed out (id: \(requestId.prefix(8))...)"
        case .sendFailed(let error):
            return "Failed to send message: \(error.localizedDescription)"
        case .disconnected:
            return "WebSocket disconnected while waiting for response"
        case .serverError(let code, let message):
            return "Server error [\(code)]: \(message)"
        case .decodingFailed(let error):
            return "Failed to decode response: \(error.localizedDescription)"
        case .invalidResponse:
            return "Invalid response format from server"
        }
    }

    // MARK: - Equatable

    public static func == (lhs: SockitError, rhs: SockitError) -> Bool {
        switch (lhs, rhs) {
        case (.notConnected, .notConnected):
            return true
        case let (.channelNotJoined(a), .channelNotJoined(b)):
            return a == b
        case let (.timeout(a), .timeout(b)):
            return a == b
        case (.sendFailed, .sendFailed):
            return true // Can't compare arbitrary errors
        case (.disconnected, .disconnected):
            return true
        case let (.serverError(c1, m1), .serverError(c2, m2)):
            return c1 == c2 && m1 == m2
        case (.decodingFailed, .decodingFailed):
            return true // Can't compare arbitrary errors
        case (.invalidResponse, .invalidResponse):
            return true
        default:
            return false
        }
    }
}
