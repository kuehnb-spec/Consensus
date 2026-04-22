import SwiftUI

/// The top-level view of the rewritten UI. Routes on `DeepReadViewModel.stage`
/// to the stage-specific child view. Shown when `AppSettings.useRewrittenUI`
/// is true; the legacy `ContentView` surface is shown otherwise.
struct DeepReadRootView: View {
    @Bindable var viewModel: DeepReadViewModel
    @EnvironmentObject private var settings: AppSettings

    @State private var showingExportSheet: Bool = false
    @State private var showingInspector: Bool = false
    @State private var showingLibrary: Bool = false

    var body: some View {
        ZStack {
            ConsensusTheme.Colors.background
                .ignoresSafeArea()

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
                StageProgressView(
                    headline: "Transcribing",
                    detail: progress.label.isEmpty ? "Engine A pass in progress…" : progress.label,
                    fraction: progress.fraction
                )

            case .namingSpeakers(let suggestions):
                SpeakerNamingView(
                    viewModel: viewModel,
                    suggestions: suggestions
                )

            case .reconciling(let progress):
                StageProgressView(
                    headline: "Reconciling",
                    detail: progress.label.isEmpty ? "LLM pass in progress…" : progress.label,
                    fraction: progress.fraction
                )

            case .reviewing:
                DeepReadReviewView(viewModel: viewModel)

            case .exporting:
                PlaceholderStageView(
                    stage: "Export",
                    plan: "Phase 1d — format picker + include-summary checkbox."
                )
            }
        }
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
                viewModel.copyToPasteboard(format: .markdown)
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            Button("Copy as plain text") {
                viewModel.copyToPasteboard(format: .plainText)
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

            Button("Save as Markdown…") {
                _ = viewModel.exportToFile(format: .markdown)
            }
            .keyboardShortcut("e", modifiers: [.command])
            Button("Save as Obsidian Markdown…") {
                _ = viewModel.exportToFile(format: .obsidianMarkdown)
            }
            Button("Save as plain text…") {
                _ = viewModel.exportToFile(format: .plainText)
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
