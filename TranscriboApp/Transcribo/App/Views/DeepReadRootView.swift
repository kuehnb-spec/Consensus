import Foundation
import SwiftUI

/// The top-level view of the app. Routes on `DeepReadViewModel.stage` to the
/// stage-specific child view.
struct DeepReadRootView: View {
    @Bindable var viewModel: DeepReadViewModel
    @EnvironmentObject private var settings: AppSettings

    @State private var showingExportSheet: Bool = false
    @State private var showingInspector: Bool = false
    @State private var showingLibrary: Bool = false
    @State private var showingVoiceLibrary: Bool = false
    @State private var showingShortcuts: Bool = false
    @State private var showingManualRevision: Bool = false

    var body: some View {
        ZStack {
            ConsensusTheme.Colors.background
                .ignoresSafeArea()

            currentStageView
                .transition(.opacity.combined(with: .scale(scale: 0.99)))
        }
        .animation(.easeInOut(duration: 0.2), value: stageIdentityToken)
        .preferredColorScheme(.dark)
        .tint(ConsensusTheme.Colors.accent)
        .fileImporter(
            isPresented: $viewModel.showFilePicker,
            allowedContentTypes: [.audio, .mpeg4Audio, .mp3, .wav, .aiff],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    Task { await viewModel.beginImport(from: url) }
                }
            case .failure(let error):
                viewModel.errorMessage = error.localizedDescription
                viewModel.showError = true
            }
        }
        .alert("Error", isPresented: $viewModel.showError) {
            Button("OK") { viewModel.showError = false }
        } message: {
            Text(viewModel.errorMessage ?? "An unknown error occurred.")
        }
        .sheet(isPresented: $showingExportSheet) {
            ExportSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $showingInspector) {
            PipelineInspectorView(viewModel: viewModel)
        }
        .sheet(isPresented: $showingLibrary) {
            ProjectLibraryView(viewModel: viewModel)
        }
        .sheet(isPresented: $showingVoiceLibrary) {
            VoiceLibraryView(viewModel: viewModel)
        }
        .sheet(isPresented: $showingShortcuts) {
            KeyboardShortcutsView()
        }
        .sheet(isPresented: $showingManualRevision) {
            ManualRevisionSheet(viewModel: viewModel)
        }
        .background(libraryShortcutHost)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Text("Consensus")
                    .font(ConsensusType.displayHeading)
                    .foregroundStyle(ConsensusTheme.Colors.textPrimary)
            }
            ToolbarItem(placement: .navigation) {
                Button {
                    showingLibrary = true
                } label: {
                    Label("Project Library", systemImage: "square.stack")
                }
                .help("Browse saved projects (⌘L)")
            }
            if viewModel.project != nil {
                // Export + Copy + Summary-pane toggle only make sense once
                // there's a transcript on screen.
                if case .reviewing = viewModel.stage {
                    if viewModel.project?.mode == .studio {
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                showingInspector = true
                            } label: {
                                Label("Inspector", systemImage: "gauge.medium")
                            }
                            .help("Open the Pipeline Inspector")
                        }
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                showingVoiceLibrary = true
                            } label: {
                                Label("Voice Library", systemImage: "person.wave.2")
                            }
                            .help("Manage the voice library")
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            viewModel.toggleSummaryPane()
                        } label: {
                            Label(
                                viewModel.showSummaryPane ? "Hide summary" : "Show summary",
                                systemImage: viewModel.showSummaryPane
                                    ? "sidebar.trailing"
                                    : "sidebar.squares.trailing"
                            )
                        }
                        .help("Toggle the summary & to-dos pane")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showingManualRevision = true
                        } label: {
                            Label("Manual Revision", systemImage: "pencil.and.scribble")
                        }
                        .help("Open the manual revision pane")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        copyMenu
                    }
                    ToolbarItem(placement: .primaryAction) {
                        exportMenu
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        viewModel.close()
                    } label: {
                        Label("Close Project", systemImage: "xmark")
                    }
                    .help("Close this project (returns to the drop screen)")
                }
            }
        }
    }

    // MARK: - Stage routing

    @ViewBuilder
    private var currentStageView: some View {
        switch viewModel.stage {
        case .idle:
            DeepReadDropView(viewModel: viewModel)

        case .importingAudio(let url):
            StageProgressView(
                headline: "Preparing audio",
                detail: url.lastPathComponent,
                fraction: nil
            )

        case .setup:
            DeepReadSetupView(viewModel: viewModel)

        case .transcribing(let progress):
            TranscriptionProgressView(
                progress: progress,
                snippets: viewModel.liveTranscriptionSnippets,
                projectTitle: viewModel.project?.title
            )

        case .namingSpeakers(let suggestions):
            SpeakerNamingView(
                viewModel: viewModel,
                suggestions: suggestions
            )

        case .reconciling(let progress):
            StageProgressView(
                headline: "Reviewing Patches",
                detail: progress.label.isEmpty ? "Patch editor in progress..." : progress.label,
                fraction: progress.fraction
            )

        case .reviewing:
            DeepReadReviewView(viewModel: viewModel)

        case .exporting:
            PlaceholderStageView(
                stage: "Export",
                plan: "Phase 1e.4 — format picker + include-summary checkbox."
            )
        }
    }

    /// A simple Equatable token the `.animation(_:value:)` can key off of.
    /// The `Stage` enum has associated values that don't fit into Equatable
    /// cheaply (progress updates fire on every fraction change and would
    /// animate each tick). This token changes only when the case changes.
    private var stageIdentityToken: Int {
        switch viewModel.stage {
        case .idle:             return 0
        case .importingAudio:   return 1
        case .setup:            return 2
        case .transcribing:     return 3
        case .namingSpeakers:   return 4
        case .reconciling:      return 5
        case .reviewing:        return 6
        case .exporting:        return 7
        }
    }

    // MARK: - Hidden keyboard-shortcut host

    /// Zero-sized button group that registers window-level keyboard
    /// shortcuts for the root view. Mirrors the pattern in
    /// `DeepReadReviewView.keyboardShortcutHost`.
    @ViewBuilder
    private var libraryShortcutHost: some View {
        Group {
            Button("Toggle Project Library") {
                showingLibrary.toggle()
            }
            .keyboardShortcut("l", modifiers: [.command])

            Button("Keyboard shortcuts") {
                showingShortcuts.toggle()
            }
            .keyboardShortcut("/", modifiers: [.command])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - Export / copy menus

    private var copyMenu: some View {
        Menu {
            Button("Copy as Markdown") {
                viewModel.copyToPasteboard(format: .md)
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            Button("Copy as plain text") {
                viewModel.copyToPasteboard(format: .txt)
            }
            Button("Copy as Obsidian Markdown") {
                viewModel.copyToPasteboard(format: .obsidianMarkdown)
            }
        } label: {
            Label(
                viewModel.copyConfirmationVisible ? "Copied" : "Copy",
                systemImage: viewModel.copyConfirmationVisible ? "checkmark" : "doc.on.doc"
            )
        }
        .help("Copy the transcript to the clipboard (⇧⌘C for Markdown)")
    }

    private var exportMenu: some View {
        Menu {
            Button("Export with options…") {
                showingExportSheet = true
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])

            Divider()

            Button("Save as Legal PDF…") {
                _ = viewModel.exportToFile(
                    format: .legalPDF,
                    includeSummary: viewModel.showSummaryPane,
                    legalPDFOptions: viewModel.defaultLegalPDFOptions(
                        includeSummary: viewModel.showSummaryPane,
                        includeCoverPage: viewModel.showSummaryPane
                    )
                )
            }
            .keyboardShortcut("p", modifiers: [.command])

            Button("Save as Markdown…") {
                _ = viewModel.exportToFile(format: .md)
            }
            .keyboardShortcut("e", modifiers: [.command])
            Button("Save as Obsidian Markdown…") {
                _ = viewModel.exportToFile(format: .obsidianMarkdown)
            }
            Button("Save as plain text…") {
                _ = viewModel.exportToFile(format: .txt)
            }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .help("Save the transcript to a file (⌘E for Markdown, ⇧⌘E for options)")
    }
}

// MARK: - Placeholder stage view

/// Shown for stages that have routing defined but no UI yet. Makes the
/// phasing honest to the user: the flow steps are visible, and where each
/// still-to-be-built stage fits is spelled out. Replaces each case as the
/// relevant phase ships.
struct PlaceholderStageView: View {
    let stage: String
    let plan: String

    var body: some View {
        VStack(spacing: ConsensusTheme.Spacing.md) {
            Image(systemName: "hammer")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(ConsensusTheme.Colors.textTertiary)
            Text(stage)
                .font(ConsensusType.displayHeading)
                .foregroundStyle(ConsensusTheme.Colors.textPrimary)
            Text(plan)
                .font(ConsensusType.displayCaption)
                .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(ConsensusTheme.Spacing.xxl)
        .background(
            RoundedRectangle(cornerRadius: ConsensusTheme.Radius.xl, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: ConsensusTheme.Radius.xl, style: .continuous)
                        .stroke(ConsensusTheme.Colors.border, lineWidth: 1)
                )
        )
        .padding(ConsensusTheme.Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Transcription progress view

struct TranscriptionProgressView: View {
    let progress: DeepReadViewModel.StageProgress
    let snippets: [DeepReadViewModel.LiveTranscriptionSnippet]
    let projectTitle: String?

    private var clampedFraction: Double {
        max(0, min(1, progress.fraction))
    }

    private var statusText: String {
        if let status = progress.status, !status.isEmpty {
            return status
        }
        if !progress.label.isEmpty {
            return progress.label
        }
        return "Preparing VibeVoice"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xl) {
            header
            progressRail
            metricsGrid
            liveTranscriptPanel
        }
        .padding(.horizontal, ConsensusTheme.Spacing.xxl)
        .padding(.vertical, ConsensusTheme.Spacing.xl)
        .frame(maxWidth: 920, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: ConsensusTheme.Spacing.xl) {
            VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.sm) {
                Text("Transcribing")
                    .font(ConsensusType.display(size: 34, weight: .semibold))
                    .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                    .lineLimit(1)

                Text(projectTitle ?? "VibeVoice draft pass")
                    .font(ConsensusType.displayBody)
                    .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: ConsensusTheme.Spacing.lg)

            HStack(spacing: ConsensusTheme.Spacing.sm) {
                Circle()
                    .fill(ConsensusTheme.Colors.confidenceGreen)
                    .frame(width: 7, height: 7)
                Text("VibeVoice active")
                    .font(ConsensusType.displayCaption.weight(.medium))
                    .foregroundStyle(ConsensusTheme.Colors.textSecondary)
            }
            .padding(.horizontal, ConsensusTheme.Spacing.md)
            .frame(height: 30)
            .background(
                Capsule()
                    .fill(ConsensusTheme.Colors.surfaceSecondary.opacity(0.74))
                    .overlay(
                        Capsule()
                            .stroke(ConsensusTheme.Colors.border, lineWidth: 1)
                    )
            )
        }
    }

    private var progressRail: some View {
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.md) {
            HStack(spacing: ConsensusTheme.Spacing.md) {
                Image(systemName: "cpu")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ConsensusTheme.Colors.accent)
                Text(statusText)
                    .font(ConsensusType.monoLog)
                    .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: ConsensusTheme.Spacing.md)
                Text("\(Int((clampedFraction * 100).rounded()))%")
                    .font(ConsensusType.monoMetric.weight(.semibold))
                    .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                    .monospacedDigit()
            }
            .frame(height: 36)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(ConsensusTheme.Colors.surfaceSecondary)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    ConsensusTheme.Colors.accent,
                                    ConsensusTheme.Colors.confidenceGreen
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(8, geometry.size.width * clampedFraction))
                }
            }
            .frame(height: 8)
            .clipShape(Capsule())
        }
    }

    private var metricsGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(.adaptive(minimum: 154, maximum: 220), spacing: ConsensusTheme.Spacing.md)
            ],
            spacing: ConsensusTheme.Spacing.md
        ) {
            TranscriptionMetricTile(
                title: "Progress",
                value: "\(Int((clampedFraction * 100).rounded()))%",
                icon: "chart.line.uptrend.xyaxis",
                tint: ConsensusTheme.Colors.accent
            )
            TranscriptionMetricTile(
                title: "Tokens",
                value: progress.tokenCount.map { $0.formatted(.number) } ?? "--",
                icon: "number",
                tint: ConsensusTheme.Colors.confidenceGreen
            )
            TranscriptionMetricTile(
                title: "Speed",
                value: progress.tokensPerSecond.map { String(format: "%.0f/s", $0) } ?? "--",
                icon: "speedometer",
                tint: ConsensusTheme.Colors.confidenceAmber
            )
            TranscriptionMetricTile(
                title: "Elapsed",
                value: Self.formattedElapsed(progress.elapsedSeconds),
                icon: "clock",
                tint: ConsensusTheme.Colors.textSecondary
            )
        }
    }

    private var liveTranscriptPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: ConsensusTheme.Spacing.sm) {
                Image(systemName: "text.bubble")
                    .foregroundStyle(ConsensusTheme.Colors.accent)
                Text("Live transcript")
                    .font(ConsensusType.displaySubheading)
                    .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                Spacer()
                Text("\(snippets.count) updates")
                    .font(ConsensusType.monoMetric)
                    .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                    .monospacedDigit()
            }
            .frame(height: 44)
            .padding(.horizontal, ConsensusTheme.Spacing.lg)

            Divider()
                .overlay(ConsensusTheme.Colors.border)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: ConsensusTheme.Spacing.sm) {
                        if snippets.isEmpty {
                            VStack(spacing: ConsensusTheme.Spacing.md) {
                                Image(systemName: "waveform")
                                    .font(.system(size: 28, weight: .light))
                                    .foregroundStyle(ConsensusTheme.Colors.accent.opacity(0.55))
                                Text("Waiting for VibeVoice output")
                                    .font(ConsensusType.displayBody)
                                    .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 210)
                        } else {
                            ForEach(Array(snippets.enumerated()), id: \.element.id) { index, snippet in
                                LiveTranscriptRow(
                                    index: index + 1,
                                    snippet: snippet
                                )
                                .id(snippet.id)
                            }
                        }
                    }
                    .padding(ConsensusTheme.Spacing.lg)
                }
                .scrollIndicators(.visible)
                .onAppear {
                    scrollToBottom(proxy)
                }
                .onChange(of: snippets.count) { _, _ in
                    scrollToBottom(proxy)
                }
            }
        }
        .frame(height: 310)
        .background(
            RoundedRectangle(cornerRadius: ConsensusTheme.Radius.md, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: ConsensusTheme.Radius.md, style: .continuous)
                        .stroke(ConsensusTheme.Colors.border, lineWidth: 1)
                )
        )
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard let lastID = snippets.last?.id else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            proxy.scrollTo(lastID, anchor: .bottom)
        }
    }

    private static func formattedElapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }
}

