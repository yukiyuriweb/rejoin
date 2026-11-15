// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Rejoin",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Rejoin",
            path: "Sources/Rejoin",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
