import Foundation

enum ConsensusError: LocalizedError {
    case invalidAudioFile(String)
    case modelDownloadFailed(String)
    case transcriptionFailed(String)
    case diarizationFailed(String)
    case exportFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidAudioFile(let msg): return "Invalid Audio File: \(msg)"
        case .modelDownloadFailed(let msg): return "Model Download Failed: \(msg)"
        case .transcriptionFailed(let msg): return "Transcription Failed: \(msg)"
        case .diarizationFailed(let msg): return "Diarization Failed: \(msg)"
        case .exportFailed(let msg): return "Export Failed: \(msg)"
        case .cancelled: return "Operation was cancelled."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .invalidAudioFile:
            return "Try a different audio file format (m4a, mp3, wav)."
        case .modelDownloadFailed:
            return "Check your internet connection and try again."
        case .transcriptionFailed:
            return "Try a smaller model or check that the audio file is not corrupted."
        case .diarizationFailed:
            return "Speaker identification failed. The transcript is still available without speaker labels."
        case .exportFailed:
            return "Check that you have write permission to the selected directory."
        case .cancelled:
            return nil
        }
    }
}

/// Backward compatibility alias
typealias TranscriboError = ConsensusError
