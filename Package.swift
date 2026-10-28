// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Launchy",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Launchy",
            path: "Sources/Launchy"
        )
    ]
)
