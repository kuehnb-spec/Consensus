import AVFoundation
import Foundation

enum AudioFileValidator {
    static let supportedExtensions: Set<String> = [
        "m4a", "mp3", "wav", "aiff", "aif", "flac", "ogg", "wma", "aac", "mp4", "mov"
    ]

    struct AudioInfo: Sendable {
        let url: URL
        let duration: TimeInterval
        let fileName: String
    }

    static func validate(url: URL) async throws -> AudioInfo {
        let asset = AVAsset(url: url)

        let duration: CMTime
        do {
            duration = try await asset.load(.duration)
        } catch {
            throw TranscriboError.invalidAudioFile("Could not read audio file: \(error.localizedDescription)")
        }

        let seconds = duration.seconds
        guard seconds > 0, seconds.isFinite else {
            throw TranscriboError.invalidAudioFile("Audio file appears to be empty or unreadable.")
        }

        let fileName = url.deletingPathExtension().lastPathComponent

        return AudioInfo(url: url, duration: seconds, fileName: fileName)
    }

    static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }
}
