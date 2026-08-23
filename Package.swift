// swift-tools-version: 5.9
import PackageDescription

// damson-ide — Orchard v2: a native macOS multi-agent orchestrator IDE
// (see docs/REBUILD-PLAN.md). Runtime-first: a UI-free runtime owns worktrees,
// terminals, and orchestration state; the app is a client of it.
//
// Dependency rule: OrchardCore ← {OrchardTerminals, OrchardOrchestration} ←
// OrchardRuntime ← OrchardApp. The `orchard` CLI depends only on OrchardProtocol.
// Only OrchardTerminals and the app may import damson products.
//
// Naming note: the plan's `Orchard` app product/target collides with the `orchard`
// CLI on a case-insensitive filesystem (both the Sources/ directories and the
// .build output binaries are the same path), so the app target/product is
// `OrchardApp`; the user-visible identity stays "Orchard.app" via OrchardTrampoline.
let package = Package(
    name: "damson-ide",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "OrchardApp", targets: ["OrchardApp"]),
        .executable(name: "orchard", targets: ["orchard"]),
        .library(name: "OrchardCore", targets: ["OrchardCore"]),
        .library(name: "OrchardTerminals", targets: ["OrchardTerminals"]),
        .library(name: "OrchardOrchestration", targets: ["OrchardOrchestration"]),
        .library(name: "OrchardProtocol", targets: ["OrchardProtocol"]),
        .library(name: "OrchardRuntime", targets: ["OrchardRuntime"]),
    ],
    dependencies: [
        // damson's terminal engine + control wire, pinned to a released tag so the
        // daily churn in that repo can't break Orchard. Bump deliberately.
        .package(url: "https://github.com/hulryung/damson.git", from: "0.4.1"),
    ],
    targets: [
        // UI-free foundation: git, worktrees, per-repo config, shared utilities.
        // Must never import damson.
        .target(
            name: "OrchardCore",
            path: "Sources/OrchardCore"
        ),
        // Terminal + agent layer — the sole damson-importing library. Owns the
        // TerminalSession seam, agent engines, readiness detection, and hooks.
        .target(
            name: "OrchardTerminals",
            dependencies: [
                "OrchardCore",
                .product(name: "DamsonTerminal", package: "damson"),
                .product(name: "DamsonControl", package: "damson"),
            ],
            path: "Sources/OrchardTerminals"
        ),
        // SQLite orchestration store + semantics (runs/tasks/dispatch/messaging).
        // T1 fills this in; the target exists so its seams are addressable now.
        .target(
            name: "OrchardOrchestration",
            dependencies: ["OrchardCore"],
            path: "Sources/OrchardOrchestration"
        ),
        // Codable wire types + RPC envelope + command specs. Shared by the runtime
        // server and the CLI; no other dependencies by design.
        .target(
            name: "OrchardProtocol",
            path: "Sources/OrchardProtocol"
        ),
        // Runtime assembly: socket server, handler registry, and the domain
        // services behind RPC. T2–T4 fill in the subdirectories.
        .target(
            name: "OrchardRuntime",
            dependencies: [
                "OrchardCore",
                "OrchardTerminals",
                "OrchardOrchestration",
                "OrchardProtocol",
            ],
            path: "Sources/OrchardRuntime"
        ),
        // The agent-facing CLI. Client of the runtime socket; agent-context and
        // guides must keep working with no runtime running.
        .executableTarget(
            name: "orchard",
            dependencies: ["OrchardProtocol", "OrchardRuntime", "OrchardTerminals"],
            path: "Sources/orchard"
        ),
        // The app: SwiftUI shell hosting OrchardRuntime in-process.
        .executableTarget(
            name: "OrchardApp",
            dependencies: [
                .product(name: "DamsonTerminal", package: "damson"),
                "OrchardCore",
                "OrchardTerminals",
                "OrchardRuntime",
            ],
            path: "Sources/OrchardApp",
            resources: [.copy("Resources/Orchard.icns")]
        ),
        .testTarget(
            name: "OrchardCoreTests",
            dependencies: ["OrchardCore"],
            path: "Tests/OrchardCoreTests"
        ),
        .testTarget(
            name: "OrchardTerminalsTests",
            dependencies: ["OrchardTerminals", "OrchardCore"],
            path: "Tests/OrchardTerminalsTests"
        ),
        .testTarget(
            name: "OrchardOrchestrationTests",
            dependencies: ["OrchardOrchestration"],
            path: "Tests/OrchardOrchestrationTests"
        ),
        .testTarget(
            name: "OrchardRuntimeTests",
            dependencies: ["OrchardRuntime", "OrchardProtocol"],
            path: "Tests/OrchardRuntimeTests"
        ),
    ]
)
