import PDFKit
import SwiftUI

struct ExportView: View {
    @Environment(TranscriptionViewModel.self) private var viewModel
    @State private var previewPDFData: Data?
    @State private var previewDebounceTask: Task<Void, Never>?

    var body: some View {
        @Bindable var vm = viewModel

        HSplitView {
            // Left: Export options
            ScrollView {
                VStack(spacing: ConsensusTheme.Spacing.xl) {
                    // Header
                    VStack(spacing: ConsensusTheme.Spacing.sm) {
                        Image(systemName: "square.and.arrow.up.circle.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(ConsensusTheme.Colors.accent)

                        Text("Export Transcript")
                            .font(ConsensusTheme.Fonts.title)
                            .foregroundStyle(ConsensusTheme.Colors.textPrimary)

                        if let result = viewModel.result {
                            Text("\(result.audioFileName) \u{2022} \(TimeFormatting.durationDisplay(result.duration))")
                                .font(ConsensusTheme.Fonts.subtitle)
                                .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                        }
                    }
                    .padding(.top, ConsensusTheme.Spacing.lg)

                    // Format grid
                    LazyVGrid(columns: [
                        GridItem(.flexible(), spacing: ConsensusTheme.Spacing.md),
                        GridItem(.flexible(), spacing: ConsensusTheme.Spacing.md),
                        GridItem(.flexible(), spacing: ConsensusTheme.Spacing.md),
                    ], spacing: ConsensusTheme.Spacing.md) {
                        ForEach(ExportFormat.allCases) { format in
                            ExportFormatCard(
                                format: format,
                                isSelected: viewModel.selectedFormats.contains(format),
                                onToggle: {
                                    if viewModel.selectedFormats.contains(format) {
                                        viewModel.selectedFormats.remove(format)
                                    } else {
                                        viewModel.selectedFormats.insert(format)
                                    }
                                },
                                onExportSingle: {
                                    Task { await viewModel.exportSingle(format: format) }
                                }
                            )
                        }
                    }
                    .padding(.horizontal)

                    // Legal PDF options
                    if viewModel.selectedFormats.contains(.legalPDF) {
                        legalPDFOptions
                            .padding(.horizontal)
                    }

                    // Export All button
                    exportActions

                    Spacer()
                }
                .padding(ConsensusTheme.Spacing.xl)
            }
            .frame(minWidth: 420)

            // Right: Live PDF preview (when Legal PDF is selected)
            if viewModel.selectedFormats.contains(.legalPDF) {
                legalPDFPreview
                    .frame(minWidth: 350, idealWidth: 450)
            }
        }
        .onChange(of: viewModel.selectedFormats) { _, _ in
            viewModel.persistProjectDraft()
            regeneratePreviewIfNeeded()
        }
        .onChange(of: viewModel.showElapsedTime) { _, _ in
            viewModel.persistProjectDraft()
            regeneratePreviewIfNeeded()
        }
        .onChange(of: viewModel.showClockTime) { _, _ in
            viewModel.persistProjectDraft()
            regeneratePreviewIfNeeded()
        }
        .onChange(of: viewModel.legalPDFHeader) { _, _ in
            viewModel.persistProjectDraft()
            regeneratePreviewDebounced()
        }
        .onChange(of: viewModel.includeCoverPage) { _, _ in
            regeneratePreviewIfNeeded()
        }
        .onChange(of: viewModel.coverPageIncludeSummary) { _, _ in
            regeneratePreviewIfNeeded()
        }
        .onChange(of: viewModel.coverPageIncludeActionItems) { _, _ in
            regeneratePreviewIfNeeded()
        }
        .onAppear {
            regeneratePreviewIfNeeded()
        }
    }

    // MARK: - Legal PDF Options

    private var legalPDFOptions: some View {
        @Bindable var vm = viewModel

        return VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.lg) {
            Label("Legal Transcript Options", systemImage: "doc.text.magnifyingglass")
                .font(.headline)
                .foregroundStyle(ConsensusTheme.Colors.textPrimary)

            VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xs) {
                Text("HEADER TEXT")
                    .font(ConsensusTheme.Fonts.mono(.caption2))
                    .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                TextEditor(text: $vm.legalPDFHeader)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                    .frame(height: 64)
                    .padding(ConsensusTheme.Spacing.sm)
                    .background(ConsensusTheme.Colors.surfacePrimary, in: RoundedRectangle(cornerRadius: ConsensusTheme.Radius.md))
                    .overlay {
                        RoundedRectangle(cornerRadius: ConsensusTheme.Radius.md)
                            .stroke(ConsensusTheme.Colors.border, lineWidth: 1)
                    }
                    .scrollContentBackground(.hidden)
                    .help("Text shown at the top of the first page")
            }

            Divider()
                .overlay(ConsensusTheme.Colors.border)

            Toggle("Show elapsed time", isOn: $vm.showElapsedTime)
                .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                .help("Show time since start of recording (e.g., 00:05:22)")

            Toggle("Show clock time", isOn: $vm.showClockTime)
                .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                .help("Show actual time of day (e.g., 2:34 PM)")

            if vm.showClockTime {
                HStack {
                    Text("Recording started:")
                        .font(ConsensusTheme.Fonts.caption)
                        .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                    if let startTime = viewModel.recordingStartTime {
                        Text(startTime, style: .time)
                            .font(.caption.bold())
                            .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                        Text("(from file)")
                            .font(ConsensusTheme.Fonts.caption2)
                            .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                    } else {
                        Text("Unknown")
                            .font(ConsensusTheme.Fonts.caption)
                            .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                    }
                }
            }
        }
        .consensusCard(label: "Legal Options", icon: "doc.text.magnifyingglass")

