// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeBabo",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "ClaudeBabo",
            path: "Sources/ClaudeBabo"
        )
    ]
)
