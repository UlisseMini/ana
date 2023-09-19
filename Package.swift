// swift-tools-version: 5.8
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "bossgpt-swift",
    platforms: [.macOS(.v12)],
    dependencies: [
        .package(url: "https://github.com/MacPaw/OpenAI.git", branch: "main")
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .executableTarget(
            name: "bossgpt-swift",
            dependencies: [
                .product(name: "OpenAI", package: "OpenAI")
            ],
            path: "Sources"),
    ]
)
