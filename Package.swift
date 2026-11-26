// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Wingman",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Wingman",
            path: "Sources/Wingman",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
