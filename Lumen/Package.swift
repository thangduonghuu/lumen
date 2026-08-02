// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Lumen",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Lumen",
            resources: [.copy("Resources")]
        )
    ]
)
