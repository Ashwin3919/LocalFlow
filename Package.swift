// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LocalFlow",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "LocalFlow", targets: ["LocalFlow"])
    ],
    targets: [
        .executableTarget(
            name: "LocalFlow",
            path: "Sources/LocalFlow"
        )
    ]
)
