// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "LocalFlow",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        // Renamed from argmaxinc/WhisperKit at 1.0.0. The old URL still
        // redirects here, but depending on a redirect is fragile: it breaks
        // the moment a repo reoccupies the old name.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.0.0"),
        // In-app updates. Sparkle ships as a binary framework, so
        // scripts/make-app.sh embeds and signs it into the bundle.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "LocalFlow",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
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
