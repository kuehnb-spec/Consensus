import Foundation

enum DemoProjectFactory {
    static let projectID = UUID(uuidString: "7C5D3D52-AD3E-4A50-A210-0CB957E91E41")!

    static func makeProject(now: Date = Date()) -> TranscriptionProject {
        let standardResult = TranscriptionResult(
            audioPath: "/BuiltIn/Built-in Demo.m4a",
            duration: 42,
            segments: standardSegments()
        )
        let comparisonResult = TranscriptionResult(
            audioPath: "/BuiltIn/Built-in Demo.m4a",
            duration: 42,
            segments: comparisonSegments()
        )
        let consensusResult = TranscriptionResult(
            audioPath: "/BuiltIn/Built-in Demo.m4a",
            duration: 42,
            segments: consensusSegments()
        )

        let standardPass = TranscriptionPass(
            id: UUID(uuidString: "A8144D49-83E4-493D-A1A4-6D1EB08A725F")!,
            kind: .standard,
            createdAt: now.addingTimeInterval(-180),
            engineName: "WhisperKit",
            modelName: "Small",
            diarizationEngineName: "FluidAudio",
            language: "en",
            minSpeakers: 2,
            maxSpeakers: 2,
            warnings: [],
            result: standardResult,
            qualitySummary: QualityAnalysisService.analyze(result: standardResult)
        )

        let comparisonPass = TranscriptionPass(
            id: UUID(uuidString: "E3D5B3A3-B41E-4E12-90A8-D8A31346D37C")!,
            kind: .deepReviewComparison,
            createdAt: now.addingTimeInterval(-120),
            engineName: "FluidAudio ASR",
            modelName: "Parakeet v3",
            diarizationEngineName: "FluidAudio",
            language: "en",
            minSpeakers: 2,
            maxSpeakers: 2,
            warnings: [],
            result: comparisonResult,
            qualitySummary: QualityAnalysisService.analyze(result: comparisonResult)
        )

        let consensusPass = TranscriptionPass(
            id: UUID(uuidString: "BD6154C4-2A87-4E64-A6CC-774D7EDC716A")!,
            kind: .deepReviewConsensus,
            createdAt: now.addingTimeInterval(-60),
            engineName: "Manual Reconciliation",
            modelName: "Consensus",
            diarizationEngineName: "Merged",
            language: "en",
            minSpeakers: 2,
            maxSpeakers: 2,
            warnings: [],
            result: consensusResult,
            qualitySummary: QualityAnalysisService.analyze(result: consensusResult)
        )

        var mapping = SpeakerMapping()
        mapping.rename("S1", to: "Host")
        mapping.rename("S2", to: "Reviewer")

        return TranscriptionProject(
            id: projectID,
            name: "Built-in Demo Project",
            createdAt: now.addingTimeInterval(-240),
            updatedAt: now,
            lastOpenedAt: now,
            audioFileName: "Built-in Demo",
            audioDuration: 42,
            sourceAudioPath: nil,
            sourceAudioBookmark: nil,
            transcriptionSettings: ProjectTranscriptionSettings(
                model: .small,
                deepReviewEngineChoice: .parakeetV3,
                deepReviewComparisonModel: .largeV3,
                minSpeakers: 2,
                maxSpeakers: 2,
                language: "en"
            ),
            exportPreferences: ProjectExportPreferences(
                selectedFormats: [.legalPDF, .md, .json],
                showElapsedTime: true,
                showClockTime: false,
                recordingStartTime: nil,
                legalPDFHeader: "Built-in Demo Project"
            ),
            speakerMapping: mapping,
            passes: [standardPass, comparisonPass, consensusPass],
            activePassID: consensusPass.id,
            exportHistory: []
        )
    }

