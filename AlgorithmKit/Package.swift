// swift-tools-version:5.9
// AlgorithmKit — plan step S0.2. The dosing core as a pure function, shared by the app
// (iOS) and the replay harness / CI (macOS). No Core Data, no DI, no UI in here.
import PackageDescription

let package = Package(
    name: "AlgorithmKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AlgorithmCore", targets: ["AlgorithmCore"]),
        .library(name: "JSOrefCore", targets: ["JSOrefCore"]),
        .executable(name: "trio-replay", targets: ["trio-replay"]),
    ],
    targets: [
        .target(
            name: "AlgorithmCore",
            path: "Sources/AlgorithmCore"
        ),
        .target(
            name: "JSOrefCore",
            dependencies: ["AlgorithmCore"],
            path: "Sources/JSOrefCore",
            resources: [.copy("Resources/javascript")]
        ),
        .executableTarget(
            name: "trio-replay",
            dependencies: ["AlgorithmCore", "JSOrefCore"],
            path: "Sources/trio-replay"
        ),
        .testTarget(
            name: "AlgorithmKitTests",
            dependencies: ["AlgorithmCore", "JSOrefCore"],
            path: "Tests/AlgorithmKitTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
