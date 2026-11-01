// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Purrch",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Purrch",
            path: "Sources/Purrch",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ],
    swiftLanguageModes: [.v5]
)
