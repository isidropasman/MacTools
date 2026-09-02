// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacTools",
    platforms: [.macOS("14.0")],
    targets: [
        .executableTarget(
            name: "Pila",
            path: "Sources/Pila",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
    ]
)
