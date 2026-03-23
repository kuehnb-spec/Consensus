// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Consensus",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.17.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.3"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", .upToNextMinor(from: "2.29.1")),
    ],
    targets: [
        .executableTarget(
            name: "Consensus",
            dependencies: [
                "WhisperKit",
                .product(name: "SpeakerKit", package: "WhisperKit"),
                "FluidAudio",
                "ZIPFoundation",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            ],
            path: "Transcribo",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