        // Quality tier badge
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.sm) {
            Toggle("Include quality tier badge", isOn: $vm.includeQualityTierBadge)
                .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                .help("Adds \"Standard Transcript\" or \"Verified Transcript\" to the export header")

            HStack(spacing: ConsensusTheme.Spacing.sm) {
                Text("Current tier:")
                    .font(ConsensusTheme.Fonts.caption)
                    .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                Text(viewModel.qualityTier)
                    .font(.caption.bold())
                    .foregroundStyle(viewModel.hasConsensusPass ? ConsensusTheme.Colors.confidenceGreen : ConsensusTheme.Colors.textSecondary)
            }
        }
        .consensusCard(label: "Quality", icon: "seal")

        // Cover page
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.sm) {
            Toggle("Include cover page", isOn: $vm.includeCoverPage)
                .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                .help("Prepend a cover page with recording metadata, summary, and action items")

            if vm.includeCoverPage {
                VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.sm) {
                    Toggle("Include summary", isOn: $vm.coverPageIncludeSummary)
                        .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                        .font(.subheadline)

                    Toggle("Include action items", isOn: $vm.coverPageIncludeActionItems)
                        .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                        .font(.subheadline)

                    if viewModel.summaryResult == nil && viewModel.currentProject?.detailedSummary == nil {
                        HStack(spacing: ConsensusTheme.Spacing.xs) {
                            Image(systemName: "info.circle")
                                .foregroundStyle(ConsensusTheme.Colors.confidenceAmber)
                            Text("No summary generated yet. Use the Summary Pane to generate one first.")
                                .font(.caption)
                                .foregroundStyle(ConsensusTheme.Colors.confidenceAmber)
                        }
                    }
                }
                .padding(.leading, ConsensusTheme.Spacing.lg)
            }
        }
        .consensusCard(label: "Cover Page", icon: "doc.richtext")

        // Confidence highlighting
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.sm) {
            Toggle("Highlight low-confidence words", isOn: $vm.highlightLowConfidence)
                .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                .help("Mark words the engine was unsure about with [brackets] in text exports")

            Text("Words below 50% confidence will be wrapped in [brackets] so the reader knows to verify them against the audio.")
                .font(.caption2)
                .foregroundStyle(ConsensusTheme.Colors.textTertiary)
        }
        .consensusCard(label: "Confidence", icon: "waveform.badge.exclamationmark")
    }

    // MARK: - Export Actions

    private var exportActions: some View {
        VStack(spacing: ConsensusTheme.Spacing.sm) {
            Button {
                Task { await viewModel.exportAll() }
            } label: {
                Label("Export All Selected", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: 300)
            }
            .buttonStyle(ConsensusPrimaryButtonStyle())
            .controlSize(.large)
            .disabled(viewModel.selectedFormats.isEmpty || viewModel.isExporting)

            if viewModel.isExporting {
                ProgressView()
                    .controlSize(.small)
            }

            if let error = viewModel.exportError {
                Text(error)
                    .font(ConsensusTheme.Fonts.caption)
                    .foregroundStyle(ConsensusTheme.Colors.danger)
            }

            if let dir = viewModel.lastExportDirectory {
                HStack(spacing: ConsensusTheme.Spacing.xs) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(ConsensusTheme.Colors.success)
                    Text("Exported to \(dir.lastPathComponent)")
                        .font(ConsensusTheme.Fonts.caption)
                        .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                }
            }
        }
    }

    // MARK: - Live PDF Preview

    private var legalPDFPreview: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Preview", systemImage: "eye")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                Spacer()
            }
            .padding(.horizontal, ConsensusTheme.Spacing.lg)
            .padding(.vertical, ConsensusTheme.Spacing.sm)
            .background(ConsensusTheme.Colors.surfacePrimary)

            Divider()
                .overlay(ConsensusTheme.Colors.border)

            if let data = previewPDFData {
                PDFPreviewView(data: data)
            } else {
                VStack(spacing: ConsensusTheme.Spacing.sm) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Generating preview...")
                        .font(ConsensusTheme.Fonts.caption)
                        .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(ConsensusTheme.Colors.surfacePrimary)
    }


    // MARK: - Preview Generation

    private func regeneratePreviewIfNeeded() {
        guard viewModel.selectedFormats.contains(.legalPDF) else {
            previewPDFData = nil
            return
        }
        regeneratePreview()
    }

    private func regeneratePreviewDebounced() {
        previewDebounceTask?.cancel()
        previewDebounceTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            regeneratePreview()
        }
    }

    private func regeneratePreview() {
        guard let result = viewModel.result else { return }
        let options = viewModel.buildLegalPDFOptions()
        Task.detached {
            let data = try? ExportService.buildLegalPDF(
                result: result,
                speakerMapping: await viewModel.speakerMapping,
                options: options
            )
            await MainActor.run {
                previewPDFData = data
            }
        }
    }
}

