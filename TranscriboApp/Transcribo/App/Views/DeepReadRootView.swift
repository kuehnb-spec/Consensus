import SwiftUI

/// The top-level view of the rewritten UI. Routes on `DeepReadViewModel.stage`
/// to the stage-specific child view. Shown when `AppSettings.useRewrittenUI`
/// is true; the legacy `ContentView` surface is shown otherwise.
struct DeepReadRootView: View {
    @Bindable var viewModel: DeepReadViewModel
    @EnvironmentObject private var settings: AppSettings

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

            case .namingSpeakers:
                PlaceholderStageView(
                    stage: "Speaker naming",
                    plan: "Phase 1c — confirm auto-detected names, integrate voice library."
                )

            case .reconciling(let progress):
                StageProgressView(
                    headline: "Reconciling",
                    detail: progress.label.isEmpty ? "LLM pass in progress…" : progress.label,
                    fraction: progress.fraction
                )

            case .reviewing:
                PlaceholderStageView(
                    stage: "Interactive review",
                    plan: "Phase 1d — transcript + inline uncertainties + verbatim/clean toggle."
                )

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
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Text("Consensus")
                    .font(ConsensusType.displayHeading)
                    .foregroundStyle(ConsensusTheme.Colors.textPrimary)
            }
            if viewModel.project != nil {
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
