// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sockit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
        // Linux: supported via Swift 6.0+ (no platform declaration needed)
    ],
    products: [
        .library(name: "SockitCore", targets: ["SockitCore"]),
        .library(name: "SockitClient", targets: ["SockitClient"]),
        .library(name: "SockitServer", targets: ["SockitServer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.99.0"),
        .package(url: "https://github.com/vapor/websocket-kit.git", from: "2.16.0"),
    ],
    targets: [
        // Core - shared types (no dependencies)
        .target(name: "SockitCore"),

        // Client - cross-platform WebSocket client
        // On Linux, automatically links NIOWebSocketTransport via conditional dependency
        .target(
            name: "SockitClient",
            dependencies: [
                "SockitCore",
                .target(name: "SockitNIOTransport", condition: .when(platforms: [.linux])),
            ]
        ),

        // NIO-based transport for Linux (uses websocket-kit)
        .target(
            name: "SockitNIOTransport",
            dependencies: [
                "SockitCore",
                .product(name: "WebSocketKit", package: "websocket-kit"),
            ]
        ),

        // Server - Vapor WebSocket server
        .target(
            name: "SockitServer",
            dependencies: [
                "SockitCore",
                .product(name: "Vapor", package: "vapor"),
            ]
        ),

        // Tests - Swift Testing framework
        .testTarget(
            name: "SockitCoreTests",
            dependencies: ["SockitCore"]
        ),
        .testTarget(
            name: "SockitClientTests",
            dependencies: ["SockitClient"]
        ),
        // Integration tests use NIO's HTTP pipeline API which contains types
        // that don't conform to Sendable (NIO API limitation, not Sockit's).
        // These run in Swift 5 language mode to avoid false positives.
        .testTarget(
            name: "SockitIntegrationTests",
            dependencies: [
                "SockitClient",
                "SockitNIOTransport",
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SockitServerTests",
            dependencies: ["SockitServer", "SockitClient"]
        ),
        .testTarget(
            name: "SockitNIOTransportTests",
            dependencies: ["SockitNIOTransport", "SockitCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
