// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MissionaryXCrucibleHardening",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "MissionaryXCore", targets: ["MissionaryXCore"]),
    ],
    targets: [
        .target(
            name: "MissionaryXCore",
            path: "Sources/MissionaryXCore"
        ),
        .testTarget(
            name: "MissionaryXCoreTests",
            dependencies: ["MissionaryXCore"],
            path: "Tests/MissionaryXCoreTests"
        ),
    ]
)
