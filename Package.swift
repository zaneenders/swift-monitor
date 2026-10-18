// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "swift-monitor",
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.104.0"),
    ],
    targets: [
        .executableTarget(
            name: "swift-monitor",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "SwiftMonitorTests",
            dependencies: [
                "swift-monitor",
                .product(name: "NIOEmbedded", package: "swift-nio"),
            ]
        ),
    ]
)
