// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "QuickBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "QuickBar",
            path: "Sources/QuickBar",
            swiftSettings: [.unsafeFlags(["-Onone"], .when(configuration: .debug))]
        )
    ]
)
