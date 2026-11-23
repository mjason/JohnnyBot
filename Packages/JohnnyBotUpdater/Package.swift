// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "JohnnyBotUpdater",
    platforms: [.macOS(.v13), .iOS(.v16), .visionOS(.v1)],
    products: [.library(name: "JohnnyBotUpdater", targets: ["JohnnyBotUpdater"])],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        .target(
            name: "JohnnyBotUpdater",
            dependencies: [.product(name: "Sparkle", package: "Sparkle", condition: .when(platforms: [.macOS]))]
        ),
    ]
)
