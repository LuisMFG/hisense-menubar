// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ArCondicionado",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ArCondicionado", path: "Sources/ArCondicionado")
    ]
)
