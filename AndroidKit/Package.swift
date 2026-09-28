// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AndroidKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "AndroidKit", targets: ["AndroidKit"]),
        .library(name: "AndymanCLI", targets: ["AndymanCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.6.0"),
    ],
    targets: [
        .target(name: "AndroidKit"),
        .target(
            name: "AndymanCLI",
            dependencies: [
                "AndroidKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "AndroidKitTests", dependencies: ["AndroidKit"]),
        .testTarget(name: "AndymanCLITests", dependencies: ["AndymanCLI"]),
    ]
)