private struct TranscriptionMetricTile: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.md) {
            HStack(spacing: ConsensusTheme.Spacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 16)
                Text(title.uppercased())
                    .font(ConsensusType.displayEyebrow)
                    .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                    .lineLimit(1)
            }

            Text(value)
                .font(ConsensusType.mono(size: 24, weight: .semibold))
                .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(ConsensusTheme.Spacing.lg)
        .frame(maxWidth: .infinity, minHeight: 94, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ConsensusTheme.Radius.md, style: .continuous)
                .fill(ConsensusTheme.Colors.surfaceSecondary.opacity(0.68))
                .overlay(
                    RoundedRectangle(cornerRadius: ConsensusTheme.Radius.md, style: .continuous)
                        .stroke(ConsensusTheme.Colors.border, lineWidth: 1)
                )
        )
    }
}

private struct LiveTranscriptRow: View {
    let index: Int
    let snippet: DeepReadViewModel.LiveTranscriptionSnippet

    var body: some View {
        HStack(alignment: .top, spacing: ConsensusTheme.Spacing.md) {
            Text(String(format: "%02d", index))
                .font(ConsensusType.monoTimestamp)
                .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                .frame(width: 28, alignment: .trailing)

            Text(snippet.text)
                .font(ConsensusType.transcriptBody)
                .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, ConsensusTheme.Spacing.sm)
        .padding(.horizontal, ConsensusTheme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: ConsensusTheme.Radius.md, style: .continuous)
                .fill(ConsensusTheme.Colors.surfacePrimary.opacity(0.56))
        )
    }
}

