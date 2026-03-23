import Foundation

enum TranscriptionPassKind: String, Codable, Sendable {
    case standard
    case deepReviewPrimary
    case deepReviewComparison
    case deepReviewConsensus

    var displayName: String {
        switch self {
        case .standard: return "Standard"
        case .deepReviewPrimary: return "Deep Review Primary"
        case .deepReviewComparison: return "Deep Review Comparison"
        case .deepReviewConsensus: return "Deep Review Consensus"
        }
    }
}

struct ProjectTranscriptionSettings: Codable, Sendable {
    var model: WhisperModel
    var deepReviewEngineChoice: DeepReviewEngineChoice?
    var deepReviewComparisonModel: WhisperModel?
    var minSpeakers: Int
    var maxSpeakers: Int
    var language: String
}

struct ProjectExportPreferences: Codable, Sendable {
    var selectedFormats: [ExportFormat]
    var showElapsedTime: Bool
    var showClockTime: Bool
    var recordingStartTime: Date?
    var legalPDFHeader: String
}

struct ExportRecord: Codable, Identifiable, Sendable {
    let id: UUID
    let format: ExportFormat
    let exportedAt: Date
    let destinationPath: String

    init(
        id: UUID = UUID(),
        format: ExportFormat,
        exportedAt: Date = Date(),
        destinationPath: String
    ) {
        self.id = id
        self.format = format
        self.exportedAt = exportedAt
        self.destinationPath = destinationPath
    }
}

struct QualityFlag: Codable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case lowWordConfidence
        case lowSegmentConfidence
        case lowDiarizationQuality
        case unknownSpeaker

        var displayName: String {
            switch self {
            case .lowWordConfidence: return "Low Word Confidence"
            case .lowSegmentConfidence: return "Low Segment Confidence"
            case .lowDiarizationQuality: return "Low Diarization Quality"
            case .unknownSpeaker: return "Unknown Speaker"
            }
        }
    }

    enum Severity: String, Codable, Sendable {
        case low
        case medium
        case high

        var sortRank: Int {
            switch self {
            case .high: return 0
            case .medium: return 1
            case .low: return 2
            }
        }
    }

    let id: UUID
    let segmentID: UUID
    let kind: Kind
    let severity: Severity
    let speakerID: String
    let start: TimeInterval
    let end: TimeInterval
    let snippet: String
    let observedValue: Float?
    let thresholdValue: Float?
    let message: String

    init(
        id: UUID = UUID(),
        segmentID: UUID,
        kind: Kind,
        severity: Severity,
        speakerID: String,
        start: TimeInterval,
        end: TimeInterval,
        snippet: String,
        observedValue: Float? = nil,
        thresholdValue: Float? = nil,
        message: String
    ) {
        self.id = id
        self.segmentID = segmentID
        self.kind = kind
        self.severity = severity
        self.speakerID = speakerID
        self.start = start
        self.end = end
        self.snippet = snippet
        self.observedValue = observedValue
        self.thresholdValue = thresholdValue
        self.message = message
    }
}

struct TranscriptQualitySummary: Codable, Sendable {
    var averageWordConfidence: Float?
    var averageSegmentConfidence: Float?
    var averageDiarizationQuality: Float?
    var averageLogProb: Float?
    var averageCompressionRatio: Float?
    var averageNoSpeechProbability: Float?
    var lowConfidenceWordCount: Int
    var lowConfidenceSegmentCount: Int
    var lowDiarizationSegmentCount: Int
    var unknownSpeakerSegmentCount: Int
    var riskySegments: [QualityFlag]
}

struct TranscriptionPass: Codable, Identifiable, Sendable {
    let id: UUID
    var kind: TranscriptionPassKind
    var createdAt: Date
    var engineName: String
    var modelName: String
    var diarizationEngineName: String
    var language: String
    var minSpeakers: Int?
    var maxSpeakers: Int?
    var warnings: [String]
    var result: TranscriptionResult
    var qualitySummary: TranscriptQualitySummary

    init(
        id: UUID = UUID(),
        kind: TranscriptionPassKind,
        createdAt: Date = Date(),
        engineName: String,
        modelName: String,
        diarizationEngineName: String,
        language: String,
        minSpeakers: Int?,
        maxSpeakers: Int?,
        warnings: [String] = [],
        result: TranscriptionResult,
        qualitySummary: TranscriptQualitySummary
    ) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
        self.engineName = engineName
        self.modelName = modelName
        self.diarizationEngineName = diarizationEngineName
        self.language = language
        self.minSpeakers = minSpeakers
        self.maxSpeakers = maxSpeakers
        self.warnings = warnings
        self.result = result
        self.qualitySummary = qualitySummary
    }
}

struct TranscriptionProject: Codable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var lastOpenedAt: Date?
    var audioFileName: String
    var audioDuration: TimeInterval
    var sourceAudioPath: String?
    var sourceAudioBookmark: Data?
    var transcriptionSettings: ProjectTranscriptionSettings
    var exportPreferences: ProjectExportPreferences
    var speakerMapping: SpeakerMapping
    var passes: [TranscriptionPass]
    var activePassID: UUID?
    var exportHistory: [ExportRecord]

    var activePass: TranscriptionPass? {
        guard let activePassID else { return passes.last }
        return passes.first(where: { $0.id == activePassID }) ?? passes.last
    }

    var hasTranscript: Bool {
        activePass != nil
    }

    mutating func appendPass(_ pass: TranscriptionPass) {
        passes.append(pass)
        activePassID = pass.id
        updatedAt = Date()
    }

    mutating func upsertPass(_ pass: TranscriptionPass) {
        if let index = passes.firstIndex(where: { $0.id == pass.id }) {
            passes[index] = pass
        } else {
            passes.append(pass)
        }
        activePassID = pass.id
        updatedAt = Date()
    }

    mutating func setActivePass(id: UUID) {
        guard passes.contains(where: { $0.id == id }) else { return }
        activePassID = id
        updatedAt = Date()
    }

    mutating func updateActivePass(result: @escaping (inout TranscriptionPass) -> Void) {
        guard let activePassID,
              let index = passes.firstIndex(where: { $0.id == activePassID }) else {
            return
        }
        result(&passes[index])
        updatedAt = Date()
    }
}

struct TranscriptionProjectSummary: Identifiable, Sendable {
    let id: UUID
    let name: String
    let audioFileName: String
    let createdAt: Date
    let updatedAt: Date
    let lastOpenedAt: Date?
    let hasTranscript: Bool
    let passCount: Int
    let averageWordConfidence: Float?
    let averageDiarizationQuality: Float?
    let hasConsensus: Bool
    let hasMultiplePasses: Bool
}

extension TranscriptionProject {
    var summary: TranscriptionProjectSummary {
        let qualitySummary = activePass?.qualitySummary
        return TranscriptionProjectSummary(
            id: id,
            name: name,
            audioFileName: audioFileName,
            createdAt: createdAt,
            updatedAt: updatedAt,
            lastOpenedAt: lastOpenedAt,
            hasTranscript: hasTranscript,
            passCount: passes.count,
            averageWordConfidence: qualitySummary?.averageWordConfidence,
            averageDiarizationQuality: qualitySummary?.averageDiarizationQuality,
            hasConsensus: passes.contains { $0.kind == .deepReviewConsensus },
            hasMultiplePasses: passes.count > 1
        )
    }
}
