// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Consensus",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.17.0"),
        .package(path: "Vendor/FluidAudio"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", .upToNextMinor(from: "2.30.6")),
        // speech-swift (soniqo) — provides Qwen3-ForcedAligner for post-Deep-Transcription
        // word-timing rebuild. See Brainstorming/WORD-TIMELINE-REBUILD-PLAN.md, Slice 2.
        .package(url: "https://github.com/soniqo/speech-swift.git", from: "0.0.9"),
    ],
    targets: [
        // Standalone smoke harness that exercises Qwen3-ForcedAligner via the
        // exact API path our `Qwen3ForcedAlignmentService` wrapper uses.
        // Run with: swift run SmokeAlignment <audio-file> [optional reference text]
        // See Brainstorming/WORD-TIMELINE-REBUILD-PLAN.md, Slice 2.
        .executableTarget(
            name: "SmokeAlignment",
            dependencies: [
                .product(name: "Qwen3ASR", package: "speech-swift"),
            ],
            path: "Scripts/SmokeAlignment",
            swiftSettings: [
                // Match the Consensus target; Swift 6 strict concurrency flags
                // the speech-swift progressHandler closure as non-Sendable.
                .swiftLanguageMode(.v5),
            ]
        ),
        // Batch benchmark harness — runs ASR + forced alignment over a set of
        // audio files and reports RTF, word-count, and deviation-from-linear
        // statistics. Used to answer "is the aligner actually doing work or
        // silently emitting trivial output?" before we trust it in production.
        // See Brainstorming/WORD-TIMELINE-REBUILD-PLAN.md, Slice 3.
        .executableTarget(
            name: "AlignmentBenchmark",
            dependencies: [
                .product(name: "Qwen3ASR", package: "speech-swift"),
            ],
            path: "Scripts/AlignmentBenchmark",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        // Exports a Consensus project.json into a flat JSON ground-truth file
        // (per-word timings + speaker IDs + resolved speaker names) suitable
        // for tcpWER/DER measurement and for comparing forced-alignment
        // output against human-verified timings.
        //
        // Originally planned to parse the Legal PDF export, but Consensus's
        // Legal PDF rasterizes glyphs (no text layer), so we read from the
        // project.json instead — which also has per-word timings the PDF
        // doesn't encode. See Brainstorming/WORD-TIMELINE-REBUILD-PLAN.md,
        // Slice 4.5.
        .executableTarget(
            name: "GroundTruthExporter",
            path: "Scripts/GroundTruthExporter",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        // Compares Qwen3-ForcedAligner output against a ground-truth JSON
        // (produced by GroundTruthExporter). Reports word-level start-time
        // offsets: mean / median / p95 / max, percentage within tolerance
        // bands, and per-speaker boundary accuracy. This is the first
        // quantitative answer to "is forced alignment actually better than
        // the ASR engines' own word timings on our audio?"
        // See Brainstorming/WORD-TIMELINE-REBUILD-PLAN.md, Slice 4.5.
        .executableTarget(
            name: "AlignmentValidator",
            dependencies: [
                .product(name: "Qwen3ASR", package: "speech-swift"),
            ],
            path: "Scripts/AlignmentValidator",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .executableTarget(
            name: "Consensus",
            dependencies: [
                "WhisperKit",
                .product(name: "SpeakerKit", package: "WhisperKit"),
                "FluidAudio",
                "ZIPFoundation",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Qwen3ASR", package: "speech-swift"),
            ],
            path: "Transcribo",
            resources: [
                // Bundled OFL-licensed typefaces for the rewritten UI
                // (Phase 0, April 21, 2026). Registered at app launch via
                // `FontRegistration.registerBundledFonts()`.
                .copy("App/Resources/Fonts/Inter"),
                .copy("App/Resources/Fonts/SourceSerif4"),
                .copy("App/Resources/Fonts/JetBrainsMono"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
