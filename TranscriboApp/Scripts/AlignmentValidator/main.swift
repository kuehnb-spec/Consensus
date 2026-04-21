import AVFoundation
import AudioCommon
import Foundation
import Qwen3ASR

// Validates Qwen3-ForcedAligner output against a ground-truth JSON produced
// by `GroundTruthExporter`. Both aligner and ground-truth word streams
// should describe the same audio; we compare per-word start times.
//
// For each aligned word we find the corresponding ground-truth word by
// greedy text matching within a tolerance window. We report:
//   - absolute start-time offsets (mean / median / p95 / max / std)
//   - percentage within ±50 ms, ±100 ms, ±250 ms, ±500 ms, ±1 s tolerance
//   - per-speaker turn-boundary offset (first word of each GT speaker turn
//     vs. the nearest aligned word with the same word text)
//
// Usage:
//   swift run AlignmentValidator <ground-truth.json> [--audio <path>] \
//       [--aligner-model <id>] [--min-dur <seconds>]
//
// If --audio is omitted we use the `audioPath` recorded in the ground truth.

@main
struct AlignmentValidator {
    // MARK: - Ground-truth schema mirror

    struct GroundTruth: Codable {
        let sourceProject: String
        let projectName: String?
        let passKind: String
        let passModel: String?
        let audioPath: String?
        let durationSec: Double?
        let speakerNames: [String: String]?
        let segments: [GTSegment]
    }
    struct GTSegment: Codable {
        let start: Double
        let end: Double
        let speakerID: String?
        let speakerName: String?
        let text: String
        let words: [GTWord]
    }
    struct GTWord: Codable {
        let word: String
        let start: Double
        let end: Double
        let probability: Double?
    }

    // MARK: - Report schema

    struct Report: Codable {
        let groundTruthPath: String
        let audioPath: String
        let alignerModelId: String
        let durationSec: Double
        let groundTruthWordCount: Int
        let alignedWordCount: Int
        let matchedWordCount: Int
        let matchRate: Double
        // Distribution of absolute start-time deltas (aligner - gt) in seconds.
        let meanAbsOffsetSec: Double
        let medianAbsOffsetSec: Double
        let p95AbsOffsetSec: Double
        let maxAbsOffsetSec: Double
        let stddevOffsetSec: Double
        // Signed mean (positive = aligner runs late).
        let meanSignedOffsetSec: Double
        // Percentage of matched words within tolerance bands.
        let percentWithin50ms: Double
        let percentWithin100ms: Double
        let percentWithin250ms: Double
        let percentWithin500ms: Double
        let percentWithin1000ms: Double
        // Per-speaker-turn boundary offset.
        let turnBoundaryCount: Int
        let meanTurnBoundaryOffsetSec: Double
        let medianTurnBoundaryOffsetSec: Double
        let maxTurnBoundaryOffsetSec: Double
        // Alignment timing.
        let alignmentElapsedSec: Double
        let alignmentRTF: Double
        // Unmatched sample for debugging.
        let unmatchedExamples: [String]
    }

