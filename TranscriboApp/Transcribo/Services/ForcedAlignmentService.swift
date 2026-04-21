import AVFoundation
import Foundation

/// A single word with timings produced by a forced-alignment pass.
/// Unlike `TranscriptionSegment.WordTiming`, this type is produced *after*
/// final text selection (post-Deep-Transcription), so its confidence is
/// the aligner's own signal, not the source ASR engine's per-token probability.
struct AlignedWordTiming: Sendable, Equatable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
    /// Aligner-reported confidence in the [0, 1] range. `nil` if the aligner
    /// does not surface a confidence signal.
    let confidence: Float?

    init(text: String, start: TimeInterval, end: TimeInterval, confidence: Float? = nil) {
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
    }
}

/// Summary statistics describing how much a forced-alignment pass changed
/// word timings vs. the input ASR timings. Surfaced in the process log so we
/// can eyeball impact on real recordings before we trust the pass.
struct ForcedAlignmentDelta: Sendable {
    let wordsAligned: Int
    let wordsUnmatched: Int
    let meanStartDelta: TimeInterval
    let maxStartDelta: TimeInterval
    let meanDurationDelta: TimeInterval

    var summaryLine: String {
        let meanMs = Int((meanStartDelta * 1000).rounded())
        let maxMs = Int((maxStartDelta * 1000).rounded())
        return "\(wordsAligned) words aligned, \(wordsUnmatched) unmatched · mean Δstart \(meanMs)ms · max Δstart \(maxMs)ms"
    }
}

/// Errors specific to the forced-alignment stage.
enum ForcedAlignmentError: Error, LocalizedError {
    /// The concrete implementation is present but disabled (e.g. setting off).
    case disabled
    /// The implementation is a compile-time stub; the underlying model isn't wired yet.
    case notImplemented(detail: String)
    /// The aligner produced no usable output.
    case emptyResult
    /// The aligner failed internally.
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .disabled:
            return "Forced alignment is disabled in Settings."
        case .notImplemented(let detail):
            return "Forced alignment is not yet wired up. \(detail)"
        case .emptyResult:
            return "The forced aligner produced no aligned words."
        case .failed(let message):
            return "Forced alignment failed: \(message)"
        }
    }
}

/// A rough audio-range + expected text, used to guide chunked alignment.
/// Usually one of these per Deep-Transcription speaker turn.
struct ForcedAlignmentHint: Sendable {
    /// Expected start of this segment in the original audio (seconds).
    let audioStart: TimeInterval
    /// Expected end of this segment in the original audio (seconds).
    let audioEnd: TimeInterval
    /// The text expected inside this segment.
    let text: String

    init(audioStart: TimeInterval, audioEnd: TimeInterval, text: String) {
        self.audioStart = audioStart
        self.audioEnd = audioEnd
        self.text = text
    }
}

/// A stage that rebuilds word timings for a finalized text transcript
/// against the source audio. Runs *after* Deep Transcription has chosen
/// the best text, so a single high-quality alignment benefits every
/// downstream consumer (diarization, subtitle export, flag ranges).
///
/// Implementations are expected to be lazy: model weights load on the
/// first `align(...)` call, not at app launch.
protocol ForcedAlignmentService: Sendable {
    /// Human-readable name for process-log display.
    var displayName: String { get }

    /// Preload model weights if the implementation benefits from warm-up.
    /// May be a no-op.
    func prepareModel(progressCallback: (@Sendable (Double) -> Void)?) async throws

    /// Align `text` against the audio at `audioURL` and return word-level timings.
    ///
    /// For long audio (> a few minutes) callers should prefer `alignSegments`
    /// — single-shot alignment on long context degrades sharply because the
    /// aligner's timestamp quantizer has a fixed class count.
    ///
    /// - Parameters:
    ///   - audioURL: Source audio file. Implementations are responsible for resampling.
    ///   - text: The finalized text to align. Whitespace-normalized; punctuation preserved.
    ///   - hintedWordCount: Expected word count from the ASR-produced timings, used
    ///     by some implementations to bound decoding. Pass `nil` if unknown.
    /// - Returns: A time-sorted list of aligned words. The aligner is not required
    ///   to produce exactly one entry per whitespace-separated input token; callers
    ///   should reconcile counts downstream.
    func align(
        audioURL: URL,
        text: String,
        hintedWordCount: Int?
    ) async throws -> [AlignedWordTiming]

