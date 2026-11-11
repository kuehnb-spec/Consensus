import Foundation

struct TranscriptionSegment: Identifiable, Codable, Sendable {
    let id: UUID
    var speakerID: String
    var start: TimeInterval
    var end: TimeInterval
    var text: String
    var words: [WordTiming]?
    var averageLogProb: Float?
    var noSpeechProb: Float?
    var decodingTemperature: Float?
    var compressionRatio: Float?
    var diarizationQuality: Float?
    var diarizationOverlap: TimeInterval?
    /// Where `words[].start/end` came from. `nil` means unknown (projects
    /// saved before 2026-11-11); `.interpolated` means the engine gave only a
    /// segment span and the word times are an even split of it.
    var wordTimingSource: WordTimingSource?

    struct WordTiming: Codable, Sendable {
        let word: String
        let start: Float
        let end: Float
        /// The engine's own per-word probability, or `nil` when the engine
        /// provides none (VibeVoice, hand-edited words). Never invent one:
        /// consumers must treat `nil` as "unknown", not as certain or zero.
        let probability: Float?
    }

    enum WordTimingSource: String, Codable, Sendable {
        /// Per-word times reported by the engine itself (Parakeet, Whisper).
        case engine
        /// Linear split of the segment span; not a measurement.
        case interpolated
        /// Re-timed by a forced aligner.
        case aligned
    }

    init(
        id: UUID = UUID(),
        speakerID: String = "UNKNOWN",
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        words: [WordTiming]? = nil,
        averageLogProb: Float? = nil,
        noSpeechProb: Float? = nil,
        decodingTemperature: Float? = nil,
        compressionRatio: Float? = nil,
        diarizationQuality: Float? = nil,
        diarizationOverlap: TimeInterval? = nil,
        wordTimingSource: WordTimingSource? = nil
    ) {
        self.id = id
        self.speakerID = speakerID
        self.start = start
        self.end = end
        self.text = text
        self.words = words
        self.averageLogProb = averageLogProb
        self.noSpeechProb = noSpeechProb
        self.decodingTemperature = decodingTemperature
        self.compressionRatio = compressionRatio
        self.diarizationQuality = diarizationQuality
        self.diarizationOverlap = diarizationOverlap
        self.wordTimingSource = wordTimingSource
    }
}

extension TranscriptionSegment {
    /// Mean of the engine-reported word probabilities; `nil` when no word
    /// carries one (an unknown is not averaged in as 0 or 1).
    var averageWordConfidence: Float? {
        guard let probabilities = words?.compactMap(\.probability), !probabilities.isEmpty else { return nil }
        return probabilities.reduce(Float.zero, +) / Float(probabilities.count)
    }

    var minimumWordConfidence: Float? {
        words?.compactMap(\.probability).min()
    }
}
