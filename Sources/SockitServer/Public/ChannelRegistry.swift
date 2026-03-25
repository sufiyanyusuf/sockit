import Foundation
import SockitCore

/// Manages channel subscriptions for pub/sub messaging
public actor ChannelRegistry {
    /// Map of channel -> connection IDs
    private var subscriptions: [String: Set<UUID>] = [:]

    /// Map of connection ID -> channels
    private var connectionChannels: [UUID: Set<String>] = [:]

    public init() {}

    /// Subscribe a connection to a channel
    public func subscribe(connectionId: UUID, to channel: String) {
        subscriptions[channel, default: []].insert(connectionId)
        connectionChannels[connectionId, default: []].insert(channel)
    }

    /// Unsubscribe a connection from a channel
    public func unsubscribe(connectionId: UUID, from channel: String) {
        subscriptions[channel]?.remove(connectionId)
        connectionChannels[connectionId]?.remove(channel)

        // Clean up empty sets
        if subscriptions[channel]?.isEmpty == true {
            subscriptions.removeValue(forKey: channel)
        }
    }

    /// Unsubscribe a connection from all channels
    public func unsubscribeAll(connectionId: UUID) {
        guard let channels = connectionChannels[connectionId] else { return }

        for channel in channels {
            subscriptions[channel]?.remove(connectionId)
            if subscriptions[channel]?.isEmpty == true {
                subscriptions.removeValue(forKey: channel)
            }
        }

        connectionChannels.removeValue(forKey: connectionId)
    }

    /// Get all connection IDs subscribed to a channel
    public func subscribers(for channel: String) -> Set<UUID> {
        subscriptions[channel] ?? []
    }

    /// Get all channels a connection is subscribed to
    public func channels(for connectionId: UUID) -> Set<String> {
        connectionChannels[connectionId] ?? []
    }

    /// Check if a connection is subscribed to a channel
    public func isSubscribed(connectionId: UUID, to channel: String) -> Bool {
        subscriptions[channel]?.contains(connectionId) ?? false
    }
}
