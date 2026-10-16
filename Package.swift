// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "bitchat",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "bitchat",
            targets: ["bitchat"]
        )
    ],
    dependencies: [
        .package(path: "localPackages/Arti"),
        .package(path: "localPackages/BitFoundation"),
        .package(path: "localPackages/BitLogger"),
        // Upstream 0.21.1 plus Swift 6.4 compiler disambiguation; see docs/validation/BASELINE.md.
        .package(url: "https://github.com/samouraiworld/swift-secp256k1", revision: "0a1a9f9031b6f86f92eb9b66ef8a6882af531e6f")
    ],
    targets: [
        .executableTarget(
            name: "bitchat",
            dependencies: [
                .product(name: "P256K", package: "swift-secp256k1"),
                .product(name: "BitFoundation", package: "BitFoundation"),
                .product(name: "BitLogger", package: "BitLogger"),
                .product(name: "Tor", package: "Arti")
            ],
            path: "bitchat",
            exclude: [
                "Info.plist",
                "Assets.xcassets",
                "_PreviewHelpers/PreviewAssets.xcassets",
                "bitchat.entitlements",
                "bitchat-macOS.entitlements",
                "LaunchScreen.storyboard",
                "ViewModels/Extensions/README.md"
            ],
            resources: [
                .process("Localizable.xcstrings"),
                .process("Views/Wesh/Pave/Pave.xcstrings")
            ]
        ),
        .testTarget(
            name: "bitchatTests",
            dependencies: [
                "bitchat",
                .product(name: "BitFoundation", package: "BitFoundation")
            ],
            path: "bitchatTests",
            exclude: [
                "Info.plist",
                "README.md",
                // CI perf gate data (read by scripts/check-perf-floors.sh),
                // not a test resource.
                "Performance/perf-floors.json"
            ],
            resources: [
                .process("Localization"),
                // Only the vector fixture: declaring the whole "Noise"
                // directory would claim its .swift test files as resources
                // and silently drop them from compilation.
                .process("Noise/NoiseTestVectors.json"),
                // Frozen envelopes produced by the released iOS (733098bb)
                // and Android (b7f0b33d) private-DM implementations; prove
                // receive compatibility independently of the local generator.
                .process("Nostr/Fixtures"),
                // Signed QR vectors shared with the Android client.
                .process("Services/Fixtures")
            ]
        )
    ]
)
