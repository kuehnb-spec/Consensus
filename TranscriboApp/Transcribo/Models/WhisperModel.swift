import Foundation

enum WhisperModel: String, CaseIterable, Identifiable, Codable, Sendable {
    case tiny
    case base
    case small
    case medium
    case largeV3 = "large-v3"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tiny: return "Tiny"
        case .base: return "Base"
        case .small: return "Small"
        case .medium: return "Medium"
        case .largeV3: return "Large v3"
        }
    }

    var approximateSize: String {
        switch self {
        case .tiny: return "~75 MB"
        case .base: return "~145 MB"
        case .small: return "~500 MB"
        case .medium: return "~1.5 GB"
        case .largeV3: return "~3 GB"
        }
    }

    var description: String {
        switch self {
        case .tiny: return "Fastest, lowest accuracy"
        case .base: return "Fast, basic accuracy"
        case .small: return "Good balance of speed and accuracy"
        case .medium: return "Good accuracy, moderate speed"
        case .largeV3: return "Best accuracy, slowest"
        }
    }

    /// The WhisperKit model variant string
    var whisperKitVariant: String {
        switch self {
        case .tiny: return "openai_whisper-tiny"
        case .base: return "openai_whisper-base"
        case .small: return "openai_whisper-small"
        case .medium: return "openai_whisper-medium"
        case .largeV3: return "openai_whisper-large-v3"
        }
    }

    var recommendedDeepReviewModel: WhisperModel {
        switch self {
        case .tiny, .base:
            return .small
        case .small, .medium:
            return .largeV3
        case .largeV3:
            return .largeV3
        }
    }
}
