import SwiftUI

/// A single entry in the process log.
struct ProcessLogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let message: String
    let level: Level
    var detail: String?

    enum Level {
        case info
        case progress
        case success
        case warning
        case error
        case aiThinking

        var label: String {
            switch self {
            case .info: return "INFO"
            case .progress: return "PROGRESS"
            case .success: return "SUCCESS"
            case .warning: return "WARNING"
            case .error: return "ERROR"
            case .aiThinking: return "AI"
            }
        }

        var icon: String {
            switch self {
            case .info: return "info.circle"
            case .progress: return "arrow.triangle.2.circlepath"
            case .success: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .error: return "xmark.circle.fill"
            case .aiThinking: return "brain"
            }
        }

        var color: Color {
            switch self {
            case .info: return ConsensusTheme.Colors.textSecondary
            case .progress: return ConsensusTheme.Colors.accent
            case .success: return ConsensusTheme.Colors.confidenceGreen
            case .warning: return ConsensusTheme.Colors.confidenceAmber
            case .error: return ConsensusTheme.Colors.confidenceRed
            case .aiThinking: return Color(red: 0.55, green: 0.40, blue: 0.95)
            }
        }
    }

    init(_ message: String, level: Level = .info, detail: String? = nil) {
        self.timestamp = Date()
        self.message = message
        self.level = level
        self.detail = detail
    }
}

/// Observable process log that services can write to.
/// Contains both a task log (left pane) and a live output stream (right pane).
@Observable
@MainActor
final class ProcessLog {
    private(set) var entries: [ProcessLogEntry] = []
    var isVisible: Bool = false

    /// Live output text for the right pane (transcription words, LLM tokens, etc.)
    private(set) var outputText: String = ""

    /// Label for the current output stream
    private(set) var outputLabel: String = "Output"

    func log(_ message: String, level: ProcessLogEntry.Level = .info, detail: String? = nil) {
        let entry = ProcessLogEntry(message, level: level, detail: detail)
        entries.append(entry)

        // Keep a reasonable history
        if entries.count > 500 {
            entries.removeFirst(entries.count - 500)
        }
    }

    /// Append text to the live output stream (token-by-token for LLM, word-by-word for transcription).
    func appendOutput(_ text: String) {
        outputText += text

        // Keep output from growing unbounded — trim the front if too long
        if outputText.count > 50_000 {
            let dropCount = outputText.count - 40_000
            outputText = String(outputText.dropFirst(dropCount))
        }
    }

    /// Replace the entire output text (for transcription state updates).
    func setOutput(_ text: String) {
        outputText = text
    }

    /// Set the label for the output pane.
    func setOutputLabel(_ label: String) {
        outputLabel = label
    }

    /// Clear the output stream.
    func clearOutput() {
        outputText = ""
        outputLabel = "Output"
    }

    func clear() {
        entries.removeAll()
        outputText = ""
        outputLabel = "Output"
    }

    /// Render the full log as a human-readable markdown string for saving to a file.
    /// Includes timestamps, severity, every message, and any attached detail block.
    func renderAsMarkdown(title: String = "Diagnostic Report") -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

        var lines: [String] = []
        lines.append("# \(title)")
        lines.append("")
        lines.append("Generated: \(formatter.string(from: Date()))")
        lines.append("Entries: \(entries.count)")
        lines.append("")
        lines.append("---")
        lines.append("")

        for entry in entries {
            let time = formatter.string(from: entry.timestamp)
            let level = "[\(entry.level.label)]"
            lines.append("- `\(time)` \(level) \(entry.message)")
            if let detail = entry.detail, !detail.isEmpty {
                lines.append("")
                lines.append("  ```")
                for detailLine in detail.components(separatedBy: "\n") {
                    lines.append("  \(detailLine)")
                }
                lines.append("  ```")
                lines.append("")
            }
        }

        if !outputText.isEmpty {
            lines.append("")
            lines.append("---")
            lines.append("")
            lines.append("## Live Output")
            lines.append("")
            lines.append("```")
            lines.append(outputText)
            lines.append("```")
        }

        return lines.joined(separator: "\n")
    }
}

/// Floating, closeable process log window with split panes.
/// Left: Task log with timestamped entries.
/// Right: Live output stream (transcription text, LLM generation, etc.)
struct ProcessLogView: View {
    @Bindable var processLog: ProcessLog
    @Environment(TranscriptionViewModel.self) private var viewModel
    @EnvironmentObject private var settings: AppSettings
    @State private var isExpanded: Bool = true
    @State private var scrollToBottom: Bool = true
    @State private var outputScrollToBottom: Bool = true
    @State private var savedReportURL: URL?

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            titleBar