    private static func standardSegments() -> [TranscriptionSegment] {
        [
            segment(
                speakerID: "S1",
                start: 0,
                end: 8,
                text: "Welcome to the demo project for Consensus.",
                confidence: 0.97,
                diarizationQuality: 0.97
            ),
            segment(
                speakerID: "S2",
                start: 8,
                end: 18,
                text: "This sample shows how saved transcripts behave in the app.",
                confidence: 0.95,
                diarizationQuality: 0.96
            ),
            segment(
                speakerID: "S1",
                start: 18,
                end: 24,
                text: "The standard pass hears counselor's table,",
                confidence: 0.79,
                diarizationQuality: 0.95
            ),
            segment(
                speakerID: "S1",
                start: 24,
                end: 30,
                text: "and the review pass hears councillors' table.",
                confidence: 0.84,
                diarizationQuality: 0.94
            ),
            segment(
                speakerID: "S2",
                start: 30,
                end: 36,
                text: "Sometimes the disagreement is only punctuation not the actual words",
                confidence: 0.86,
                diarizationQuality: 0.95
            ),
            segment(
                speakerID: "S1",
                start: 36,
                end: 42,
                text: "That is why the final column keeps the transcript in full context.",
                confidence: 0.92,
                diarizationQuality: 0.96
            ),
        ]
    }

    private static func comparisonSegments() -> [TranscriptionSegment] {
        [
            segment(
                speakerID: "S1",
                start: 0,
                end: 8,
                text: "Welcome to the demo project for Consensus.",
                confidence: 0.99,
                diarizationQuality: 0.97
            ),
            segment(
                speakerID: "S2",
                start: 8,
                end: 18,
                text: "This sample shows how saved transcripts behave in the app.",
                confidence: 0.98,
                diarizationQuality: 0.96
            ),
            segment(
                speakerID: "S1",
                start: 18,
                end: 30,
                text: "The standard pass hears counselor's table, and the review pass hears councillors' table.",
                confidence: 0.96,
                diarizationQuality: 0.95
            ),
            segment(
                speakerID: "S2",
                start: 30,
                end: 42,
                text: "Sometimes the disagreement is only punctuation, not the actual words. That is why the final column keeps the transcript in full context.",
                confidence: 0.97,
                diarizationQuality: 0.96
            ),
        ]
    }

    private static func consensusSegments() -> [TranscriptionSegment] {
        [
            segment(
                speakerID: "S1",
                start: 0,
                end: 8,
                text: "Welcome to the demo project for Consensus.",
                confidence: 0.99,
                diarizationQuality: 0.97
            ),
            segment(
                speakerID: "S2",
                start: 8,
                end: 18,
                text: "This sample shows how saved transcripts behave in the app.",
                confidence: 0.98,
                diarizationQuality: 0.96
            ),
            segment(
                speakerID: "S1",
                start: 18,
                end: 30,
                text: "The standard pass hears counselor's table, and the review pass hears councillors' table.",
                confidence: 0.96,
                diarizationQuality: 0.95
            ),
            segment(
                speakerID: "S2",
                start: 30,
                end: 42,
                text: "Sometimes the disagreement is only punctuation, not the actual words. That is why the final column keeps the transcript in full context.",
                confidence: 0.97,
                diarizationQuality: 0.96
            ),
        ]
    }

    private static func segment(
        speakerID: String,
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        confidence: Float,
        diarizationQuality: Float
    ) -> TranscriptionSegment {
        TranscriptionSegment(
            speakerID: speakerID,
            start: start,
            end: end,
            text: text,
            words: makeWords(text: text, start: start, end: end, probability: confidence),
            averageLogProb: confidenceLogProb(confidence),
            noSpeechProb: max(0.01, 1 - confidence) * 0.1,
            decodingTemperature: 0,
            compressionRatio: 1.08,
            diarizationQuality: diarizationQuality,
            diarizationOverlap: 0
        )
    }

    private static func makeWords(
        text: String,
        start: TimeInterval,
        end: TimeInterval,
        probability: Float
    ) -> [TranscriptionSegment.WordTiming] {
        let tokens = text
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)

        guard !tokens.isEmpty else { return [] }

        let duration = max(0.1, end - start)
        let step = duration / Double(tokens.count)

        return tokens.enumerated().map { index, token in
            let tokenStart = start + (Double(index) * step)
            let tokenEnd = min(end, tokenStart + step)
            return TranscriptionSegment.WordTiming(
                word: token,
                start: Float(tokenStart),
                end: Float(tokenEnd),
                probability: probability
            )
        }
    }

    private static func confidenceLogProb(_ confidence: Float) -> Float {
        let clamped = max(0.01, min(confidence, 0.999))
        return log(clamped)
    }
}
