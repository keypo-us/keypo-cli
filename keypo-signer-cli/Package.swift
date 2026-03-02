// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "keypo-signer",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "keypo-signer", targets: ["keypo-signer"]),
        .library(name: "KeypoCore", targets: ["KeypoCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "keypo-signer",
            dependencies: [
                "KeypoCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(
            name: "KeypoCore",
            dependencies: []
        ),
        .testTarget(
            name: "KeypoCoreTests",
            dependencies: ["KeypoCore"]
        ),
    ]
)
