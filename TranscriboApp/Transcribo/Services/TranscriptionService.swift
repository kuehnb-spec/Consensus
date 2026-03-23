import Foundation
import WhisperKit

/// Wraps WhisperKit for transcription with progress reporting.
actor TranscriptionService {
    private var whisperKit: WhisperKit?
    private var currentModel: String?

    /// Load a WhisperKit model, downloading if needed.
    func loadModel(
        variant: String,
        progressCallback: @escaping @Sendable (Double) -> Void
    ) async throws {
        if currentModel == variant, whisperKit != nil {
            return // Already loaded
        }

        // Step 1: Download model files with progress reporting
        let modelFolder = try await WhisperKit.download(
            variant: variant,
            progressCallback: { progress in
                let fraction = progress.fractionCompleted
                progressCallback(fraction)
            }
        )

        // Step 2: Initialize WhisperKit with the local model folder
        progressCallback(1.0)
        let kit = try await WhisperKit(
            modelFolder: modelFolder.path,
            verbose: true,
            prewarm: true,
            load: true,
            download: false
        )

        whisperKit = kit
        currentModel = variant
    }

    /// Transcribe an audio file and return segments.
    func transcribe(
        audioPath: String,
        language: String = "en",
        audioDuration: TimeInterval = 0,
        progressCallback: @escaping @Sendable (Double, String?) -> Bool
    ) async throws -> [TranscriptionSegment] {
        guard let kit = whisperKit else {
            throw TranscriboError.transcriptionFailed("Model not loaded. Call loadModel first.")
        }

        let options = DecodingOptions(
            language: language,
            wordTimestamps: true
        )

        // Estimate total 30-second windows for progress calculation
        let estimatedWindows = max(1.0, audioDuration / 30.0)

        let callback: TranscriptionCallback = { progress in
            let fraction = min(1.0, Double(progress.windowId + 1) / estimatedWindows)
            let shouldContinue = progressCallback(fraction, progress.text)
            return shouldContinue
        }

        let results = try await kit.transcribe(
            audioPath: audioPath,
            decodeOptions: options,
            callback: callback
        )

        // Convert WhisperKit results to our segment model
        var segments: [TranscriptionSegment] = []

        for result in results {
            for segment in result.segments {
                let words: [TranscriptionSegment.WordTiming]? = segment.words.map { timings in
                    timings.map { (wt: WordTiming) in
                        TranscriptionSegment.WordTiming(
                            word: wt.word,
                            start: Float(wt.start),
                            end: Float(wt.end),
                            probability: Float(wt.probability)
                        )
                    }
                }

                let cleanText = Self.stripWhisperTokens(segment.text)
                    .trimmingCharacters(in: .whitespaces)

                guard !cleanText.isEmpty else { continue }

                segments.append(TranscriptionSegment(
                    speakerID: "UNKNOWN",
                    start: TimeInterval(segment.start),
                    end: TimeInterval(segment.end),
                    text: cleanText,
                    words: words,
                    averageLogProb: segment.avgLogprob,
                    noSpeechProb: segment.noSpeechProb,
                    decodingTemperature: segment.temperature,
                    compressionRatio: segment.compressionRatio
                ))
            }
        }

        return segments
    }

    /// Strip WhisperKit special tokens like <|startoftranscript|>, <|en|>, <|0.00|>, etc.
    private static func stripWhisperTokens(_ text: String) -> String {
        text.replacingOccurrences(
            of: "<\\|[^|]*\\|>",
            with: "",
            options: .regularExpression
        )
    }
}
