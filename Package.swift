// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Purrch",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "PurrchCore", path: "Sources/PurrchCore"),
        .executableTarget(
            name: "Purrch",
            dependencies: ["PurrchCore"],
            path: "Sources/Purrch",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(name: "PurrchCoreTests", dependencies: ["PurrchCore"], path: "Tests/PurrchCoreTests"),
    ],
    swiftLanguageModes: [.v5]
)