    /// Align `hints` against the audio at `audioURL`, chunking along the
    /// provided boundaries. The **required** method for any audio over
    /// ~2 minutes — the AlignmentValidator against Clayton Everett's
    /// 19-minute Consensus ground truth showed single-shot alignment
    /// produced 1.6% matched words at median delta > 90 s, while chunked
    /// alignment along segment boundaries produced 72% matched with
    /// median delta 300 ms. See Brainstorming/WORD-TIMELINE-REBUILD-PLAN.md.
    ///
    /// - Parameters:
    ///   - audioURL: Source audio file.
    ///   - hints: Ordered per-segment (start, end, text) hints. Typically
    ///     derived from `MergedTranscript.segments`.
    ///   - maxChunkSeconds: Upper bound on per-alignment-call audio
    ///     duration. Implementations coalesce consecutive hints whose
    ///     combined span fits under this ceiling. Default 120 s.
    /// - Returns: Time-sorted list of aligned words, with timestamps
    ///   expressed in the **original** audio timeline (not per-chunk).
    func alignSegments(
        audioURL: URL,
        hints: [ForcedAlignmentHint],
        maxChunkSeconds: TimeInterval
    ) async throws -> [AlignedWordTiming]

    /// Release any model weights held in memory.
    func unload() async
}

extension ForcedAlignmentService {
    /// Default-argument convenience wrapping alignSegments with a 120 s ceiling.
    func alignSegments(
        audioURL: URL,
        hints: [ForcedAlignmentHint]
    ) async throws -> [AlignedWordTiming] {
        try await alignSegments(audioURL: audioURL, hints: hints, maxChunkSeconds: 120.0)
    }
}

// MARK: - Passthrough implementation

/// A no-op `ForcedAlignmentService` that always throws `.disabled`.
/// Used when the setting is off or when no real aligner is available,
/// so the call-site can treat "no alignment" as a normal error path
/// instead of needing a `?` branch everywhere.
struct PassthroughForcedAlignmentService: ForcedAlignmentService {
    let displayName = "Passthrough (disabled)"

    func prepareModel(progressCallback: (@Sendable (Double) -> Void)?) async throws {}

    func align(audioURL: URL, text: String, hintedWordCount: Int?) async throws -> [AlignedWordTiming] {
        throw ForcedAlignmentError.disabled
    }

    func alignSegments(
        audioURL: URL,
        hints: [ForcedAlignmentHint],
        maxChunkSeconds: TimeInterval
    ) async throws -> [AlignedWordTiming] {
        throw ForcedAlignmentError.disabled
    }

    func unload() async {}
}

// MARK: - Post-processing helpers

/// Cleanup utilities for aligner output. Run before handing results to the
/// rest of the app.
///
/// Forced aligners typically classify timestamps over a discrete grid
/// (Qwen3-ForcedAligner uses 5000 classes across the audio time axis). When
/// adjacent words are spoken in rapid succession, multiple words can snap
/// to the same grid cell and emerge as `start == end`. That's well-defined
/// aligner behavior, not a bug, but it produces unusable word durations
/// downstream (zero-width word boxes in waveform UI, division-by-zero in
/// some confidence calculations, etc.), so we repair them here.
enum AlignedWordTimingPostprocess {
    /// Minimum word duration used when repairing zero-duration output.
    /// Informed by average phoneme length — most real spoken words are at
    /// least 60 ms even in fast speech.
    static let defaultMinimumDurationSeconds: TimeInterval = 0.060

