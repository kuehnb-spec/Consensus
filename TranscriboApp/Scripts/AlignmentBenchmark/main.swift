import AVFoundation
import AudioCommon
import Foundation
import Qwen3ASR

// Batch benchmark for the Word Timeline Rebuild (Slice 3 of the plan).
//
// For each audio file in the argument list:
//   1. Load and resample to 16 kHz mono.
//   2. Run Qwen3-ASR-0.6B to produce a text transcript (needed because we
//      don't have ground-truth transcripts for the TestAudio corpus).
//   3. Run Qwen3-ForcedAligner on that transcript against the audio.
//   4. Report alignment RTF, word-count, zero-duration-word count, and
//      deviation from a linear-interpolation baseline. Large deviation
//      from linear interpolation means the aligner is making real
//      audio-grounded decisions rather than silently emitting trivial
//      evenly-spaced timestamps — a sanity check we can run without ground
//      truth.
//
// Usage:
//   swift run -c release AlignmentBenchmark <audio1> [audio2] [audio3] …
//
// Output is human-readable to stdout plus a JSON summary to
// /tmp/alignment-benchmark.json for later analysis.

@main
struct AlignmentBenchmark {
    struct FileResult: Codable {
        let path: String
        let durationSec: Double
        let asrText: String
        let asrElapsedSec: Double
        let alignmentElapsedSec: Double
        let alignmentRTF: Double
        let tokenCount: Int
        let alignedWordCount: Int
        /// Zero-duration words in the raw aligner output (start == end).
        let zeroDurationWords: Int
        /// Zero-duration words after applying the 60 ms minimum-duration
        /// post-process. Should always be 0 except when the aligner placed
        /// two words at identical start times (unrepairable without moving
        /// starts, which we don't do).
        let zeroDurationWordsAfterRepair: Int
        /// Count of words modified by the minimum-duration post-process.
        let repairedWordCount: Int
        /// Mean absolute start-time deviation between Qwen3 alignment and an
        /// evenly-spaced linear-interpolation baseline (seconds). Larger values
        /// mean the aligner is responsive to audio content.
        let meanDeviationFromLinearSec: Double
        let maxDeviationFromLinearSec: Double
        /// Mean inter-word gap in the aligned output.
        let meanInterwordGapSec: Double
        let maxInterwordGapSec: Double
        /// Which aligner model the benchmark used (4-bit default, 8-bit, bf16).
        let alignerModelId: String
    }

    struct BenchmarkSummary: Codable {
        let runAt: String
        let fileCount: Int
        let results: [FileResult]
        let errors: [String]
    }

