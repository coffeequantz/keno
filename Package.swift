// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Keno",
    platforms: [.macOS("13.3")],
    dependencies: [
        // SwiftTerm 1.99.2 plus one commit that lets Keno choose the GPU. Drop the fork if upstream takes it.
        .package(url: "https://github.com/coffeequantz/SwiftTerm.git", revision: "94818ae2da3aea23698057671d4ca0b8dc46c06c"),
    ],
    targets: [
        .executableTarget(
            name: "Keno",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm"), "whisper"],
            path: "Sources/Keno",
            swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))]
        ),
        // whisper.cpp (MIT) for local voice prompts, linked statically: nothing for users to install.
        // Built by scripts/build-whisper.sh: universal, Metal on Apple Silicon, AVX2 on Intel.
        .binaryTarget(
            name: "whisper",
            url: "https://github.com/coffeequantz/keno/releases/download/whisper-v1.9.5/whisper-v1.9.5-macos.xcframework.zip",
            checksum: "0a5d563ded211cbb2479f737e0d892d679a3ae063a092d12cfc9001d8477a209"
        ),
    ]
)
