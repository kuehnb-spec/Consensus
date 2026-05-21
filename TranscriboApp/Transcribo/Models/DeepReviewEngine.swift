import Foundation
import FluidAudio

enum FluidAsrModelVariant: String, CaseIterable, Codable, Identifiable, Sendable {
    case parakeetV3
    case parakeetV2

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .parakeetV3:
            return "Parakeet v3"
        case .parakeetV2:
            return "Parakeet v2"
        }
    }

    var engineName: String { "FluidAudio ASR" }

    var asrModelVersion: AsrModelVersion {
        switch self {
        case .parakeetV3:
            return .v3
        case .parakeetV2:
            return .v2
        }
    }
}

enum DeepReviewEngineChoice: String, CaseIterable, Codable, Identifiable, Sendable {
    case parakeetV3
    case whisper
    case parakeetV2

    var id: String { rawValue }

    static let defaultChoice: DeepReviewEngineChoice = .whisper

    var displayName: String {
        switch self {
        case .parakeetV3:
            return "Parakeet v3"
        case .whisper:
            return "Whisper Comparison"
        case .parakeetV2:
            return "Parakeet v2"
        }
    }

    var detailText: String {
        switch self {
        case .parakeetV3:
            return "Recommended for Deep Review. Run a second pass with FluidAudio's Parakeet v3 engine."
        case .whisper:
            return "Run a second Whisper pass with a different model size."
        case .parakeetV2:
            return "Run a second pass with FluidAudio's Parakeet v2 engine."
        }
    }

    var usesWhisperModelSelection: Bool {
        self == .whisper
    }

    var fluidVariant: FluidAsrModelVariant? {
        switch self {
        case .parakeetV3:
            return .parakeetV3
        case .whisper:
            return nil
        case .parakeetV2:
            return .parakeetV2
        }
    }
}

enum VibeVoiceVariant: String, CaseIterable, Codable, Identifiable, Sendable {
    case fourBitMLX

    var id: String { rawValue }
    var displayName: String { "VibeVoice ASR (MLX 4-bit)" }
    var engineName: String { "VibeVoice" }
}

enum TranscriptionEngineDescriptor: Sendable {
    case whisper(WhisperModel)
    case fluidAsr(FluidAsrModelVariant)
    /// Microsoft VibeVoice (joint ASR + diarization). `context` is forwarded as
    /// a hotword bias — typically the project's known speaker names.
    case vibevoice(VibeVoiceVariant, context: String?)

    var engineName: String {
        switch self {
        case .whisper:
            return "WhisperKit"
        case .fluidAsr(let variant):
            return variant.engineName
        case .vibevoice(let variant, _):
            return variant.engineName
        }
    }

    var modelName: String {
        switch self {
        case .whisper(let model):
            return model.displayName
        case .fluidAsr(let variant):
            return variant.displayName
        case .vibevoice(let variant, _):
            return variant.displayName
        }
    }

    /// Engines that emit speaker labels themselves and don't need a separate
    /// diarization pass. The pipeline automatically skips diarization for these.
    var providesOwnDiarization: Bool {
        switch self {
        case .vibevoice:
            return true
        case .whisper, .fluidAsr:
            return false
        }
    }
}
