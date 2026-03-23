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

    struct WordTiming: Codable, Sendable {
        let word: String
        let start: Float
        let end: Float
        let probability: Float
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
        diarizationOverlap: TimeInterval? = nil
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
    }
}

extension TranscriptionSegment {
    var averageWordConfidence: Float? {
        guard let words, !words.isEmpty else { return nil }
        let total = words.reduce(Float.zero) { $0 + $1.probability }
        return total / Float(words.count)
    }

    var minimumWordConfidence: Float? {
        words?.map(\.probability).min()
    }
}
