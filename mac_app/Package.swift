// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TextEchoApp",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "TextEchoApp", targets: ["TextEchoApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0")
    ],
    targets: [
        .executableTarget(
            name: "TextEchoApp",
            dependencies: ["WhisperKit"],
            path: "Sources/TextEchoApp"
        )
    ]
)
