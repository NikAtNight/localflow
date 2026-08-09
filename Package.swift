// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "LocalFlow",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.0.0"),
        // In-app updates. Sparkle ships as a binary framework, so
        // scripts/make-app.sh embeds and signs it into the bundle.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "LocalFlow",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/LocalFlow"
        ),
        .testTarget(
            name: "LocalFlowTests",
            dependencies: ["LocalFlow"],
            path: "Tests/LocalFlowTests"
        )
    ]
)