// MARK: - Generic progress view

/// A headline + detail + optional linear progress bar. Used for the
/// transitional stages until each gets its own dedicated view.
struct StageProgressView: View {
    let headline: String
    let detail: String
    let fraction: Double?

    var body: some View {
        VStack(spacing: ConsensusTheme.Spacing.lg) {
            Text(headline)
                .font(ConsensusType.displayHeading)
                .foregroundStyle(ConsensusTheme.Colors.textPrimary)
            Text(detail)
                .font(ConsensusType.displayCaption)
                .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)

            if let fraction {
                ProgressView(value: max(0, min(1, fraction)))
                    .progressViewStyle(.linear)
                    .tint(ConsensusTheme.Colors.accent)
                    .frame(width: 320)
                Text(String(format: "%.0f%%", fraction * 100))
                    .font(ConsensusType.monoMetric)
                    .foregroundStyle(ConsensusTheme.Colors.textTertiary)
            } else {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(ConsensusTheme.Colors.accent)
            }
        }
        .padding(ConsensusTheme.Spacing.xxl)
        .frame(maxWidth: 480, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: ConsensusTheme.Radius.xl, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: ConsensusTheme.Radius.xl, style: .continuous)
                        .stroke(ConsensusTheme.Colors.border, lineWidth: 1)
                )
        )
        .padding(ConsensusTheme.Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
