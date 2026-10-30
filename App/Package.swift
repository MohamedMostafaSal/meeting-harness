// swift-tools-version:5.10
import PackageDescription

// The iPhone app. A Swift package so it builds with xtool on Linux and with Xcode
// on a Mac. The deterministic harness comes from the root package (HarnessCore);
// the on-device models come from Argmax's open-source SDK (WhisperKit, SpeakerKit).
let package = Package(
    name: "MeetingHarnessApp",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MeetingHarness", targets: ["MeetingHarness"]),
    ],
    dependencies: [
        .package(path: ".."),
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.1"),
    ],
    targets: [
        .target(
            name: "MeetingHarness",
            dependencies: [
                .product(name: "HarnessCore", package: "meeting-harness"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "SpeakerKit", package: "argmax-oss-swift"),
            ]
        ),
        .testTarget(
            name: "MeetingHarnessTests",
            dependencies: ["MeetingHarness"]
        ),
    ]
)
