import Foundation

/// Formatters that turn a `ProjectDocument` + `TranscriptPass` (+ optional
/// `SummaryDocument`) into text representations suitable for the clipboard,
/// a `.txt` file, or an Obsidian-compatible Markdown note.
///
/// Phase 1e.1 ships plain text, Markdown, and Obsidian Markdown (with YAML
/// frontmatter). Legal PDF, DOCX, and SRT/VTT can layer on later; they need
/// different plumbing (PDF renderer, XML writer, subtitle formatter) and
/// aren't ready to ship yet.
enum TranscriptExporter {

    // MARK: - Plain text

    /// Pure-text transcript. One turn per paragraph; header line carries
    /// "Name HH:MM:SS".
    static func plainText(
        project: ProjectDocument,
        pass: TranscriptPass
    ) -> String {
        var lines: [String] = []
        lines.append(project.title)
        lines.append(String(repeating: "=", count: project.title.count))
        lines.append("")

        for segment in pass.segments {
            let name = displayName(for: segment.speakerID, in: project)
            let stamp = formatTimestamp(segment.start)
            lines.append("\(name)  \(stamp)")
            lines.append(segment.text)
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Markdown

    /// Simple Markdown: speaker names as bold, timestamps in a code-style
    /// monospace run. Good for pasting into Slack, email, or plain Markdown
    /// editors.
    static func markdown(
        project: ProjectDocument,
        pass: TranscriptPass,
        summary: SummaryDocument? = nil,
        includeSummary: Bool = false
    ) -> String {
        var lines: [String] = []

        lines.append("# \(project.title)")
        lines.append("")
        lines.append(metadataLine(project: project, pass: pass))
        lines.append("")

        if includeSummary, let summary, !summary.summary.isEmpty {
            lines.append("## Summary")
            lines.append("")
            lines.append(summary.summary)
            lines.append("")
            if !summary.todos.isEmpty {
                lines.append("## To-dos")
                lines.append("")
                for todo in summary.todos {
                    let box = todo.isDone ? "[x]" : "[ ]"
                    let owner = todo.ownerSpeakerID.flatMap { displayName(for: $0, in: project) }
                    let suffix = owner.map { " (\($0))" } ?? ""
                    lines.append("- \(box) \(todo.text)\(suffix)")
                }
                lines.append("")
            }
        }

        lines.append("## Transcript")
        lines.append("")
        for segment in pass.segments {
            let name = displayName(for: segment.speakerID, in: project)
            let stamp = formatTimestamp(segment.start)
            lines.append("**\(name)** `\(stamp)`")
            lines.append("")
            lines.append(segment.text)
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Obsidian Markdown (with YAML frontmatter)

    /// Obsidian-flavoured Markdown with YAML frontmatter. Matches the shape
    /// laid out in the rewrite plan (title / date / duration / speakers /
    /// tags). Intended to drop straight into a vault note.
    static func obsidianMarkdown(
        project: ProjectDocument,
        pass: TranscriptPass,
        summary: SummaryDocument? = nil,
        includeSummary: Bool = false
    ) -> String {
        let dateString = yamlDate(from: project.audio.recordingStartTime ?? project.createdAt)
        let duration = formatDurationLong(project.audio.durationSeconds)
        let speakerList = yamlList(
            project.speakers.map(\.displayName).filter { !$0.isEmpty }
        )
        let engine = pass.engineAttribution.primaryEngine
        let tags = yamlList(["consensus/transcript", "engine/\(engine.lowercased().replacingOccurrences(of: " ", with: "-"))"])

        var lines: [String] = []
        lines.append("---")
        lines.append("title: \(yamlEscape(project.title))")
        lines.append("date: \(dateString)")
        lines.append("duration: \(duration)")
        lines.append("speakers: \(speakerList)")
        lines.append("tags: \(tags)")
        lines.append("---")
        lines.append("")

        // Reuse the Markdown body — same transcript formatting.
        let body = markdown(
            project: project,
            pass: pass,
            summary: summary,
            includeSummary: includeSummary
        )
        // Strip the first Markdown H1 so the frontmatter's `title` is the
        // one source of truth for note titles in Obsidian.
        let stripped = body
            .split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
            .dropFirst(2)
            .joined(separator: "\n")
        lines.append("# \(project.title)")
        lines.append(String(stripped))

        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func displayName(for speakerID: String, in project: ProjectDocument) -> String {
        if let speaker = project.speakers.first(where: { $0.id == speakerID }),
           !speaker.displayName.isEmpty {
            return speaker.displayName
        }
        return speakerID
    }

    private static func metadataLine(project: ProjectDocument, pass: TranscriptPass) -> String {
        var parts: [String] = []
        parts.append(formatDurationLong(project.audio.durationSeconds))
        parts.append("\(pass.segments.count) turn\(pass.segments.count == 1 ? "" : "s")")
        if !pass.engineAttribution.primaryEngine.isEmpty {
            parts.append(pass.engineAttribution.primaryEngine)
        }
        if let start = project.audio.recordingStartTime {
            let fmt = DateFormatter()
            fmt.dateStyle = .medium
            fmt.timeStyle = .short
            parts.append(fmt.string(from: start))
        }
        return parts.joined(separator: " · ")
    }

    private static func formatTimestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    private static func formatDurationLong(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%dh %dm %ds", h, m, s) }
        if m > 0 { return String(format: "%dm %ds", m, s) }
        return String(format: "%ds", s)
    }

    private static func yamlDate(from date: Date) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withYear, .withMonth, .withDay, .withDashSeparatorInDate]
        return fmt.string(from: date)
    }

    private static func yamlList(_ values: [String]) -> String {
        let quoted = values.map { "\"\(yamlEscape($0))\"" }
        return "[\(quoted.joined(separator: ", "))]"
    }

    private static func yamlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
