import FluidAudio
import Foundation

/// Wraps FluidAudio's offline ASR models so Deep Review can run a second local engine.
actor FluidAsrTranscriptionService {
    private var managers: [FluidAsrModelVariant: AsrManager] = [:]

    func prepareModel(
        variant: FluidAsrModelVariant,
        progressCallback: @escaping @Sendable (Double) -> Void
    ) async throws {
        if managers[variant] != nil {
            progressCallback(1.0)
            return
        }

        let models = try await AsrModels.downloadAndLoad(
            version: variant.asrModelVersion,
            progressHandler: { progress in
                progressCallback(progress.fractionCompleted)
            }
        )

        let manager = AsrManager()
        try await manager.initialize(models: models)
        managers[variant] = manager
        progressCallback(1.0)
    }

    func transcribe(
        audioURL: URL,
        variant: FluidAsrModelVariant,
        progressCallback: @escaping @Sendable (Double) -> Void
    ) async throws -> [TranscriptionSegment] {
        let manager = try await preparedManager(
            variant: variant,
            progressCallback: progressCallback
        )

        progressCallback(0.05)
        let result = try await manager.transcribe(audioURL)
        progressCallback(1.0)

        return Self.buildSegments(from: result)
    }

    private func preparedManager(
        variant: FluidAsrModelVariant,
        progressCallback: @escaping @Sendable (Double) -> Void
    ) async throws -> AsrManager {
        if let manager = managers[variant] {
            return manager
        }

        try await prepareModel(variant: variant, progressCallback: progressCallback)

        guard let manager = managers[variant] else {
            throw TranscriboError.modelDownloadFailed("The \(variant.displayName) models could not be initialized.")
        }

        return manager
    }

    private static func buildSegments(from result: ASRResult) -> [TranscriptionSegment] {
        let wordTimings = buildWordTimings(from: result.tokenTimings ?? [])

        guard !wordTimings.isEmpty else {
            let fallbackText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fallbackText.isEmpty else { return [] }

            return [
                TranscriptionSegment(
                    speakerID: "UNKNOWN",
                    start: 0,
                    end: result.duration,
                    text: fallbackText,
                    words: nil
                )
            ]
        }

        var segments: [TranscriptionSegment] = []
        var currentWords: [WordTiming] = []

        func flushCurrentWords() {
            guard let firstWord = currentWords.first, let lastWord = currentWords.last else { return }

            let segmentWords = currentWords.map {
                TranscriptionSegment.WordTiming(
                    word: $0.word,
                    start: Float($0.start),
                    end: Float($0.end),
                    probability: $0.confidence
                )
            }

            let joinedText = normalizeSegmentText(currentWords.map(\.word).joined(separator: " "))

            segments.append(
                TranscriptionSegment(
                    speakerID: "UNKNOWN",
                    start: firstWord.start,
                    end: lastWord.end,
                    text: joinedText,
                    words: segmentWords
                )
            )

            currentWords.removeAll(keepingCapacity: true)
        }

        for word in wordTimings {
            if shouldSplit(beforeAppending: word, currentWords: currentWords) {
                flushCurrentWords()
            }

            currentWords.append(word)
        }

        flushCurrentWords()
        return segments
    }

    private static func shouldSplit(
        beforeAppending nextWord: WordTiming,
        currentWords: [WordTiming]
    ) -> Bool {
        guard let lastWord = currentWords.last,
              let firstWord = currentWords.first else {
            return false
        }

        let gap = nextWord.start - lastWord.end
        let currentDuration = nextWord.end - firstWord.start
        let sentenceEnded = lastWord.word.last.map { ".!?".contains($0) } ?? false

        if gap > 1.1 {
            return true
        }

        if sentenceEnded && (gap > 0.2 || currentDuration >= 3.5 || currentWords.count >= 10) {
            return true
        }

        if currentDuration > 8.0 {
            return true
        }

        return currentDuration > 5.5 && currentWords.count >= 14
    }

    private static func buildWordTimings(from tokenTimings: [TokenTiming]) -> [WordTiming] {
        var words: [WordTiming] = []
        var currentWord = ""
        var currentStart: TimeInterval = 0
        var currentEnd: TimeInterval = 0
        var currentConfidences: [Float] = []

        func flushWord() {
            let trimmedWord = currentWord.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedWord.isEmpty else {
                currentWord = ""
                currentConfidences = []
                return
            }

            let confidence = currentConfidences.isEmpty
                ? 0.5
                : currentConfidences.reduce(Float.zero, +) / Float(currentConfidences.count)

            words.append(
                WordTiming(
                    word: trimmedWord,
                    start: currentStart,
                    end: currentEnd,
                    confidence: confidence
                )
            )

            currentWord = ""
            currentConfidences = []
        }

        for tokenTiming in tokenTimings {
            let token = tokenTiming.token
            guard !token.isEmpty, token != "<blank>", token != "<pad>" else { continue }

            let startsNewWord = currentWord.isEmpty || token.hasPrefix(" ") || token.hasPrefix("▁")
            let normalizedToken = token
                .replacingOccurrences(of: "▁", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !normalizedToken.isEmpty else { continue }

            if startsNewWord && !currentWord.isEmpty {
                flushWord()
            }

            if currentWord.isEmpty {
                currentWord = normalizedToken
                currentStart = tokenTiming.startTime
            } else {
                currentWord += normalizedToken
            }

            currentEnd = tokenTiming.endTime
            currentConfidences.append(tokenTiming.confidence)
        }

        flushWord()
        return words
    }

    private static func normalizeSegmentText(_ text: String) -> String {
        text
            .replacingOccurrences(of: " ,", with: ",")
            .replacingOccurrences(of: " .", with: ".")
            .replacingOccurrences(of: " !", with: "!")
            .replacingOccurrences(of: " ?", with: "?")
            .replacingOccurrences(of: " ;", with: ";")
            .replacingOccurrences(of: " :", with: ":")
            .replacingOccurrences(of: " n't", with: "n't")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct WordTiming: Sendable {
    let word: String
    let start: TimeInterval
    let end: TimeInterval
    let confidence: Float
}
