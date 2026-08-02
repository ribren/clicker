// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Clicker",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Clicker", path: "Sources/Clicker")
    ]
)
