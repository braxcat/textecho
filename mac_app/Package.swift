// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TextEchoApp",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "TextEchoApp", targets: ["TextEchoApp"])
    ],
    targets: [
        .executableTarget(
            name: "TextEchoApp",
            path: "Sources/TextEchoApp"
        )
    ]
)
