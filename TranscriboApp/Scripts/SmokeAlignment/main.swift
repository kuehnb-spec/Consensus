import AVFoundation
import AudioCommon
import Foundation
import Qwen3ASR

// Smoke harness for Slice 2 of the Word Timeline Rebuild.
//
// Exercises the exact Qwen3ForcedAligner API path that
// `Transcribo/Services/Qwen3ForcedAlignmentService.swift` uses, from a
// standalone executable so we don't need to launch the SwiftUI app.
//
// Usage:
//   swift run SmokeAlignment <audio-file> [reference text]
//
// If reference text is omitted, the harness prints a warning and expects the
// caller to pass the transcript explicitly — unlike the full ASR+Align path,
// this tool only tests the alignment step.

@main
struct SmokeAlignment {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            FileHandle.standardError.write(Data("""
            usage: swift run SmokeAlignment <audio-file> [reference text]
              If reference text is omitted, a default phrase is used.
            """.utf8))
            exit(2)
        }

        let audioPath = args[1]
        let refText: String
        if args.count >= 3 {
            refText = args[2]
        } else {
            refText = "Testing, testing. This is Brant just testing, and this is somebody else speaking, testing, testing, and this is back to Brant, and this is somebody else."
            print("[info] no reference text provided; using default phrase")
        }

        let url = URL(fileURLWithPath: audioPath)

        do {
            print("[1/3] Loading audio: \(audioPath)")
            let samples = try loadMono16k(url: url)
            let duration = Double(samples.count) / 16_000.0
            print("      -> \(samples.count) samples, \(String(format: "%.2f", duration))s")

            print("[2/3] Loading Qwen3-ForcedAligner (first run downloads ~500MB)")
            let start = Date()
            let aligner = try await Qwen3ForcedAligner.fromPretrained(
                progressHandler: { progress, phase in
                    let pct = Int(progress * 100)
                    print("      [\(pct)%] \(phase)")
                }
            )
            let modelLoadSecs = Date().timeIntervalSince(start)
            print("      -> ready in \(String(format: "%.2f", modelLoadSecs))s")

            print("[3/3] Aligning \(refText.split(whereSeparator: { $0.isWhitespace }).count) text tokens against audio")
            let alignStart = Date()
            let aligned: [AlignedWord] = aligner.align(
                audio: samples,
                text: refText,
                sampleRate: 16_000
            )
            let alignSecs = Date().timeIntervalSince(alignStart)

            // Map into the same shape our `Qwen3ForcedAlignmentService.align` returns,
            // verifying the mapping code works against the real types.
            let mapped = aligned.compactMap { word -> (String, Double, Double)? in
                let trimmed = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                let s = TimeInterval(word.startTime)
                let e = TimeInterval(max(word.endTime, word.startTime))
                return (trimmed, s, e)
            }

            let rtf = alignSecs > 0 ? duration / alignSecs : 0
            print("")
            print("=== Alignment result ===")
            print("\(mapped.count) aligned words, alignment took \(String(format: "%.3f", alignSecs))s  (RTF ≈ \(String(format: "%.1fx", rtf)))")

            for (text, s, e) in mapped {
                print(String(format: "  [%6.2fs - %6.2fs] %@", s, e, text))
            }

            let unmatched = max(0, refText.split(whereSeparator: { $0.isWhitespace }).count - mapped.count)
            print("")
            print("=== Summary ===")
            print("Reference tokens:        \(refText.split(whereSeparator: { $0.isWhitespace }).count)")
            print("Aligner output words:    \(aligned.count)")
            print("Non-empty after mapping: \(mapped.count)")
            print("Apparent unmatched:      \(unmatched)")
            print("Audio duration:          \(String(format: "%.2f", duration))s")
            print("Alignment time:          \(String(format: "%.3f", alignSecs))s")
            print("RTF:                     \(String(format: "%.1fx", rtf)) (alignment only)")
            print("Model load time:         \(String(format: "%.2f", modelLoadSecs))s (incl. any fresh download)")
        } catch {
            FileHandle.standardError.write(Data("[error] \(error)\n".utf8))
            exit(1)
        }
    }

    /// 16 kHz mono Float32 PCM loader — matches `ForcedAlignmentAudioLoader.loadMono16k`
    /// in the main Consensus target. Duplicated here so this smoke harness can
    /// build as a standalone executable without pulling in Consensus sources.
    static func loadMono16k(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "SmokeAlignment", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not build target format"])
        }
        guard let converter = AVAudioConverter(from: file.processingFormat, to: targetFormat) else {
            throw NSError(domain: "SmokeAlignment", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not build audio converter"])
        }

        let frameCapacity = AVAudioFrameCount(
            Double(file.length) * 16_000.0 / file.processingFormat.sampleRate
        )
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else {
            throw NSError(domain: "SmokeAlignment", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not allocate PCM buffer"])
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
            throw conversionError
        }

        guard let channel = output.floatChannelData else {
            throw NSError(domain: "SmokeAlignment", code: 4, userInfo: [NSLocalizedDescriptionKey: "No float channel data"])
        }
        let count = Int(output.frameLength)
        return Array(UnsafeBufferPointer(start: channel[0], count: count))
    }
}
