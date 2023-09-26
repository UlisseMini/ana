// swift-tools-version: 5.8
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "bossgpt",
    platforms: [.macOS(.v12)],
    dependencies: [
        .package(url: "https://github.com/daltoniam/Starscream.git", .upToNextMajor(from: "4.0.6")),
        .package(url: "https://github.com/soffes/HotKey", from: "0.2.0")
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .executableTarget(
            name: "bossgpt",
            dependencies: [
                "Starscream",
                "HotKey"
            ],
            path: "Sources"),
    ]
)
