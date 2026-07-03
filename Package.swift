// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SwiftClaw",
    platforms: [
        .macOS("27.0"),
        .iOS("27.0"),
    ],
    products: [
        .executable(
            name: "SwiftClaw",
            targets: ["SwiftClaw"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/MacPaw/OpenAI.git", branch: "main"),
        .package(url: "https://github.com/Cocoanetics/SwiftMail", revision: "3bfb4a3a2a9677c6090221f622c537870ee78960"),
    ],
    targets: [
        .executableTarget(
            name: "SwiftClaw",
            dependencies: [
                .product(name: "OpenAI", package: "OpenAI"),
                .product(name: "SwiftMail", package: "SwiftMail"),
            ],
            path: "SwiftClaw",
            resources: [
                .process("Assets.xcassets"),
            ]
        ),
        .testTarget(
            name: "SwiftClawTests",
            dependencies: ["SwiftClaw"],
            path: "SwiftClawTests"
        ),
    ]
)
