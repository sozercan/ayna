// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Ayna",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
        .watchOS(.v26),
    ],
    products: [
        .executable(name: "Ayna", targets: ["Ayna"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.8.1"),
    ],
    targets: [
        .executableTarget(
            name: "Ayna",
            dependencies: [
                .product(
                    name: "Sparkle",
                    package: "Sparkle",
                    condition: .when(platforms: [.macOS])
                ),
            ],
            path: "Sources/Ayna",
            exclude: [
                "Resources/ayna.icon",
            ],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "AynaTests",
            dependencies: ["Ayna"],
            path: "Tests/AynaTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
