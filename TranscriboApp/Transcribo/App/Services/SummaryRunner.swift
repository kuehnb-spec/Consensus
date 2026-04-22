import Foundation

/// Generates a conversational summary + extracted to-dos from a completed
/// transcript pass using the existing `TranscriptCleanupService`. The LLM
/// returns a plain-text two-section document ("ACTION ITEMS & DELIVERABLES"
/// then "KEY POINTS"); this runner parses it into a structured
/// `SummaryDocument` for the `SummaryPane` view.
///
/// Parsing is intentionally forgiving: if the LLM deviates from the
/// expected structure, we still surface the full text in the `summary`
/// field rather than throwing.
final class SummaryRunner {
    private let cleanup = TranscriptCleanupService()

    struct Progress: Sendable {
        let fraction: Double
        let label: String
    }

    struct Output: Sendable {
        let summary: String
        let todos: [TodoItem]
    }

    /// Stage weightings. Model load dominates on first run (~4.5 GB
    /// download for Qwen 3 8B); summarisation itself is seconds on an
    /// 8-minute transcript.
    private enum Weights {
        static let modelLoad: Double = 0.35
        static let summarize: Double = 0.65
    }

    func run(
        project: ProjectDocument,
        pass: TranscriptPass,
        model: CleanupModel = CleanupModel.recommended(),
        progress: @escaping @Sendable (Progress) -> Void
    ) async throws -> Output {
        progress(Progress(fraction: 0, label: "Loading \(model.displayName)…"))

        try await cleanup.loadModel(model) { fraction in
            let firstRunHint = fraction < 1.0
                ? "Downloading \(model.displayName) (\(model.approximateSize))…"
                : "Loading \(model.displayName)…"
            progress(Progress(
                fraction: fraction * Weights.modelLoad,
                label: firstRunHint
            ))
        }

        // Format the transcript for the LLM using the existing helper so
        // the surface here matches what the legacy pipeline feeds in.
        let mapping = SpeakerMapping(
            names: Dictionary(uniqueKeysWithValues: project.speakers.map { ($0.id, $0.displayName) })
        )
        let result = TranscriptionResult(
            audioPath: project.audio.originalURL.path,
            duration: project.audio.durationSeconds,
            segments: pass.segments
        )
        let formatted = TranscriptCleanupService.formatForCleanup(
            result: result,
            speakerMapping: mapping
        )

        // Streamed so the progress bar moves while generation runs. The
        // cleanup service's token counter is loose (we don't know the max
        // from here), so we cap the contribution at the summarize weight.
        progress(Progress(
            fraction: Weights.modelLoad,
            label: "Summarising…"
        ))

        let tokenCounter = TokenCounter()
        let raw = try await cleanup.process(
            transcript: formatted,
            task: .summarize,
            tokenCallback: { _ in
                let tokens = tokenCounter.increment()
                // Summary output is typically ~1000 tokens; use that as the
                // denominator but never exceed the summarize weight.
                let approx = min(1.0, Double(tokens) / 1000.0)
                progress(Progress(
                    fraction: Weights.modelLoad + approx * Weights.summarize,
                    label: "Summarising… (\(tokens) tokens)"
                ))
            }
        )

        progress(Progress(fraction: 1.0, label: "Done"))

        return Self.parse(raw: raw, speakers: project.speakers)
    }

    // MARK: - Parsing

    /// Splits the LLM's plain-text output into the two sections the prompt
    /// asks for and converts the action-items list into `TodoItem`s. If
    /// the prompt deviates — say it omits the "KEY POINTS" header — we
    /// still return the whole text as the summary so nothing is lost.
    static func parse(raw: String, speakers: [Speaker]) -> Output {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let keyPointsRange = trimmed.range(of: "KEY POINTS", options: .caseInsensitive)

        let actionSection: String
        let summaryText: String
        if let kp = keyPointsRange {
            actionSection = String(trimmed[..<kp.lowerBound])
            summaryText = String(trimmed[kp.lowerBound...])
        } else {
            actionSection = ""
            summaryText = trimmed
        }

        // Drop the leading "ACTION ITEMS & DELIVERABLES" header if it's
        // present, then pick list-looking lines out of what's left.
        let actionBody = actionSection
            .replacingOccurrences(
                of: "action items & deliverables",
                with: "",
                options: .caseInsensitive
            )
            .replacingOccurrences(
                of: "action items and deliverables",
                with: "",
                options: .caseInsensitive
            )

        let todos = actionBody
            .components(separatedBy: .newlines)
            .compactMap { line -> TodoItem? in parseTodoLine(line, speakers: speakers) }

        return Output(summary: cleanSummaryText(summaryText), todos: todos)
    }

    private static func parseTodoLine(_ line: String, speakers: [Speaker]) -> TodoItem? {
        var text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // List markers we'll peel off: "-", "*", "•", "1.", "1)"
        let bullets: [String] = ["-", "*", "•"]
        var foundBullet = false
        for bullet in bullets {
            if text.hasPrefix(bullet + " ") {
                text = String(text.dropFirst(bullet.count + 1))
                foundBullet = true
                break
            }
        }
        if !foundBullet {
            // Numbered list: match "1." or "1)"
            if let match = text.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                text.removeSubrange(match)
                foundBullet = true
            }
        }
        guard foundBullet else { return nil }

        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // Try to split on the first colon to pull out the speaker label
        // the prompt asks for ("[NAME]: deliverable"). Also accept
        // "NAME: deliverable" without brackets.
        var ownerSpeakerID: String? = nil
        var taskText = text
        if let colon = text.firstIndex(of: ":") {
            let head = String(text[..<colon])
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            let tail = String(text[text.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            if !head.isEmpty && !tail.isEmpty && head.count <= 60 {
                // Try to resolve to a known speaker
                if let match = speakers.first(where: { $0.displayName.lowercased() == head.lowercased() }) {
                    ownerSpeakerID = match.id
                }
                taskText = tail
            }
        }

        return TodoItem(text: taskText, ownerSpeakerID: ownerSpeakerID)
    }

    private static func cleanSummaryText(_ text: String) -> String {
        // Drop the leading "KEY POINTS" header; everything after is the
        // body. Keep newlines to preserve paragraph structure.
        let withoutHeader = text.replacingOccurrences(
            of: #"^\s*key points[:\s]*"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        return withoutHeader.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Helpers

    private final class TokenCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int = 0
        func increment() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }
    }
}
