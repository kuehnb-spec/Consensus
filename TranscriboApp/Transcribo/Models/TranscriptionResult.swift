import Foundation

struct TranscriptionResult: Codable, Sendable {
    let audioPath: String
    let audioFileName: String
    let duration: TimeInterval
    var segments: [TranscriptionSegment]

    var detectedSpeakers: [String] {
        Array(Set(segments.map(\.speakerID))).sorted()
    }

    var speakerCount: Int { detectedSpeakers.count }
    var allWords: [TranscriptionSegment.WordTiming] {
        segments.compactMap(\.words).flatMap { $0 }
    }

    init(audioPath: String, duration: TimeInterval, segments: [TranscriptionSegment]) {
        self.audioPath = audioPath
        self.audioFileName = URL(fileURLWithPath: audioPath).deletingPathExtension().lastPathComponent
        self.duration = duration
        self.segments = segments
    }
}
