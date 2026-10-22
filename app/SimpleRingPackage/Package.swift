// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "SimpleRingPackage",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SimpleRingFeature", targets: ["SimpleRingFeature"]),
        .library(name: "DesignSystem", targets: ["DesignSystem"]),
        .library(name: "RingClient", targets: ["RingClient"]),
    ],
    dependencies: [
        .package(url: "https://github.com/stasel/WebRTC.git", from: "125.0.0"),
    ],
    targets: [
        // Design tokens and small shared views
        .target(name: "DesignSystem"),

        // Ring API client and WebRTC live view
        .target(
            name: "RingClient",
            dependencies: [
                .product(name: "WebRTC", package: "WebRTC")
            ]
        ),

        // App UI
        .target(
            name: "SimpleRingFeature",
            dependencies: ["DesignSystem", "RingClient"]
        ),

        .testTarget(
            name: "SimpleRingFeatureTests",
            dependencies: ["SimpleRingFeature"]
        ),
    ]
)
