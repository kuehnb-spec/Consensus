import Foundation

// The two artifacts the CLI writes. Schema and rendering rules are fixed by
// 10-consensus-spec.md §Output contract — downstream (PADD) parses these, so
// changes here are breaking changes and need a `schema_version` bump.

extension ConsensusCLI {

    struct TranscriptDocument {
        let probe: AudioProbe
        let pass: TranscriptPass
        let options: TranscribeOptions
        let processingSeconds: TimeInterval

        // MARK: - JSON (authoritative artifact)

        func jsonData() throws -> Data {
            var root: [String: Any] = [:]
            root["schema_version"] = ConsensusCLI.schemaVersion

            var source: [String: Any] = [
                "filename": probe.url.lastPathComponent,
                "sha256": probe.sha256,
                "duration_seconds": rounded(probe.duration, 1),
            ]
            source["file_created"] = probe.createdAt.map(Self.iso8601.string(from:)) ?? NSNull()
            root["source"] = source

            var config: [String: Any] = [
                "speakers_hint": options.speakers ?? NSNull(),
                "language": options.language,
            ]
            if let hints = options.hints { config["stt_hints"] = hints }

            root["provenance"] = [
                "app_version": ConsensusCLI.appVersion,
                "engines": engineDescriptors(),
                "config": config,
                "processed_at": Self.iso8601.string(from: Date()),
                "processing_seconds": rounded(processingSeconds, 1),
            ]

            root["speakers"] = speakerLabels
            root["segments"] = pass.segments.map { segment in
                var payload: [String: Any] = [
                    "start": rounded(segment.start, 2),
                    "end": rounded(segment.end, 2),
                    "speaker": label(for: segment.speakerID),
                    "text": segment.text.trimmingCharacters(in: .whitespacesAndNewlines),
                ]
                // Never fabricate confidence: emit null when the engine gave none.
                payload["confidence"] = segment.averageLogProb.map { confidence(fromLogProb: $0) } ?? NSNull()
                if let words = segment.words, !words.isEmpty {
                    payload["words"] = words.map { word in
                        [
                            "word": word.word,
                            "start": rounded(TimeInterval(word.start), 2),
                            "end": rounded(TimeInterval(word.end), 2),
                            "confidence": rounded(TimeInterval(word.probability), 3),
                        ] as [String: Any]
                    }
                }
                return payload
            }

            return try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
        }

        // MARK: - Markdown (human-readable rendering)

        func markdown() -> String {
            var lines: [String] = []
            let title = probe.url.deletingPathExtension().lastPathComponent
            lines.append("# \(title)")
            lines.append("")
            lines.append("- **Source:** `\(probe.url.lastPathComponent)`")
            lines.append("- **Duration:** \(Self.clock(probe.duration))")
            if let created = probe.createdAt {
                lines.append("- **Recorded:** \(Self.humanDate.string(from: created))")
            }
            lines.append("- **Speakers:** \(speakerLabels.count)")
            lines.append("- **Transcribed:** \(Self.humanDate.string(from: Date())) by Consensus \(ConsensusCLI.appVersion)")
            lines.append("")
            lines.append("---")
            lines.append("")

            // Merge consecutive same-speaker segments into one paragraph, keeping
            // the timestamp of the first segment in the run.
            for turn in mergedTurns() {
                lines.append("**\(turn.speaker)** [\(Self.clock(turn.start))]")
                lines.append("")
                lines.append(turn.text)
                lines.append("")
            }
            return lines.joined(separator: "\n")
        }

        struct Turn {
            let speaker: String
            let start: TimeInterval
            let text: String
        }

        func mergedTurns() -> [Turn] {
            var turns: [Turn] = []
            for segment in pass.segments {
                let speaker = label(for: segment.speakerID)
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                if let last = turns.last, last.speaker == speaker {
                    turns[turns.count - 1] = Turn(
                        speaker: speaker,
                        start: last.start,
                        text: last.text + " " + text
                    )
                } else {
                    turns.append(Turn(speaker: speaker, start: segment.start, text: text))
                }
            }
            return turns
        }

        // MARK: - Speaker labels

        /// Stable, identity-free labels in first-appearance order: the first
        /// voice heard is always SPEAKER_A within a given file (spec §Output).
        var speakerOrder: [String: String] {
            var mapping: [String: String] = [:]
            var next = 0
            for segment in pass.segments where mapping[segment.speakerID] == nil {
                mapping[segment.speakerID] = Self.alphabeticLabel(next)
                next += 1
            }
            return mapping
        }

        var speakerLabels: [String] {
            Array(Set(speakerOrder.values)).sorted()
        }

        func label(for speakerID: String) -> String {
            speakerOrder[speakerID] ?? "SPEAKER_?"
        }

        static func alphabeticLabel(_ index: Int) -> String {
            // A…Z, then AA, AB… so speaker counts above 26 stay unambiguous.
            var value = index
            var letters = ""
            repeat {
                letters = String(UnicodeScalar(UInt8(65 + value % 26))) + letters
                value = value / 26 - 1
            } while value >= 0
            return "SPEAKER_\(letters)"
        }

        // MARK: - Provenance helpers

        private func engineDescriptors() -> [[String: Any]] {
            let attribution = pass.engineAttribution
            var engines: [[String: Any]] = []
            let mirror = Mirror(reflecting: attribution)
            for child in mirror.children {
                if let value = child.value as? String, !value.isEmpty {
                    engines.append(["name": child.label ?? "engine", "model": value, "version": ConsensusCLI.appVersion])
                }
            }
            if engines.isEmpty {
                engines = [[
                    "name": "VibeVoice",
                    "model": "VibeVoice ASR (MLX 4-bit)",
                    "version": ConsensusCLI.appVersion,
                ]]
            }
            return engines
        }

        /// Maps an average log-probability to a 0–1 confidence. Approximate by
        /// construction — it is the engine's own token likelihood, not a
        /// calibrated accuracy estimate.
        private func confidence(fromLogProb logProb: Float) -> Double {
            rounded(TimeInterval(exp(logProb)), 3)
        }

        private func rounded(_ value: TimeInterval, _ places: Int) -> Double {
            let factor = pow(10.0, Double(places))
            return (value * factor).rounded() / factor
        }

        // MARK: - Formatters

        static let iso8601: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return formatter
        }()

        static let humanDate: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter
        }()

        static func clock(_ seconds: TimeInterval) -> String {
            let total = Int(seconds.rounded())
            let hours = total / 3600
            let minutes = (total % 3600) / 60
            let secs = total % 60
            return hours > 0
                ? String(format: "%d:%02d:%02d", hours, minutes, secs)
                : String(format: "%02d:%02d", minutes, secs)
        }
    }
}
