// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "meeting-harness",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        // The deterministic harness: schema, router, pipeline, connector, evaluation.
        .library(name: "HarnessCore", targets: ["HarnessCore"]),
        // Scripted stand-ins for the AI pillars, for tests and phone-free demos.
        .library(name: "HarnessTesting", targets: ["HarnessTesting"]),
        .executable(name: "harness-demo", targets: ["HarnessDemo"]),
    ],
    targets: [
        .target(name: "HarnessCore"),
        .target(name: "HarnessTesting", dependencies: ["HarnessCore"]),
        .executableTarget(name: "HarnessDemo", dependencies: ["HarnessCore", "HarnessTesting"]),
        .testTarget(name: "HarnessCoreTests", dependencies: ["HarnessCore", "HarnessTesting"]),
    ]
)
