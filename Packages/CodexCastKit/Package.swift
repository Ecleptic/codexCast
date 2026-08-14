// swift-tools-version: 6.4
import PackageDescription

// One package, one module per subsystem. This gives the same enforced module
// boundaries as separate packages without seven Package.swift files to keep in
// sync. Dependencies point downward only: Core depends on nothing, and nothing
// depends on the app.
let package = Package(
    name: "CodexCastKit",
    platforms: [.iOS(.v27), .macOS(.v26)],
    products: [
        .library(name: "CodexCastCore", targets: ["CodexCastCore"]),
        .library(name: "CodexCastPersistence", targets: ["CodexCastPersistence"]),
        .library(name: "CodexCastFeeds", targets: ["CodexCastFeeds"]),
        .library(name: "CodexCastPlayback", targets: ["CodexCastPlayback"]),
        .library(name: "CodexCastTranscription", targets: ["CodexCastTranscription"]),
        .library(name: "CodexCastPipeline", targets: ["CodexCastPipeline"]),
        .library(name: "CodexCastDetection", targets: ["CodexCastDetection"]),
    ],
    dependencies: [
        // The only mandatory third-party dependency (§3).
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(name: "CodexCastCore"),
        .target(
            name: "CodexCastPersistence",
            dependencies: ["CodexCastCore", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(name: "CodexCastFeeds", dependencies: ["CodexCastCore"]),
        .target(name: "CodexCastPlayback", dependencies: ["CodexCastCore"]),
        .target(name: "CodexCastTranscription", dependencies: ["CodexCastCore"]),
        .target(
            name: "CodexCastPipeline",
            dependencies: ["CodexCastCore", "CodexCastPersistence", "CodexCastFeeds"]
        ),
        .target(
            name: "CodexCastDetection",
            dependencies: ["CodexCastCore", "CodexCastPersistence"]
        ),

        .testTarget(name: "CodexCastCoreTests", dependencies: ["CodexCastCore"]),
        .testTarget(
            name: "CodexCastFeedsTests",
            dependencies: ["CodexCastFeeds"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "CodexCastPersistenceTests",
            dependencies: ["CodexCastPersistence"]
        ),
        .testTarget(name: "CodexCastPlaybackTests", dependencies: ["CodexCastPlayback"]),
        .testTarget(name: "CodexCastDetectionTests", dependencies: ["CodexCastDetection"]),
    ],
    swiftLanguageModes: [.v6]
)
