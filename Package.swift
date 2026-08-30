// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CanonSync",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "CanonSync",
            path: "Sources/CanonSync"
        )
    ]
)
