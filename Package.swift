// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "PaperManager",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "PaperManager", targets: ["PaperManager"])
    ],
    targets: [
        .executableTarget(
            name: "PaperManager",
            path: "Sources/PaperManager",
            resources: [
                .process("Resources")
            ]
        )
    ],
    swiftLanguageVersions: [.v5]
)