// MARK: - Summary Parser

private struct ParsedSummary {
    let summary: String?
    let actionItems: String?
}

/// Split a combined LLM summary into the key-points section and action-items section.
private func parseSummaryForCoverPage(_ text: String?) -> ParsedSummary {
    guard let text, !text.isEmpty else {
        return ParsedSummary(summary: nil, actionItems: nil)
    }

    // The LLM typically produces sections like "ACTION ITEMS & DELIVERABLES" and "KEY POINTS"
    let lines = text.components(separatedBy: "\n")
    var actionLines: [String] = []
    var summaryLines: [String] = []
    var currentSection: String = "summary"

    for line in lines {
        let upper = line.uppercased().trimmingCharacters(in: .whitespaces)
        if upper.contains("ACTION ITEM") || upper.contains("DELIVERABLE") || upper.contains("TO-DO") || upper.contains("TODO") {
            currentSection = "actions"
            continue
        } else if upper.contains("KEY POINT") || upper.contains("SUMMARY") {
            currentSection = "summary"
            continue
        }

        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { continue }

        switch currentSection {
        case "actions": actionLines.append(trimmed)
        default: summaryLines.append(trimmed)
        }
    }

    return ParsedSummary(
        summary: summaryLines.isEmpty ? text : summaryLines.joined(separator: "\n"),
        actionItems: actionLines.isEmpty ? nil : actionLines.joined(separator: "\n")
    )
}

// MARK: - PDF Preview (NSViewRepresentable)

private struct PDFPreviewView: NSViewRepresentable {
    let data: Data

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.backgroundColor = NSColor(ConsensusTheme.Colors.surfacePrimary)
        if let document = PDFDocument(data: data) {
            pdfView.document = document
        }
        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        if let document = PDFDocument(data: data) {
            pdfView.document = document
        }
    }
}

// MARK: - Export Format Card

struct ExportFormatCard: View {
    let format: ExportFormat
    let isSelected: Bool
    let onToggle: () -> Void
    let onExportSingle: () -> Void

    var body: some View {
        VStack(spacing: ConsensusTheme.Spacing.sm) {
            Image(systemName: format.icon)
                .font(.title2)
                .foregroundStyle(isSelected ? ConsensusTheme.Colors.accent : ConsensusTheme.Colors.textSecondary)

            Text(format.displayName)
                .font(.headline)
                .foregroundStyle(ConsensusTheme.Colors.textPrimary)

            Text(".\(format.fileExtension)")
                .font(ConsensusTheme.Fonts.mono(.caption2))
                .foregroundStyle(ConsensusTheme.Colors.textTertiary)

            HStack(spacing: ConsensusTheme.Spacing.sm) {
                Button {
                    onToggle()
                } label: {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? ConsensusTheme.Colors.accent : ConsensusTheme.Colors.textTertiary)
                }
                .buttonStyle(.plain)

                Button {
                    onExportSingle()
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Export this format only")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(ConsensusTheme.Spacing.lg)
        .background {
            RoundedRectangle(cornerRadius: ConsensusTheme.Radius.lg)
                .fill(isSelected ? ConsensusTheme.Colors.accentSubtle : ConsensusTheme.Colors.surfacePrimary)
                .overlay {
                    RoundedRectangle(cornerRadius: ConsensusTheme.Radius.lg)
                        .stroke(
                            isSelected ? ConsensusTheme.Colors.borderAccent : ConsensusTheme.Colors.border,
                            lineWidth: 1
                        )
                }
        }
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
    }
}
