import Foundation

#if canImport(Qwen3ASR)
import Qwen3ASR
import AudioCommon
#endif

/// `ForcedAlignmentService` backed by Qwen3-ForcedAligner via the
/// `speech-swift` Swift Package (`https://github.com/soniqo/speech-swift`).
///
/// Compile-time guarded on `canImport(Qwen3ASR)` so the app builds whether or
/// not the SPM dependency has been added. When the dep is absent, every
/// method throws `ForcedAlignmentError.notImplemented` — callers should fall
/// back to `PassthroughForcedAlignmentService` in that case.
///
/// ### API notes (speech-swift 0.0.9, April 2026)
///
/// * Model: default is `aufklarer/Qwen3-ForcedAligner-0.6B-4bit` (MLX 4-bit,
///   ~500 MB). Weights download from HuggingFace on first use and cache to
///   `~/Library/Caches/qwen3-speech/`.
/// * `Qwen3ForcedAligner.fromPretrained(...)` is `async throws` with a
///   `progressHandler: ((Double, String) -> Void)?` parameter we wire through.
/// * `align(audio:text:sampleRate:language:)` is **synchronous** — it's a
///   single forward pass. The speech-swift type is a `class` (not an actor),
///   so we hold it inside an actor of our own to serialize access.
/// * The aligner returns `AudioCommon.AlignedWord` (fields `.text`, `.startTime`,
///   `.endTime` as `Float`), which we map to our `AlignedWordTiming`.
actor Qwen3ForcedAlignmentService: ForcedAlignmentService {
    let displayName = "Qwen3-ForcedAligner (local)"

    #if canImport(Qwen3ASR)
    private var aligner: Qwen3ForcedAligner?
    #endif

    func prepareModel(progressCallback: (@Sendable (Double) -> Void)?) async throws {
        #if canImport(Qwen3ASR)
        if aligner != nil { return }
        // Map speech-swift's `(Double, String)` progress signal to our `Double`-only
        // signature. The message describes the current phase (download, load, etc.)
        // which we swallow here — callers get a numeric progress value.
        aligner = try await Qwen3ForcedAligner.fromPretrained(
            progressHandler: { progress, _ in
                progressCallback?(progress)
            }
        )
        progressCallback?(1.0)
        #else
        _ = progressCallback
        throw ForcedAlignmentError.notImplemented(
            detail: "Add the `speech-swift` Swift Package and re-build to enable Qwen3 forced alignment."
        )
        #endif
    }

    func align(
        audioURL: URL,
        text: String,
        hintedWordCount: Int?
    ) async throws -> [AlignedWordTiming] {
        #if canImport(Qwen3ASR)
        if aligner == nil {
            try await prepareModel(progressCallback: nil)
        }
        guard let aligner else {
            throw ForcedAlignmentError.failed("Aligner did not initialize.")
        }

        let samples = try await ForcedAlignmentAudioLoader.loadMono16k(url: audioURL)

        // speech-swift's align is synchronous and runs a single forward pass.
        // We fully qualify the return type to disambiguate from any same-named
        // type in the Consensus module namespace.
        let rawWords: [AudioCommon.AlignedWord] = aligner.align(
            audio: samples,
            text: text,
            sampleRate: 16_000
        )

        let mapped: [AlignedWordTiming] = rawWords.compactMap { word in
            let trimmed = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return AlignedWordTiming(
                text: trimmed,
                start: TimeInterval(word.startTime),
                end: TimeInterval(max(word.endTime, word.startTime)),
                // speech-swift 0.0.9 does not expose a per-word confidence field.
                confidence: nil
            )
        }

        guard !mapped.isEmpty else { throw ForcedAlignmentError.emptyResult }
        _ = hintedWordCount  // currently unused; speech-swift infers word count from text
        let sorted = mapped.sorted { $0.start < $1.start }

        // Repair zero-duration words produced by the aligner's timestamp
        // quantization. Slice 3 benchmark showed 15–26% of words land with
        // start == end on real-world phone-call audio; this post-process
        // extends each such word's `end` forward by up to 60 ms, clipped
        // to the next word's start. See AlignedWordTimingPostprocess docs.
        let (repaired, _) = AlignedWordTimingPostprocess.enforceMinimumDurationCounted(sorted)
        return repaired
        #else
        _ = (audioURL, text, hintedWordCount)
        throw ForcedAlignmentError.notImplemented(
            detail: "Add the `speech-swift` Swift Package and re-build to enable Qwen3 forced alignment."
        )
        #endif
    }

    func alignSegments(
        audioURL: URL,
        hints: [ForcedAlignmentHint],
        maxChunkSeconds: TimeInterval
    ) async throws -> [AlignedWordTiming] {
        #if canImport(Qwen3ASR)
        if aligner == nil {
            try await prepareModel(progressCallback: nil)
        }
        guard let aligner else {
            throw ForcedAlignmentError.failed("Aligner did not initialize.")
        }
        guard !hints.isEmpty else {
            throw ForcedAlignmentError.emptyResult
        }

        // Load audio once; we'll slice per chunk.
        let samples = try await ForcedAlignmentAudioLoader.loadMono16k(url: audioURL)

        // Group consecutive hints into chunks whose combined audio span is
        // <= maxChunkSeconds. Single-hint chunks are always allowed even if
        // they exceed the ceiling (a very long single turn is still a
        // single alignment call — we'd rather degrade than drop audio).
        struct Chunk {
            var audioStart: TimeInterval
            var audioEnd: TimeInterval
            var text: String
        }
        var chunks: [Chunk] = []
        var i = 0
        while i < hints.count {
            let base = hints[i]
            var audioEnd = base.audioEnd
            var combinedText = base.text
            var j = i
            while j + 1 < hints.count {
                let nextEnd = hints[j + 1].audioEnd
                if nextEnd - base.audioStart > maxChunkSeconds { break }
                j += 1
                audioEnd = hints[j].audioEnd
                let sep = combinedText.isEmpty ? "" : " "
                combinedText = combinedText + sep + hints[j].text
            }
            chunks.append(Chunk(
                audioStart: base.audioStart,
                audioEnd: audioEnd,
                text: combinedText
            ))
            i = j + 1
        }

        // Align each chunk, offsetting timestamps back to absolute time.
        // Pad by 0.5 s on each side to give the aligner edge context.
        let edgePad: TimeInterval = 0.5
        var combined: [AlignedWordTiming] = []
        for chunk in chunks {
            let slice = ForcedAlignmentAudioLoader.slice(
                samples,
                from: chunk.audioStart - edgePad,
                to: chunk.audioEnd + edgePad
            )
            guard !slice.samples.isEmpty else { continue }
            let raw: [AudioCommon.AlignedWord] = aligner.align(
                audio: slice.samples,
                text: chunk.text,
                sampleRate: 16_000
            )
            for w in raw {
                let text = w.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                combined.append(AlignedWordTiming(
                    text: text,
                    start: TimeInterval(w.startTime) + slice.start,
                    end: TimeInterval(max(w.endTime, w.startTime)) + slice.start,
                    confidence: nil
                ))
            }
        }

        guard !combined.isEmpty else { throw ForcedAlignmentError.emptyResult }

        // Repair zero-duration words the same way align() does.
        let sorted = combined.sorted { $0.start < $1.start }
        let (repaired, _) = AlignedWordTimingPostprocess.enforceMinimumDurationCounted(sorted)
        return repaired
        #else
        _ = (audioURL, hints, maxChunkSeconds)
        throw ForcedAlignmentError.notImplemented(
            detail: "Add the `speech-swift` Swift Package and re-build to enable Qwen3 forced alignment."
        )
        #endif
    }

    func unload() async {
        #if canImport(Qwen3ASR)
        aligner = nil
        #endif
    }
}

/// Factory that returns the best available forced-alignment service given
/// current build configuration. Call-sites should use this rather than
/// instantiating concrete types, so removing/adding the speech-swift dep
/// is a one-line change.
enum ForcedAlignmentServiceFactory {
    static func make(enabled: Bool) -> any ForcedAlignmentService {
        guard enabled else { return PassthroughForcedAlignmentService() }
        #if canImport(Qwen3ASR)
        return Qwen3ForcedAlignmentService()
        #else
        return PassthroughForcedAlignmentService()
        #endif
    }

    /// `true` when a real aligner will be returned by `make(enabled: true)`.
    /// Use to gate UI that advertises the feature.
    static var isAvailable: Bool {
        #if canImport(Qwen3ASR)
        return true
        #else
        return false
        #endif
    }
}
