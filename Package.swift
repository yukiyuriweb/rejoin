// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Rejoin",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Rejoin",
            path: "Sources/Rejoin",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
