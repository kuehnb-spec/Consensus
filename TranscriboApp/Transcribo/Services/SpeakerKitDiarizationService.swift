import AVFoundation
import Foundation
import SpeakerKit

/// Wraps Argmax SpeakerKit (pyannote v4 on CoreML) for high-quality speaker diarization.
/// SpeakerKit uses newer models than FluidAudio and generally produces better results.
actor SpeakerKitDiarizationService {
    private var speakerKit: SpeakerKit?

    /// Load SpeakerKit models (downloads from HuggingFace on first use).
    func prepareModels(
        progressCallback: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let config = PyannoteConfig()
        speakerKit = try await SpeakerKit(config)
    }

    /// Run speaker diarization on an audio file using SpeakerKit.
    func diarize(
        audioURL: URL,
        numberOfSpeakers: Int? = nil,
        clusterDistanceThreshold: Float? = nil,
        progressCallback: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [DiarizationSegment] {
        // Load models if not yet loaded
        if speakerKit == nil {
            try await prepareModels(progressCallback: progressCallback)
        }

        guard let speakerKit else {
            throw ConsensusError.diarizationFailed("SpeakerKit models not loaded.")
        }

        // Load audio as 16kHz mono PCM float array
        let audioArray = try await loadAudioAsPCM(url: audioURL)

        // Configure diarization options
        var options = PyannoteDiarizationOptions()
        if let numberOfSpeakers {
            options.numberOfSpeakers = numberOfSpeakers
        }
        if let clusterDistanceThreshold {
            options.clusterDistanceThreshold = clusterDistanceThreshold
        }

        // Run diarization
        let result = try await speakerKit.diarize(
            audioArray: audioArray,
            options: options,
            progressCallback: { progress in
                progressCallback?(progress.fractionCompleted)
            }
        )

        // Convert SpeakerSegments to our DiarizationSegment type
        return result.segments.compactMap { segment -> DiarizationSegment? in
            guard let speakerID = segment.speaker.speakerId else { return nil }

            return DiarizationSegment(
                speakerID: "SPEAKER_\(speakerID)",
                start: TimeInterval(segment.startTime),
                end: TimeInterval(segment.endTime),
                qualityScore: 1.0  // SpeakerKit doesn't expose per-segment quality
            )
        }
    }

    /// Run multiple diarization passes with different clustering thresholds.
    func diarizeMultiple(
        audioURL: URL,
        numberOfSpeakers: Int? = nil,
        thresholds: [Float] = [0.3, 0.5, 0.7],
        progressCallback: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> [(threshold: Float, segments: [DiarizationSegment])] {
        var results: [(threshold: Float, segments: [DiarizationSegment])] = []

        for (index, threshold) in thresholds.enumerated() {
            progressCallback?(index + 1, thresholds.count)

            let segments = try await diarize(
                audioURL: audioURL,
                numberOfSpeakers: numberOfSpeakers,
                clusterDistanceThreshold: threshold
            )

            results.append((threshold: threshold, segments: segments))
        }

        return results
    }

    func unload() async {
        if let speakerKit {
            await speakerKit.unloadModels()
        }
        speakerKit = nil
    }

    // MARK: - Private

    /// Load audio file as 16kHz mono PCM float array (SpeakerKit's expected input format).
    private func loadAudioAsPCM(url: URL) async throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            throw ConsensusError.diarizationFailed("Could not create 16kHz mono audio format.")
        }

        guard let converter = AVAudioConverter(from: file.processingFormat, to: format) else {
            throw ConsensusError.diarizationFailed("Could not create audio converter to 16kHz mono.")
        }

        let frameCount = AVAudioFrameCount(
            Double(file.length) * 16000.0 / file.processingFormat.sampleRate
        )

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw ConsensusError.diarizationFailed("Could not allocate audio buffer.")
        }

        var conversionError: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            let readFrameCount: AVAudioFrameCount = 4096
            guard let readBuffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: readFrameCount
            ) else {
                outStatus.pointee = .endOfStream
                return nil
            }

            do {
                try file.read(into: readBuffer)
                if readBuffer.frameLength == 0 {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return readBuffer
            } catch {
                outStatus.pointee = .endOfStream
                return nil
            }
        }

        converter.convert(to: outputBuffer, error: &conversionError, withInputFrom: inputBlock)

        if let conversionError {
            throw ConsensusError.diarizationFailed("Audio conversion failed: \(conversionError.localizedDescription)")
        }

        guard let channelData = outputBuffer.floatChannelData else {
            throw ConsensusError.diarizationFailed("No audio channel data available.")
        }

        let count = Int(outputBuffer.frameLength)
        return Array(UnsafeBufferPointer(start: channelData[0], count: count))
    }
}
