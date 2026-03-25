import Foundation

/// Holds raw JSON data for deferred decoding.
/// Avoids the double-parse overhead of AnyCodable.
public struct RawPayload: Sendable, Equatable {
    public let data: Data

    public init(_ data: Data) {
        self.data = data
    }

    public init() {
        self.data = Data("{}".utf8)
    }

    /// Decode the raw data to a specific type.
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    /// Decode the raw data to a specific type, returning nil if decoding fails.
    public func decodeIfPresent<T: Decodable>(_ type: T.Type) -> T? {
        try? decode(type)
    }
}
