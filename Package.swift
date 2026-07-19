// swift-tools-version: 5.9
import PackageDescription

// damson-ide — Orchard: a native macOS cockpit that runs CLI coding agents
// (Claude Code, …) side by side, each in its own git worktree.
//
// Reuses damson's GPU terminal engine + control layer via the DamsonTerminal and
// DamsonControl library products, pinned to a released damson tag so the daily
// churn in that repo can't break Orchard's build. Bump the dependency version
// deliberately when Orchard should pick up newer engine work.
let package = Package(
    name: "damson-ide",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Orchard", targets: ["Orchard"]),
        .executable(name: "orchard-cli", targets: ["orchard-cli"]),
    ],
    dependencies: [
        // Pinned to a specific damson commit (the one that dropped the Orchard
        // targets — earlier tags still declare them and collide by module name).
        // Deterministic + immune to damson's daily churn; bump this sha, or switch
        // to `from: "0.3.8"`, when Orchard should pick up newer engine work.
        .package(url: "https://github.com/hulryung/damson.git",
                 revision: "e4d14f95b8ab3ed12ec4522aa0dd2de279ca68f4"),
    ],
    targets: [
        .target(
            name: "DamsonOrchestrator",
            dependencies: [
                .product(name: "DamsonTerminal", package: "damson"),
                .product(name: "DamsonControl", package: "damson"),
            ],
            path: "Sources/DamsonOrchestrator"
        ),
        .target(
            name: "OrchardControl",
            dependencies: [
                .product(name: "DamsonControl", package: "damson"),
            ],
            path: "Sources/OrchardControl"
        ),
        .executableTarget(
            name: "Orchard",
            dependencies: [
                .product(name: "DamsonTerminal", package: "damson"),
                "DamsonOrchestrator",
                "OrchardControl",
            ],
            path: "Sources/Orchard",
            resources: [.copy("Resources/Orchard.icns")]
        ),
        .executableTarget(
            name: "orchard-cli",
            dependencies: ["OrchardControl"],
            path: "Sources/orchard-cli"
        ),
        .testTarget(
            name: "DamsonOrchestratorTests",
            dependencies: ["DamsonOrchestrator"],
            path: "Tests/DamsonOrchestratorTests"
        ),
    ]
)
