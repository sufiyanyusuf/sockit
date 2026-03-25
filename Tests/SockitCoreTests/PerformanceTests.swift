import Testing
import Foundation
@testable import SockitCore

// MARK: - Performance Benchmarks

/// Test payload types for benchmarks
private struct BenchPayload: Codable, Sendable {
    let userId: String
    let date: String
    let count: Int
}

private struct SimplePayload: Codable, Sendable {
    let i: Int
}

@Suite("Performance")
struct PerformanceTests {

    // MARK: - JSON Encoding/Decoding (BIGGEST BOTTLENECK)

    @Test("benchmark: encode 10,000 messages")
    func benchmarkEncode() throws {
        let encoder = JSONEncoder()
        let message = try SockitMessage(
            event: "home.get_today",
            payload: BenchPayload(userId: "user-123", date: "2024-01-14", count: 42),
            requestId: "req-12345",
            channel: "user:self"
        )

        let start = Date().timeIntervalSinceReferenceDate
        for _ in 0..<10_000 {
            _ = try encoder.encode(message)
        }
        let elapsed = Date().timeIntervalSinceReferenceDate - start

        let msgsPerSec = 10_000 / elapsed
        print("Encode: \(Int(msgsPerSec)) msgs/sec, \(elapsed * 100) ms total")

        // Informational — CI runners vary widely, no hard threshold
        #expect(msgsPerSec > 1_000, "Encoding unreasonably slow: \(msgsPerSec) msgs/sec")
    }

    @Test("benchmark: decode 10,000 messages")
    func benchmarkDecode() throws {
        let decoder = JSONDecoder()
        let json = """
        {"event":"home.get_today","payload":{"userId":"user-123","date":"2024-01-14","count":42},"requestId":"req-12345","channel":"user:self"}
        """.data(using: .utf8)!

        let start = Date().timeIntervalSinceReferenceDate
        for _ in 0..<10_000 {
            _ = try decoder.decode(SockitMessage.self, from: json)
        }
        let elapsed = Date().timeIntervalSinceReferenceDate - start

        let msgsPerSec = 10_000 / elapsed
        print("Decode: \(Int(msgsPerSec)) msgs/sec, \(elapsed * 100) ms total")

        #expect(msgsPerSec > 1_000, "Decoding unreasonably slow: \(msgsPerSec) msgs/sec")
    }

    @Test("benchmark: reused encoder vs new encoder")
    func benchmarkEncoderReuse() throws {
        let message = SockitMessage(event: "test", requestId: "1")

        // New encoder each time (current implementation)
        let start1 = Date().timeIntervalSinceReferenceDate
        for _ in 0..<5_000 {
            let encoder = JSONEncoder()
            _ = try encoder.encode(message)
        }
        let newEncoderTime = Date().timeIntervalSinceReferenceDate - start1

        // Reused encoder
        let encoder = JSONEncoder()
        let start2 = Date().timeIntervalSinceReferenceDate
        for _ in 0..<5_000 {
            _ = try encoder.encode(message)
        }
        let reusedEncoderTime = Date().timeIntervalSinceReferenceDate - start2

        let speedup = newEncoderTime / reusedEncoderTime
        print("Encoder reuse speedup: \(String(format: "%.2f", speedup))x")
        print("  New encoder: \(String(format: "%.2f", newEncoderTime * 1000)) ms")
        print("  Reused encoder: \(String(format: "%.2f", reusedEncoderTime * 1000)) ms")

        // Reuse speedup varies by platform — just verify it doesn't regress badly
        #expect(speedup > 0.5, "Encoder reuse should not be dramatically slower")
    }

    // MARK: - Typed Payload Performance

    @Test("benchmark: typed payload decoding")
    func benchmarkTypedPayloadDecoding() throws {
        let json = """
        {"event":"test","payload":{"userId":"user-123","date":"2024-01-14","count":42},"requestId":"1"}
        """.data(using: .utf8)!

        let decoder = JSONDecoder()

        let start = Date().timeIntervalSinceReferenceDate
        for _ in 0..<10_000 {
            let message = try decoder.decode(SockitMessage.self, from: json)
            _ = try message.decodePayload(BenchPayload.self)
        }
        let elapsed = Date().timeIntervalSinceReferenceDate - start

        let opsPerSec = 10_000 / elapsed
        print("Typed payload decode: \(Int(opsPerSec)) ops/sec")

        #expect(opsPerSec > 500, "Typed decoding unreasonably slow")
    }

    // MARK: - Memory Allocation

    @Test("benchmark: message creation allocations")
    func benchmarkMessageCreation() throws {
        let start = Date().timeIntervalSinceReferenceDate

        for i in 0..<10_000 {
            let _ = try SockitMessage(
                event: "test.event",
                payload: SimplePayload(i: i),
                requestId: "req-\(i)",
                channel: "channel:\(i % 100)"
            )
        }

        let elapsed = Date().timeIntervalSinceReferenceDate - start
        let msgsPerSec = 10_000 / elapsed
        print("Message creation: \(Int(msgsPerSec)) msgs/sec")

        #expect(msgsPerSec > 5_000, "Message creation unreasonably slow")
    }
}

// MARK: - Size Benchmarks

private struct UserIdPayload: Codable, Sendable {
    let userId: String
}

@Suite("Message Size")
struct MessageSizeTests {

    @Test("message size: typical request")
    func typicalRequestSize() throws {
        let message = try SockitMessage(
            event: "home.get_today",
            payload: UserIdPayload(userId: "user-123-abc-def"),
            requestId: "550e8400-e29b-41d4-a716-446655440000",
            channel: "user:self"
        )

        let data = try JSONEncoder().encode(message)
        print("Typical request size: \(data.count) bytes")

        // Should be reasonable
        #expect(data.count < 300, "Message too large: \(data.count) bytes")
    }

    @Test("message size: large payload")
    func largePayloadSize() throws {
        var fields: [String: String] = [:]
        for i in 0..<100 {
            fields["field_\(i)"] = "value_\(i)_with_some_extra_content"
        }

        let message = try SockitMessage(
            event: "bulk.update",
            payload: fields,
            requestId: "req-123"
        )

        let data = try JSONEncoder().encode(message)
        print("Large payload size: \(data.count) bytes (\(fields.count) fields)")
    }
}
