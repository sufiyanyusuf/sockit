import Testing
import Foundation
@testable import SockitServer
@testable import SockitCore

// MARK: - Channel Registry Tests

@Suite("ChannelRegistry")
struct ChannelRegistryTests {

    @Test("subscribe adds connection to channel")
    func subscribe() async {
        let registry = ChannelRegistry()
        let connId = UUID()

        await registry.subscribe(connectionId: connId, to: "user:123")

        let subscribers = await registry.subscribers(for: "user:123")
        #expect(subscribers.contains(connId))

        let channels = await registry.channels(for: connId)
        #expect(channels.contains("user:123"))
    }

    @Test("subscribe multiple connections to same channel")
    func subscribeMultiple() async {
        let registry = ChannelRegistry()
        let conn1 = UUID()
        let conn2 = UUID()
        let conn3 = UUID()

        await registry.subscribe(connectionId: conn1, to: "lobby")
        await registry.subscribe(connectionId: conn2, to: "lobby")
        await registry.subscribe(connectionId: conn3, to: "lobby")

        let subscribers = await registry.subscribers(for: "lobby")
        #expect(subscribers.count == 3)
        #expect(subscribers.contains(conn1))
        #expect(subscribers.contains(conn2))
        #expect(subscribers.contains(conn3))
    }

    @Test("subscribe one connection to multiple channels")
    func subscribeMultipleChannels() async {
        let registry = ChannelRegistry()
        let connId = UUID()

        await registry.subscribe(connectionId: connId, to: "user:123")
        await registry.subscribe(connectionId: connId, to: "lobby")
        await registry.subscribe(connectionId: connId, to: "admin")

        let channels = await registry.channels(for: connId)
        #expect(channels == Set(["user:123", "lobby", "admin"]))
    }

    @Test("unsubscribe removes connection from channel")
    func unsubscribe() async {
        let registry = ChannelRegistry()
        let connId = UUID()

        await registry.subscribe(connectionId: connId, to: "user:123")
        await registry.unsubscribe(connectionId: connId, from: "user:123")

        let subscribers = await registry.subscribers(for: "user:123")
        #expect(subscribers.isEmpty)

        let channels = await registry.channels(for: connId)
        #expect(!channels.contains("user:123"))
    }

    @Test("unsubscribe does not affect other connections")
    func unsubscribeDoesNotAffectOthers() async {
        let registry = ChannelRegistry()
        let conn1 = UUID()
        let conn2 = UUID()

        await registry.subscribe(connectionId: conn1, to: "lobby")
        await registry.subscribe(connectionId: conn2, to: "lobby")

        await registry.unsubscribe(connectionId: conn1, from: "lobby")

        let subscribers = await registry.subscribers(for: "lobby")
        #expect(subscribers.count == 1)
        #expect(subscribers.contains(conn2))
    }

    @Test("unsubscribeAll removes connection from all channels")
    func unsubscribeAll() async {
        let registry = ChannelRegistry()
        let connId = UUID()

        await registry.subscribe(connectionId: connId, to: "user:123")
        await registry.subscribe(connectionId: connId, to: "lobby")
        await registry.subscribe(connectionId: connId, to: "admin")

        await registry.unsubscribeAll(connectionId: connId)

        let channels = await registry.channels(for: connId)
        #expect(channels.isEmpty)

        // All channels should be cleaned up
        let userSubs = await registry.subscribers(for: "user:123")
        let lobbySubs = await registry.subscribers(for: "lobby")
        let adminSubs = await registry.subscribers(for: "admin")
        #expect(userSubs.isEmpty)
        #expect(lobbySubs.isEmpty)
        #expect(adminSubs.isEmpty)
    }

    @Test("unsubscribeAll does not affect other connections")
    func unsubscribeAllDoesNotAffectOthers() async {
        let registry = ChannelRegistry()
        let conn1 = UUID()
        let conn2 = UUID()

        await registry.subscribe(connectionId: conn1, to: "lobby")
        await registry.subscribe(connectionId: conn2, to: "lobby")
        await registry.subscribe(connectionId: conn1, to: "admin")

        await registry.unsubscribeAll(connectionId: conn1)

        let lobbySubs = await registry.subscribers(for: "lobby")
        #expect(lobbySubs.count == 1)
        #expect(lobbySubs.contains(conn2))
    }

    @Test("isSubscribed returns correct value")
    func isSubscribed() async {
        let registry = ChannelRegistry()
        let connId = UUID()

        let beforeSubscribe = await registry.isSubscribed(connectionId: connId, to: "lobby")
        #expect(!beforeSubscribe)

        await registry.subscribe(connectionId: connId, to: "lobby")

        let afterSubscribe = await registry.isSubscribed(connectionId: connId, to: "lobby")
        #expect(afterSubscribe)

        await registry.unsubscribe(connectionId: connId, from: "lobby")

        let afterUnsubscribe = await registry.isSubscribed(connectionId: connId, to: "lobby")
        #expect(!afterUnsubscribe)
    }

    @Test("subscribers for empty channel returns empty set")
    func subscribersEmpty() async {
        let registry = ChannelRegistry()

        let subscribers = await registry.subscribers(for: "nonexistent")
        #expect(subscribers.isEmpty)
    }

    @Test("channels for unknown connection returns empty set")
    func channelsForUnknownConnection() async {
        let registry = ChannelRegistry()

        let channels = await registry.channels(for: UUID())
        #expect(channels.isEmpty)
    }

    @Test("duplicate subscribe is idempotent")
    func duplicateSubscribe() async {
        let registry = ChannelRegistry()
        let connId = UUID()

        await registry.subscribe(connectionId: connId, to: "lobby")
        await registry.subscribe(connectionId: connId, to: "lobby")

        let subscribers = await registry.subscribers(for: "lobby")
        #expect(subscribers.count == 1)

        let channels = await registry.channels(for: connId)
        #expect(channels.count == 1)
    }

    @Test("empty channel is cleaned up after last unsubscribe")
    func channelCleanupAfterLastUnsubscribe() async {
        let registry = ChannelRegistry()
        let conn1 = UUID()
        let conn2 = UUID()

        await registry.subscribe(connectionId: conn1, to: "lobby")
        await registry.subscribe(connectionId: conn2, to: "lobby")

        await registry.unsubscribe(connectionId: conn1, from: "lobby")
        // Channel still has conn2
        let subs1 = await registry.subscribers(for: "lobby")
        #expect(subs1.count == 1)

        await registry.unsubscribe(connectionId: conn2, from: "lobby")
        // Channel should be cleaned up
        let subs2 = await registry.subscribers(for: "lobby")
        #expect(subs2.isEmpty)
    }
}
