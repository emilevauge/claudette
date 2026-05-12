// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Claudette",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Claudette", targets: ["Claudette"])
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", from: "2.0.0")
    ],
    targets: [
        .executableTarget(
            name: "Claudette",
            dependencies: [
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")
            ],
            path: "Sources/Claudette",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