    static func main() async {
        // Ensure every print flushes immediately — without this, a crash deep
        // in MLX swallows all buffered output and leaves us without a
        // breadcrumb trail.
        setbuf(stdout, nil)
        setbuf(stderr, nil)

        // Parse optional --aligner-model flag. Defaults to the 4-bit variant.
        var alignerModelId = "aufklarer/Qwen3-ForcedAligner-0.6B-4bit"
        var fileArgs: [String] = []
        var iter = CommandLine.arguments.dropFirst().makeIterator()
        while let arg = iter.next() {
            if arg == "--aligner-model" || arg == "-a" {
                guard let value = iter.next() else {
                    FileHandle.standardError.write(Data("error: --aligner-model requires a value\n".utf8))
                    exit(2)
                }
                alignerModelId = value
            } else {
                fileArgs.append(arg)
            }
        }

        guard !fileArgs.isEmpty else {
            FileHandle.standardError.write(Data("""
            usage: swift run AlignmentBenchmark [--aligner-model <id>] <audio1> [audio2] …

              --aligner-model <id>  HuggingFace model ID for the forced aligner.
                                    Default: aufklarer/Qwen3-ForcedAligner-0.6B-4bit
                                    Alternatives:
                                      aufklarer/Qwen3-ForcedAligner-0.6B-8bit
                                      aufklarer/Qwen3-ForcedAligner-0.6B-bf16

            Outputs:
              - human-readable summary on stdout
              - JSON summary to /tmp/alignment-benchmark.json

            """.utf8))
            exit(2)
        }

        print("Loading Qwen3-ASR 0.6B (baseline) and \(alignerModelId)…")
        let modelLoadStart = Date()
        let asr: Qwen3ASRModel
        let aligner: Qwen3ForcedAligner
        do {
            asr = try await Qwen3ASRModel.fromPretrained(
                modelId: "aufklarer/Qwen3-ASR-0.6B-MLX-4bit"
            )
            aligner = try await Qwen3ForcedAligner.fromPretrained(
                modelId: alignerModelId
            )
        } catch {
            FileHandle.standardError.write(Data("[fatal] model load failed: \(error)\n".utf8))
            exit(1)
        }
        let modelLoadSecs = Date().timeIntervalSince(modelLoadStart)
        print(String(format: "  Ready in %.2fs (warm cache)\n", modelLoadSecs))

        var results: [FileResult] = []
        var errors: [String] = []

        for (idx, path) in fileArgs.enumerated() {
            print("[\(idx + 1)/\(fileArgs.count)] \(URL(fileURLWithPath: path).lastPathComponent)")
            do {
                let audio = try loadMono16k(url: URL(fileURLWithPath: path))
                let duration = Double(audio.count) / 16_000.0
                print(String(format: "  loaded %d samples (%.2fs)", audio.count, duration))

                // 1. ASR baseline
                let asrStart = Date()
                let text = asr.transcribe(audio: audio, sampleRate: 16_000, language: nil)
                let asrSecs = Date().timeIntervalSince(asrStart)
                let tokenCount = text.split(whereSeparator: { $0.isWhitespace }).count
                print(String(format: "  ASR: %d tokens in %.2fs (RTF %.1fx)",
                             tokenCount, asrSecs, asrSecs > 0 ? duration / asrSecs : 0))

                // 2. Forced alignment
                let alignStart = Date()
                let aligned: [AudioCommon.AlignedWord] = aligner.align(
                    audio: audio, text: text, sampleRate: 16_000
                )
                let alignSecs = Date().timeIntervalSince(alignStart)
                let rtf = alignSecs > 0 ? duration / alignSecs : 0
                print(String(format: "  Align: %d words in %.2fs (RTF %.1fx)",
                             aligned.count, alignSecs, rtf))

                // 3. Metrics — measure raw aligner output first.
                let zeroDur = aligned.filter { $0.endTime <= $0.startTime + 1e-4 }.count

                // Apply the same repair the Consensus wrapper applies in
                // Qwen3ForcedAlignmentService.align — enforce a 60 ms minimum
                // word duration, clipped by the next word's start. Duplicated
                // here because this executable target doesn't link the main
                // Consensus target. Keep in sync with
                // AlignedWordTimingPostprocess.enforceMinimumDuration.
                let minDuration: Double = 0.060
                var repairedStarts = [Double](repeating: 0, count: aligned.count)
                var repairedEnds = [Double](repeating: 0, count: aligned.count)
                var repairedCount = 0
                for i in 0 ..< aligned.count {
                    let w = aligned[i]
                    let start = Double(w.startTime)
                    let rawEnd = Double(w.endTime)
                    if rawEnd - start >= minDuration {
                        repairedStarts[i] = start
                        repairedEnds[i] = rawEnd
                        continue
                    }
                    let desired = start + minDuration
                    let ceiling: Double
                    if i + 1 < aligned.count {
                        ceiling = max(start, Double(aligned[i + 1].startTime) - 0.001)
                    } else {
                        ceiling = desired
                    }
                    let clamped = min(desired, ceiling)
                    repairedStarts[i] = start
                    repairedEnds[i] = clamped
                    repairedCount += 1
                }
                let zeroDurAfterRepair = (0 ..< aligned.count).filter {
                    repairedEnds[$0] <= repairedStarts[$0] + 1e-4
                }.count

                let meanDevLinear: Double
                let maxDevLinear: Double
                if aligned.count > 1 {
                    var sum = 0.0
                    var maxVal = 0.0
                    let spacing = duration / Double(aligned.count)
                    for (i, word) in aligned.enumerated() {
                        let linearStart = Double(i) * spacing
                        let dev = abs(Double(word.startTime) - linearStart)
                        sum += dev
                        if dev > maxVal { maxVal = dev }
                    }
                    meanDevLinear = sum / Double(aligned.count)
                    maxDevLinear = maxVal
                } else {
                    meanDevLinear = 0
                    maxDevLinear = 0
                }

                var gaps: [Double] = []
                for i in 1 ..< aligned.count {
                    let gap = Double(aligned[i].startTime) - Double(aligned[i - 1].endTime)
                    if gap >= 0 { gaps.append(gap) }
                }
                let meanGap = gaps.isEmpty ? 0 : gaps.reduce(0, +) / Double(gaps.count)
                let maxGap = gaps.max() ?? 0

                print(String(format: "  zero-duration: raw %d → repaired %d (fixed %d)  ·  mean dev from linear: %.2fs  ·  max dev: %.2fs",
                             zeroDur, zeroDurAfterRepair, repairedCount, meanDevLinear, maxDevLinear))
                print(String(format: "  mean gap: %.2fs  ·  max gap: %.2fs",
                             meanGap, maxGap))
                print("")

                results.append(FileResult(
                    path: path,
                    durationSec: duration,
                    asrText: text,
                    asrElapsedSec: asrSecs,
                    alignmentElapsedSec: alignSecs,
                    alignmentRTF: rtf,
                    tokenCount: tokenCount,
                    alignedWordCount: aligned.count,
                    zeroDurationWords: zeroDur,
                    zeroDurationWordsAfterRepair: zeroDurAfterRepair,
                    repairedWordCount: repairedCount,
                    meanDeviationFromLinearSec: meanDevLinear,
                    maxDeviationFromLinearSec: maxDevLinear,
                    meanInterwordGapSec: meanGap,
                    maxInterwordGapSec: maxGap,
                    alignerModelId: alignerModelId
                ))
            } catch {
                let msg = "[\(URL(fileURLWithPath: path).lastPathComponent)] \(error)"
                print("  ERROR: \(msg)")
                errors.append(msg)
            }
        }

        // Aggregate. Note: using `%@` with explicit NSString cast rather than
        // `%s` — Swift's `String(format:)` treats `%s` as a C string pointer,
        // which crashes when fed a Swift String.
        print("=== Benchmark summary ===")
        print("Aligner: \(alignerModelId)")
        print(String(
            format: "%-40@ %8@ %8@ %7@ %7@ %11@ %11@ %10@",
            "file" as NSString,
            "dur" as NSString,
            "align" as NSString,
            "RTF" as NSString,
            "words" as NSString,
            "zero raw" as NSString,
            "zero rep" as NSString,
            "devLin" as NSString
        ))
        for r in results {
            let name = URL(fileURLWithPath: r.path).lastPathComponent
            let shortName = name.count > 39 ? String(name.prefix(36)) + "…" : name
            let rawPct = r.alignedWordCount > 0
                ? Int(100.0 * Double(r.zeroDurationWords) / Double(r.alignedWordCount))
                : 0
            let repPct = r.alignedWordCount > 0
                ? Int(100.0 * Double(r.zeroDurationWordsAfterRepair) / Double(r.alignedWordCount))
                : 0
            print(String(
                format: "%-40@ %7.1fs %7.2fs %6.1fx %7d %6d (%2d%%) %6d (%2d%%) %9.2fs",
                shortName as NSString,
                r.durationSec,
                r.alignmentElapsedSec,
                r.alignmentRTF,
                r.alignedWordCount,
                r.zeroDurationWords,
                rawPct,
                r.zeroDurationWordsAfterRepair,
                repPct,
                r.meanDeviationFromLinearSec
            ))
        }

        if !errors.isEmpty {
            print("")
            print("Errors:")
            for e in errors { print("  - \(e)") }
        }

        // Write JSON
        let summary = BenchmarkSummary(
            runAt: ISO8601DateFormatter().string(from: Date()),
            fileCount: fileArgs.count,
            results: results,
            errors: errors
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(summary) {
            let outURL = URL(fileURLWithPath: "/tmp/alignment-benchmark.json")
            try? data.write(to: outURL)
            print("")
            print("JSON summary → \(outURL.path)")
        }
    }

    // MARK: - Audio loader (copy from SmokeAlignment for self-containment)

    static func loadMono16k(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "AlignmentBenchmark", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not build target format"])
        }
        guard let converter = AVAudioConverter(from: file.processingFormat, to: targetFormat) else {
            throw NSError(domain: "AlignmentBenchmark", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Could not build audio converter"])
        }

        let frameCapacity = AVAudioFrameCount(
            Double(file.length) * 16_000.0 / file.processingFormat.sampleRate
        )
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else {
            throw NSError(domain: "AlignmentBenchmark", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Could not allocate PCM buffer"])
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
        if let conversionError { throw conversionError }

        guard let channel = output.floatChannelData else {
            throw NSError(domain: "AlignmentBenchmark", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "No float channel data"])
        }
        let count = Int(output.frameLength)
        return Array(UnsafeBufferPointer(start: channel[0], count: count))
    }
}
