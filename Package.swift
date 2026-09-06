// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacTools",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "MacTools",
            path: "Sources/MacTools",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
    ]
)