    static func main() async {
        setbuf(stdout, nil)
        setbuf(stderr, nil)

        let args = Array(CommandLine.arguments.dropFirst())
        guard !args.isEmpty else {
            FileHandle.standardError.write(Data("""
            usage: swift run AlignmentValidator <ground-truth.json> \\
                [--audio <path>] [--aligner-model <id>] [--min-dur <seconds>] \\
                [--out <report.json>]

              --aligner-model  Default: aufklarer/Qwen3-ForcedAligner-0.6B-4bit
              --min-dur        Minimum word duration used to repair zero-duration
                               aligner output. Default 0.060.
              --out            Report JSON path. Default /tmp/alignment-validator.json

            """.utf8))
            exit(2)
        }

        let gtPath = args[0]
        var audioOverride: String?
        var alignerModelId = "aufklarer/Qwen3-ForcedAligner-0.6B-4bit"
        var minDuration: Double = 0.060
        var outPath = "/tmp/alignment-validator.json"

        var i = 1
        while i < args.count {
            switch args[i] {
            case "--audio":
                if i + 1 < args.count { audioOverride = args[i + 1]; i += 2 } else { i += 1 }
            case "--aligner-model":
                if i + 1 < args.count { alignerModelId = args[i + 1]; i += 2 } else { i += 1 }
            case "--min-dur":
                if i + 1 < args.count, let v = Double(args[i + 1]) { minDuration = v; i += 2 } else { i += 1 }
            case "--out":
                if i + 1 < args.count { outPath = args[i + 1]; i += 2 } else { i += 1 }
            default:
                i += 1
            }
        }

        // Load ground truth.
        let gtURL = URL(fileURLWithPath: gtPath)
        let gt: GroundTruth
        do {
            let data = try Data(contentsOf: gtURL)
            gt = try JSONDecoder().decode(GroundTruth.self, from: data)
        } catch {
            FileHandle.standardError.write(Data("error: could not load ground truth: \(error)\n".utf8))
            exit(1)
        }

        // Resolve audio path.
        let audioPath = audioOverride ?? gt.audioPath
        guard let audioPath, FileManager.default.fileExists(atPath: audioPath) else {
            FileHandle.standardError.write(Data("error: audio path not found. Pass --audio explicitly.\n".utf8))
            exit(1)
        }

        print("Validating alignment against ground truth")
        print("  Ground truth: \(gtPath)")
        print("  Audio:        \(audioPath)")
        print("  Aligner:      \(alignerModelId)")

        // Build reference text from ground-truth segments (preserves order).
        let gtWords: [GTWord] = gt.segments.flatMap(\.words)
        let text = gtWords.map(\.word).joined(separator: " ")
        let duration = gt.durationSec ?? 0

        print("  GT words:     \(gtWords.count)")
        print("  Duration:     \(String(format: "%.1fs (%.1fm)", duration, duration / 60.0))")

        // Load audio + aligner.
        let audio: [Float]
        do {
            audio = try loadMono16k(url: URL(fileURLWithPath: audioPath))
        } catch {
            FileHandle.standardError.write(Data("error: audio load failed: \(error)\n".utf8))
            exit(1)
        }

        let aligner: Qwen3ForcedAligner
        do {
            aligner = try await Qwen3ForcedAligner.fromPretrained(modelId: alignerModelId)
        } catch {
            FileHandle.standardError.write(Data("error: aligner load failed: \(error)\n".utf8))
            exit(1)
        }

        // Run alignment. For audio longer than ~2 minutes, chunk along GT
        // segment boundaries — the aligner's single-shot context can't
        // handle full-length phone calls (first-run Clayton Everett smoke
        // showed all 25 head words collapsing to t=92.96s on a 19-min
        // single-shot). For the validator we can use GT segment boundaries
        // to chunk; production code will use the ASR engine's segments.
        let chunkTargetSec: Double = 120.0 // 2 minutes per chunk
        print("  Aligning in chunks of ~\(Int(chunkTargetSec))s along GT segment boundaries…")

        // Build chunks of contiguous GT segments that sum to <= chunkTargetSec.
        struct Chunk {
            let audioStart: TimeInterval  // original-audio time (seconds)
            let audioEnd: TimeInterval
            let text: String
            let wordCount: Int
        }
        var chunks: [Chunk] = []
        var segStart = 0
        while segStart < gt.segments.count {
            var cumEnd = gt.segments[segStart].end
            var segEnd = segStart
            while segEnd + 1 < gt.segments.count,
                  gt.segments[segEnd + 1].end - gt.segments[segStart].start <= chunkTargetSec {
                segEnd += 1
                cumEnd = gt.segments[segEnd].end
            }
            let chunkText = (segStart...segEnd)
                .flatMap { gt.segments[$0].words.map(\.word) }
                .joined(separator: " ")
            let wordCount = (segStart...segEnd).reduce(0) { $0 + gt.segments[$1].words.count }
            chunks.append(Chunk(
                audioStart: gt.segments[segStart].start,
                audioEnd: cumEnd,
                text: chunkText,
                wordCount: wordCount
            ))
            segStart = segEnd + 1
        }
        print("  → \(chunks.count) chunks, max \(chunks.map(\.wordCount).max() ?? 0) words")

        // Align each chunk against its slice of audio (+0.5s padding each side
        // to give the aligner edge context). Shift timestamps to absolute time.
        let sampleRate: Double = 16_000
        let padSec: Double = 0.5
        var rawAligned: [AlignedWord] = []
        let t0 = Date()
        for (idx, chunk) in chunks.enumerated() {
            let clipStart = max(0, chunk.audioStart - padSec)
            let clipEnd = min(Double(audio.count) / sampleRate, chunk.audioEnd + padSec)
            let s = Int(clipStart * sampleRate)
            let e = min(Int(clipEnd * sampleRate), audio.count)
            guard s < e else { continue }
            let clip = Array(audio[s..<e])
            let chunkAligned = aligner.align(audio: clip, text: chunk.text, sampleRate: 16_000)
            // Shift to absolute time.
            for word in chunkAligned {
                rawAligned.append(AlignedWord(
                    text: word.text,
                    startTime: word.startTime + Float(clipStart),
                    endTime: word.endTime + Float(clipStart)
                ))
            }
            if (idx + 1) % 5 == 0 || idx == chunks.count - 1 {
                print(String(format: "    chunk %d/%d done", idx + 1, chunks.count))
            }
        }
        let alignSecs = Date().timeIntervalSince(t0)
        let rtf = alignSecs > 0 ? Double(audio.count) / 16_000.0 / alignSecs : 0
        print(String(format: "  Aligned %d words across %d chunks in %.2fs (RTF %.1fx)",
                     rawAligned.count, chunks.count, alignSecs, rtf))

        // Side-by-side diagnostic: first 25 GT words vs first 25 aligner words.
        print("  === Head-to-head (first 25) ===")
        for idx in 0 ..< min(25, min(gtWords.count, rawAligned.count)) {
            let gtW = gtWords[idx]
            let aW = rawAligned[idx]
            print(String(format: "    [GT %6.2fs %-16@]   [A %6.2fs %-16@]",
                         gtW.start,
                         gtW.word as NSString,
                         Double(aW.startTime),
                         aW.text as NSString))
        }

        // Apply the same minimum-duration repair the Consensus wrapper applies.
        var aligned: [AlignedWord] = rawAligned
        for idx in 0 ..< aligned.count {
            let w = aligned[idx]
            let d = Double(w.endTime) - Double(w.startTime)
            if d >= minDuration { continue }
            let desired = Double(w.startTime) + minDuration
            let ceiling: Double
            if idx + 1 < aligned.count {
                ceiling = max(Double(w.startTime), Double(aligned[idx + 1].startTime) - 0.001)
            } else {
                ceiling = desired
            }
            let newEnd = Float(min(desired, ceiling))
            aligned[idx] = AlignedWord(text: w.text, startTime: w.startTime, endTime: newEnd)
        }

        // Match aligner words to ground-truth words by text + time proximity.
        // Strategy: two pointers walking both lists. For each gt word, scan
        // aligner words within a ±searchWindow for a text match (normalized).
        // If found, record the offset; advance both pointers. Otherwise
        // advance just the gt pointer (and record unmatched).
        let searchWindow: Double = 10.0 // seconds

        var offsets: [Double] = []
        var unmatched: [String] = []
        var alignedCursor = 0

        for gtWord in gtWords {
            let normGT = normalize(gtWord.word)
            // Advance aligned cursor past anything far before gt.
            while alignedCursor < aligned.count,
                  Double(aligned[alignedCursor].startTime) < gtWord.start - searchWindow {
                alignedCursor += 1
            }

            var bestIdx: Int?
            var bestDelta = Double.greatestFiniteMagnitude
            var scan = alignedCursor
            while scan < aligned.count {
                let aStart = Double(aligned[scan].startTime)
                if aStart > gtWord.start + searchWindow { break }
                if normalize(aligned[scan].text) == normGT {
                    let delta = abs(aStart - gtWord.start)
                    if delta < bestDelta {
                        bestDelta = delta
                        bestIdx = scan
                    }
                }
                scan += 1
            }

            if let bestIdx {
                offsets.append(Double(aligned[bestIdx].startTime) - gtWord.start)
                alignedCursor = bestIdx + 1
            } else if unmatched.count < 20 {
                unmatched.append(String(format: "[%.2fs] %@", gtWord.start, gtWord.word))
            }
        }

        let absOffsets = offsets.map { abs($0) }
        let matchedCount = offsets.count
        let matchRate = gtWords.isEmpty ? 0 : Double(matchedCount) / Double(gtWords.count)

        func percentile(_ sorted: [Double], _ p: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            let idx = Int(Double(sorted.count - 1) * p)
            return sorted[max(0, min(sorted.count - 1, idx))]
        }
        let sortedAbs = absOffsets.sorted()
        let meanAbs = sortedAbs.isEmpty ? 0 : sortedAbs.reduce(0, +) / Double(sortedAbs.count)
        let median = percentile(sortedAbs, 0.5)
        let p95 = percentile(sortedAbs, 0.95)
        let maxAbs = sortedAbs.max() ?? 0
        let meanSigned = offsets.isEmpty ? 0 : offsets.reduce(0, +) / Double(offsets.count)
        let variance = offsets.isEmpty ? 0 : offsets.reduce(0) { $0 + ($1 - meanSigned) * ($1 - meanSigned) } / Double(offsets.count)
        let stddev = variance.squareRoot()

        func pctWithin(_ threshold: Double) -> Double {
            guard !sortedAbs.isEmpty else { return 0 }
            let count = sortedAbs.filter { $0 <= threshold }.count
            return 100.0 * Double(count) / Double(sortedAbs.count)
        }

        // Per-speaker turn boundary: for each segment-start in GT that starts
        // a new speaker turn (different speaker than previous segment), find
        // the first aligner word whose text matches the GT segment's first
        // word within a reasonable window, and record that offset.
        var turnOffsets: [Double] = []
        var lastSpeaker: String?
        for seg in gt.segments {
            defer { lastSpeaker = seg.speakerID }
            guard seg.speakerID != lastSpeaker, let firstGTWord = seg.words.first else { continue }
            let normFirst = normalize(firstGTWord.word)
            // Scan aligner for first word with matching text within ±5s of seg.start.
            var bestDelta = Double.greatestFiniteMagnitude
            for a in aligned {
                let aStart = Double(a.startTime)
                if abs(aStart - seg.start) > 5.0 { continue }
                if normalize(a.text) == normFirst {
                    let d = abs(aStart - seg.start)
                    if d < bestDelta { bestDelta = d }
                }
            }
            if bestDelta < .greatestFiniteMagnitude {
                turnOffsets.append(bestDelta)
            }
        }
        let turnMean = turnOffsets.isEmpty ? 0 : turnOffsets.reduce(0, +) / Double(turnOffsets.count)
        let turnMedian = percentile(turnOffsets.sorted(), 0.5)
        let turnMax = turnOffsets.max() ?? 0

        // Assemble report.
        let report = Report(
            groundTruthPath: gtPath,
            audioPath: audioPath,
            alignerModelId: alignerModelId,
            durationSec: Double(audio.count) / 16_000.0,
            groundTruthWordCount: gtWords.count,
            alignedWordCount: aligned.count,
            matchedWordCount: matchedCount,
            matchRate: matchRate,
            meanAbsOffsetSec: meanAbs,
            medianAbsOffsetSec: median,
            p95AbsOffsetSec: p95,
            maxAbsOffsetSec: maxAbs,
            stddevOffsetSec: stddev,
            meanSignedOffsetSec: meanSigned,
            percentWithin50ms: pctWithin(0.050),
            percentWithin100ms: pctWithin(0.100),
            percentWithin250ms: pctWithin(0.250),
            percentWithin500ms: pctWithin(0.500),
            percentWithin1000ms: pctWithin(1.000),
            turnBoundaryCount: turnOffsets.count,
            meanTurnBoundaryOffsetSec: turnMean,
            medianTurnBoundaryOffsetSec: turnMedian,
            maxTurnBoundaryOffsetSec: turnMax,
            alignmentElapsedSec: alignSecs,
            alignmentRTF: rtf,
            unmatchedExamples: unmatched
        )

        // Write JSON.
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(report) {
            try? data.write(to: URL(fileURLWithPath: outPath))
        }

        // Console summary.
        print("")
        print("=== Word-level start-time offset (Qwen3 aligner vs ground truth) ===")
        print(String(format: "  matched:      %d / %d  (%.1f%%)", matchedCount, gtWords.count, matchRate * 100))
        print(String(format: "  mean |Δ|:     %.3fs    median: %.3fs    p95: %.3fs    max: %.3fs",
                     meanAbs, median, p95, maxAbs))
        print(String(format: "  signed mean:  %+.3fs  (positive = aligner late)    stddev: %.3fs",
                     meanSigned, stddev))
        print(String(format: "  within  50ms: %.1f%%", pctWithin(0.050)))
        print(String(format: "  within 100ms: %.1f%%", pctWithin(0.100)))
        print(String(format: "  within 250ms: %.1f%%", pctWithin(0.250)))
        print(String(format: "  within 500ms: %.1f%%", pctWithin(0.500)))
        print(String(format: "  within    1s: %.1f%%", pctWithin(1.000)))
        print("")
        print("=== Speaker-turn boundary offset ===")
        print(String(format: "  %d turn boundaries measured", turnOffsets.count))
        print(String(format: "  mean: %.3fs    median: %.3fs    max: %.3fs", turnMean, turnMedian, turnMax))
        print("")
        if !unmatched.isEmpty {
            print("=== First unmatched GT words ===")
            for u in unmatched.prefix(10) { print("  \(u)") }
        }
        print("JSON → \(outPath)")
    }

