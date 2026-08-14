// swift-tools-version: 6.4
import PackageDescription

// Phase 0 four-arm comparison harness. Throwaway with the rest of Spike/ —
// only the corpus and FINDINGS.md survive Phase 0. Depends on CodexCastKit so
// the arms are scored by the same EvalMetrics the app's harness uses.
let package = Package(
    name: "SpikeTool",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(path: "../../Packages/CodexCastKit")
    ],
    targets: [
        // Shared corpus location + reporting.
        .target(
            name: "SpikeShared",
            dependencies: [
                .product(name: "CodexCastDetection", package: "CodexCastKit")
            ]
        ),
        // Arm 4 — no FoundationModels link, so it runs everywhere.
        .executableTarget(
            name: "spike",
            dependencies: [
                "SpikeShared",
                .product(name: "CodexCastDetection", package: "CodexCastKit"),
            ]
        ),
        // Arm 1 — links FoundationModels. This Mac's OS predates the SDK's
        // @Generable additions, so this binary asks for JSON and parses it;
        // the on-device run uses guided generation properly.
        .executableTarget(
            name: "spikelm",
            dependencies: [
                "SpikeShared",
                .product(name: "CodexCastDetection", package: "CodexCastKit"),
            ]
        ),
    ]
)
