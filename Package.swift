// swift-tools-version: 6.2

import PackageDescription

#if os(macOS)
let sparkleDependency: [Package.Dependency] = [
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.8.1"),
]
let sparkleTarget: [Target.Dependency] = [
    .product(name: "Sparkle", package: "Sparkle", condition: .when(platforms: [.macOS])),
]
#else
let sparkleDependency: [Package.Dependency] = []
let sparkleTarget: [Target.Dependency] = []
#endif

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
    dependencies: sparkleDependency,
    targets: [
        .executableTarget(
            name: "Ayna",
            dependencies: sparkleTarget,
            path: "Sources/Ayna",
            exclude: [
                "Resources/ayna.icon",
                "App/Assets.xcassets",
                "Info.plist",
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
