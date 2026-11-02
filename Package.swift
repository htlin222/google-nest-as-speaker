// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "NestPlayer",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "NestPlayer", targets: ["NestPlayer"]),
    ],
    targets: [
        .executableTarget(name: "NestPlayer"),
        .testTarget(
            name: "NestPlayerTests",
            dependencies: ["NestPlayer"],
            path: "tests/NestPlayerTests"
        ),
    ]
)