            if isExpanded {
                // Split content: left = task log, right = output
                HSplitView {
                    // Left pane: Process Log
                    VStack(spacing: 0) {
                        paneHeader(title: "Process Log", icon: "list.bullet", count: processLog.entries.count)
                        logContent
                    }
                    .frame(minWidth: 260)

                    // Right pane: Output Log
                    VStack(spacing: 0) {
                        paneHeader(title: processLog.outputLabel, icon: "text.justify.left", count: nil)
                        outputContent
                    }
                    .frame(minWidth: 260)
                }

                // Footer with controls
                footer
            }
        }
        .frame(width: 700, height: isExpanded ? 360 : 36)
        .background(
            RoundedRectangle(cornerRadius: ConsensusTheme.Radius.lg)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: ConsensusTheme.Radius.lg)
                        .stroke(ConsensusTheme.Colors.border, lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: ConsensusTheme.Radius.lg))
        .shadow(color: .black.opacity(0.3), radius: 12, x: 0, y: 4)
    }

    // MARK: - Components

    private var titleBar: some View {
        HStack(spacing: ConsensusTheme.Spacing.sm) {
            Image(systemName: "terminal")
                .font(.caption)
                .foregroundStyle(ConsensusTheme.Colors.accent)

            Text("Consensus Engine")
                .font(.caption.weight(.semibold))
                .foregroundStyle(ConsensusTheme.Colors.textPrimary)

            Spacer()

            // Collapse/expand
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                    .font(.caption2)
                    .foregroundStyle(ConsensusTheme.Colors.textSecondary)
            }
            .buttonStyle(.plain)

            // Close
            Button {
                processLog.isVisible = false
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(ConsensusTheme.Colors.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, ConsensusTheme.Spacing.md)
        .padding(.vertical, ConsensusTheme.Spacing.sm)
        .background(ConsensusTheme.Colors.surfacePrimary.opacity(0.6))
        .overlay(alignment: .bottom) {
            if isExpanded {
                Divider().overlay(ConsensusTheme.Colors.border)
            }
        }
    }

    private func paneHeader(title: String, icon: String, count: Int?) -> some View {
        HStack(spacing: ConsensusTheme.Spacing.xs) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundStyle(ConsensusTheme.Colors.textTertiary)

            Text(title)
                .font(ConsensusTheme.Fonts.mono(.caption2))
                .foregroundStyle(ConsensusTheme.Colors.textSecondary)

            if let count, count > 0 {
                Text("\(count)")
                    .font(ConsensusTheme.Fonts.mono(size: 9, weight: .medium))
                    .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        Capsule()
                            .fill(ConsensusTheme.Colors.surfacePrimary.opacity(0.5))
                    )
            }

            Spacer()
        }
        .padding(.horizontal, ConsensusTheme.Spacing.sm)
        .padding(.vertical, ConsensusTheme.Spacing.xs)
        .background(ConsensusTheme.Colors.surfacePrimary.opacity(0.3))
        .overlay(alignment: .bottom) {
            Divider().overlay(ConsensusTheme.Colors.border.opacity(0.5))
        }
    }

    private var logContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(processLog.entries) { entry in
                        ProcessLogEntryRow(entry: entry, timeFormatter: timeFormatter)
                            .id(entry.id)
                    }
                }
                .padding(.horizontal, ConsensusTheme.Spacing.xs)
                .padding(.vertical, ConsensusTheme.Spacing.xs)
            }
            .onChange(of: processLog.entries.count) {
                if scrollToBottom, let lastEntry = processLog.entries.last {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(lastEntry.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var outputContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(processLog.outputText.isEmpty ? "Waiting for output..." : processLog.outputText)
                    .font(ConsensusTheme.Fonts.mono(size: 10, weight: .regular))
                    .foregroundStyle(
                        processLog.outputText.isEmpty
                            ? ConsensusTheme.Colors.textTertiary
                            : ConsensusTheme.Colors.textPrimary
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(ConsensusTheme.Spacing.sm)
                    .id("outputBottom")
            }
            .onChange(of: processLog.outputText) {
                if outputScrollToBottom {
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo("outputBottom", anchor: .bottom)
                    }
                }
            }
        }
        .background(ConsensusTheme.Colors.surfacePrimary.opacity(0.15))
    }

    private var footer: some View {
        HStack(spacing: ConsensusTheme.Spacing.sm) {
            // Auto-scroll toggle
            Button {
                scrollToBottom.toggle()
                outputScrollToBottom.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.to.line")
                        .font(.caption2)
                    Text("Auto-scroll")
                        .font(.caption2)
                }
                .foregroundStyle(scrollToBottom ? ConsensusTheme.Colors.accent : ConsensusTheme.Colors.textTertiary)
            }
            .buttonStyle(.plain)

            Spacer()

            // Save Report (Diagnostic Mode only)
            if settings.diagnosticModeEnabled {
                Button {
                    if let url = viewModel.saveDiagnosticReport() {
                        savedReportURL = url
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.caption2)
                        Text("Save Report")
                            .font(.caption2)
                    }
                    .foregroundStyle(ConsensusTheme.Colors.accent)
                }
                .buttonStyle(.plain)
                .help("Export the process log as a markdown file for detailed review.")
            }

            // Clear log
            Button {
                processLog.clear()
            } label: {
                Text("Clear")
                    .font(.caption2)
                    .foregroundStyle(ConsensusTheme.Colors.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, ConsensusTheme.Spacing.md)
        .padding(.vertical, ConsensusTheme.Spacing.xs)
        .background(ConsensusTheme.Colors.surfacePrimary.opacity(0.4))
        .overlay(alignment: .top) {
            Divider().overlay(ConsensusTheme.Colors.border)
        }
    }
}

/// A single row in the process log.
private struct ProcessLogEntryRow: View {
    let entry: ProcessLogEntry
    let timeFormatter: DateFormatter

    var body: some View {
        HStack(alignment: .top, spacing: ConsensusTheme.Spacing.xs) {
            // Timestamp
            Text(timeFormatter.string(from: entry.timestamp))
                .font(ConsensusTheme.Fonts.mono(size: 9, weight: .regular))
                .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                .frame(width: 48, alignment: .leading)

            // Icon
            Image(systemName: entry.level.icon)
                .font(.system(size: 9))
                .foregroundStyle(entry.level.color)
                .frame(width: 12)

            // Message
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.message)
                    .font(ConsensusTheme.Fonts.mono(size: 10, weight: .regular))
                    .foregroundStyle(entry.level == .aiThinking
                        ? entry.level.color
                        : ConsensusTheme.Colors.textPrimary
                    )
                    .lineLimit(3)

                if let detail = entry.detail {
                    Text(detail)
                        .font(ConsensusTheme.Fonts.mono(size: 9, weight: .regular))
                        .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, ConsensusTheme.Spacing.xs)
    }
}
