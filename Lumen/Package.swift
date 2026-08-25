// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Lumen",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.6")
    ],
    targets: [
        .executableTarget(
            name: "Lumen",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            resources: [.copy("Resources")]
        ),
        .testTarget(
            name: "LumenTests",
            dependencies: ["Lumen"]
        )
    ]
)
