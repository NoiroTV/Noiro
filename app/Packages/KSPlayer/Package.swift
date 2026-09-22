// swift-tools-version:5.9
import PackageDescription

/// Compact Vortexo-tested KSPlayer source, linked against the FFmpeg modules Noiro already receives from
/// MPVKit-GPL. Sharing that binary set avoids shipping two FFmpeg builds and avoids SwiftPM's duplicate
/// Libavcodec/Libavformat target collision.
let package = Package(
    name: "KSPlayer",
    defaultLocalization: "en",
    platforms: [.iOS(.v15), .tvOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "KSPlayer", targets: ["KSPlayer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/mpvkit/MPVKit", exact: "0.41.0-n8.1.2"),
    ],
    targets: [
        .target(
            name: "KSPlayer",
            dependencies: [
                "FFmpegKit",
                "DisplayCriteria",
            ],
            resources: [.process("Metal/Shaders.metal")]
        ),
        .target(
            name: "FFmpegKit",
            dependencies: [.product(name: "MPVKit-GPL", package: "MPVKit")],
            publicHeadersPath: "include"
        ),
        .target(name: "DisplayCriteria"),
    ],
    swiftLanguageVersions: [.v5]
)