    /// Repair any word whose `end - start` is below `minimumDuration` by
    /// extending `end` forward, clipped to the start of the next word
    /// (so we never overlap). The last word is extended by the full
    /// minimum regardless.
    ///
    /// Preserves the aligner's `start` value exactly — only `end` moves.
    /// This is the conservative choice; the aligner's `start` is usually
    /// the more reliable field since it's predicted from audio onset cues.
    static func enforceMinimumDuration(
        _ words: [AlignedWordTiming],
        minimumDuration: TimeInterval = defaultMinimumDurationSeconds
    ) -> [AlignedWordTiming] {
        guard !words.isEmpty else { return words }
        var result: [AlignedWordTiming] = []
        result.reserveCapacity(words.count)

        for (i, w) in words.enumerated() {
            let currentDuration = w.end - w.start
            if currentDuration >= minimumDuration {
                result.append(w)
                continue
            }

            // Determine the ceiling: next word's start (if any), otherwise unbounded.
            let nextStart: TimeInterval? = (i + 1 < words.count) ? words[i + 1].start : nil
            let desiredEnd = w.start + minimumDuration
            let clampedEnd: TimeInterval
            if let ns = nextStart {
                // Leave a tiny gap (1 ms) so consecutive words don't share a frame.
                clampedEnd = min(desiredEnd, max(w.start, ns - 0.001))
            } else {
                clampedEnd = desiredEnd
            }

            result.append(AlignedWordTiming(
                text: w.text,
                start: w.start,
                end: clampedEnd,
                confidence: w.confidence
            ))
        }
        return result
    }

    /// Convenience: returns `(repaired, repairCount)` so callers can log
    /// how many words were touched.
    static func enforceMinimumDurationCounted(
        _ words: [AlignedWordTiming],
        minimumDuration: TimeInterval = defaultMinimumDurationSeconds
    ) -> (repaired: [AlignedWordTiming], repairCount: Int) {
        let zeroDurBefore = words.filter { $0.end - $0.start < minimumDuration }.count
        let repaired = enforceMinimumDuration(words, minimumDuration: minimumDuration)
        return (repaired, zeroDurBefore)
    }
}

// MARK: - Audio loading helper shared across implementations

enum ForcedAlignmentAudioLoader {
    static let defaultSampleRate: Double = 16_000

    /// Slice a previously-loaded 16 kHz Float32 buffer to `[start, end]` seconds,
    /// clamping to valid range. Returns `(samples, clampedStart, clampedEnd)` so
    /// the caller can offset absolute timestamps after aligning.
    static func slice(
        _ samples: [Float],
        from start: TimeInterval,
        to end: TimeInterval,
        sampleRate: Double = defaultSampleRate
    ) -> (samples: [Float], start: TimeInterval, end: TimeInterval) {
        let totalDuration = Double(samples.count) / sampleRate
        let clampedStart = max(0, min(start, totalDuration))
        let clampedEnd = max(clampedStart, min(end, totalDuration))
        let s = Int(clampedStart * sampleRate)
        let e = min(Int(clampedEnd * sampleRate), samples.count)
        guard s < e else { return ([], clampedStart, clampedStart) }
        return (Array(samples[s..<e]), clampedStart, clampedEnd)
    }

    /// Load an audio file as a 16 kHz mono Float32 PCM buffer.
    /// Matches the shape SpeakerKitDiarizationService already uses; most aligners
    /// accept this natively or resample from it cheaply.
    static func loadMono16k(url: URL) async throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw ForcedAlignmentError.failed("Could not build 16 kHz mono target format.")
        }

        guard let converter = AVAudioConverter(from: file.processingFormat, to: targetFormat) else {
            throw ForcedAlignmentError.failed("Could not build audio converter.")
        }

        let frameCapacity = AVAudioFrameCount(
            Double(file.length) * 16_000.0 / file.processingFormat.sampleRate
        )
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else {
            throw ForcedAlignmentError.failed("Could not allocate PCM buffer.")
        }

        var conversionError: NSError?
        let input: AVAudioConverterInputBlock = { _, status in
            let readCount: AVAudioFrameCount = 4096
            guard let readBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: readCount) else {
                status.pointee = .endOfStream
                return nil
            }
            do {
                try file.read(into: readBuffer)
                if readBuffer.frameLength == 0 {
                    status.pointee = .endOfStream
                    return nil
                }
                status.pointee = .haveData
                return readBuffer
            } catch {
                status.pointee = .endOfStream
                return nil
            }
        }

        converter.convert(to: output, error: &conversionError, withInputFrom: input)
        if let conversionError {
            throw ForcedAlignmentError.failed("Audio conversion failed: \(conversionError.localizedDescription)")
        }

        guard let channel = output.floatChannelData else {
            throw ForcedAlignmentError.failed("No float channel data on converted buffer.")
        }
        let count = Int(output.frameLength)
        return Array(UnsafeBufferPointer(start: channel[0], count: count))
    }
}