    // MARK: - Helpers

    static func normalize(_ word: String) -> String {
        word.lowercased()
            .replacingOccurrences(of: "[^a-z0-9']", with: "", options: .regularExpression)
    }

    static func loadMono16k(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "AlignmentValidator", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not build target format"])
        }
        guard let converter = AVAudioConverter(from: file.processingFormat, to: targetFormat) else {
            throw NSError(domain: "AlignmentValidator", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Could not build converter"])
        }
        let frameCapacity = AVAudioFrameCount(
            Double(file.length) * 16_000.0 / file.processingFormat.sampleRate
        )
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else {
            throw NSError(domain: "AlignmentValidator", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Could not allocate buffer"])
        }
        var conversionError: NSError?
        let input: AVAudioConverterInputBlock = { _, status in
            let readCount: AVAudioFrameCount = 4096
            guard let readBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: readCount) else {
                status.pointee = .endOfStream; return nil
            }
            do {
                try file.read(into: readBuffer)
                if readBuffer.frameLength == 0 { status.pointee = .endOfStream; return nil }
                status.pointee = .haveData
                return readBuffer
            } catch {
                status.pointee = .endOfStream; return nil
            }
        }
        converter.convert(to: output, error: &conversionError, withInputFrom: input)
        if let conversionError { throw conversionError }
        guard let channel = output.floatChannelData else {
            throw NSError(domain: "AlignmentValidator", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "No float channel data"])
        }
        let count = Int(output.frameLength)
        return Array(UnsafeBufferPointer(start: channel[0], count: count))
    }
}
