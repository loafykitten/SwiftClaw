// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SwiftClaw",
    platforms: [
        .macOS("27.0"),
    ],
    products: [
        .executable(
            name: "SwiftClaw",
            targets: ["SwiftClaw"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/MacPaw/OpenAI.git", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "SwiftClaw",
            dependencies: [
                .product(name: "OpenAI", package: "OpenAI"),
            ],
            path: "SwiftClaw",
            resources: [
                .process("Assets.xcassets"),
            ]
        ),
    ]
)
