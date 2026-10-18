// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "PaperManager",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "PaperManager", targets: ["PaperManager"]),
        .executable(name: "PaperManagerCLI", targets: ["PaperManagerCLI"])
    ],
    targets: [
        .executableTarget(
            name: "PaperManager",
            path: "Sources/PaperManager",
            // SwiftPM produces an executable, not an .app. The app icon is
            // packaged by build-app.sh or Xcode; excluding its catalog keeps
            // native SwiftPM builds usable with Command Line Tools alone.
            exclude: ["Resources/Assets.xcassets"],
            resources: [
                .copy("Resources/PrivacyInfo.xcprivacy"),
                .process("Resources/en.lproj"),
                .process("Resources/zh-Hans.lproj")
            ]
        ),
        .executableTarget(
            name: "PaperManagerCLI",
            path: "Sources/PaperManagerCLI"
        )
    ],
    swiftLanguageVersions: [.v5]
)
