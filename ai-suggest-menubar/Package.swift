// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ai-suggest-menubar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "ai-suggest-menubar")
    ]
)
