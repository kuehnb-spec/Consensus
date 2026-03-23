import SwiftUI

struct TranscriptionSetupView: View {
    @Environment(TranscriptionViewModel.self) private var viewModel

    var body: some View {
        @Bindable var vm = viewModel

        ScrollView {
            VStack(spacing: ConsensusTheme.Spacing.xl) {
                // Header
                VStack(spacing: ConsensusTheme.Spacing.sm) {
                    Text("Transcribe Audio")
                        .font(ConsensusTheme.Fonts.title)
                        .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                    Text("Local transcription with speaker identification")
                        .font(ConsensusTheme.Fonts.subtitle)
                        .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                }
                .padding(.top, ConsensusTheme.Spacing.sm)

                // Drop Zone
                AudioDropZone()
                    .padding(.horizontal)

                // Settings
                if viewModel.hasAudio {
                    settingsSection
                }

                // Progress / Transcribe Button
                if viewModel.pipeline.isRunning {
                    progressSection
                } else if viewModel.hasAudio {
                    transcribeButton
                }

                Spacer()
            }
            .padding(ConsensusTheme.Spacing.xl)
        }
        .onChange(of: viewModel.selectedModel) { _, _ in
            if viewModel.currentProject?.passes.isEmpty ?? true {
                viewModel.deepReviewModel = viewModel.selectedModel.recommendedDeepReviewModel
            }
            viewModel.persistProjectDraft()
        }
        .onChange(of: viewModel.minSpeakers) { _, _ in
            viewModel.persistProjectDraft()
        }
        .onChange(of: viewModel.maxSpeakers) { _, _ in
            viewModel.persistProjectDraft()
        }
    }

    private var settingsSection: some View {
        @Bindable var vm = viewModel

        return VStack(spacing: ConsensusTheme.Spacing.lg) {
            // Model picker
            HStack {
                VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xs) {
                    Text("Model")
                        .font(.headline)
                        .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                    Text(viewModel.selectedModel.description)
                        .font(ConsensusTheme.Fonts.caption)
                        .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                }
                Spacer()
                Picker("", selection: $vm.selectedModel) {
                    ForEach(WhisperModel.allCases) { model in
                        HStack {
                            Text(model.displayName)
                            Text(model.approximateSize)
                                .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                        }
                        .tag(model)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 200)
            }

            Divider()
                .overlay(ConsensusTheme.Colors.border)

            // Diarization engine
            HStack {
                VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xs) {
                    Text("Diarization Engine")
                        .font(.headline)
                        .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                    Text(viewModel.diarizationEngine == .speakerKit
                        ? "Newer pyannote v4 models, best accuracy"
                        : "Original engine, good for comparison"
                    )
                        .font(ConsensusTheme.Fonts.caption)
                        .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                }
                Spacer()
                Picker("", selection: $vm.diarizationEngine) {
                    ForEach(DiarizationEngine.allCases) { engine in
                        Text(engine.displayName)
                            .tag(engine)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 240)
            }

            Divider()
                .overlay(ConsensusTheme.Colors.border)

            // Speaker count
            HStack(spacing: ConsensusTheme.Spacing.xl) {
                VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xs) {
                    Text("Speakers")
                        .font(.headline)
                        .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                    Text("Set range for better accuracy (0 = auto)")
                        .font(ConsensusTheme.Fonts.caption)
                        .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                }
                Spacer()

                HStack(spacing: ConsensusTheme.Spacing.md) {
                    VStack(spacing: ConsensusTheme.Spacing.xs) {
                        Text("Min")
                            .font(ConsensusTheme.Fonts.mono(.caption2))
                            .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                        Stepper(value: $vm.minSpeakers, in: 0...20) {
                            Text("\(viewModel.minSpeakers)")
                                .font(ConsensusTheme.Fonts.mono(.body))
                                .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                                .frame(width: 24)
                        }
                    }

                    VStack(spacing: ConsensusTheme.Spacing.xs) {
                        Text("Max")
                            .font(ConsensusTheme.Fonts.mono(.caption2))
                            .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                        Stepper(value: $vm.maxSpeakers, in: 0...20) {
                            Text("\(viewModel.maxSpeakers)")
                                .font(ConsensusTheme.Fonts.mono(.body))
                                .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                                .frame(width: 24)
                        }
                    }
                }
            }
        }
        .consensusCard(label: "Settings", icon: "gearshape")
        .padding(.horizontal)
    }

    private var isIndeterminate: Bool {
        switch viewModel.pipeline.state {
        case .downloadingModel(let p) where p >= 1.0: return true
        case .diarizing, .mergingResults, .loadingAudio: return true
        default: return false
        }
    }

    private var progressSection: some View {
        VStack(spacing: ConsensusTheme.Spacing.md) {
            if isIndeterminate {
                ProgressView()
                    .progressViewStyle(.linear)
            } else {
                ProgressView(value: viewModel.pipelineProgress)
                    .progressViewStyle(.linear)
                    .tint(ConsensusTheme.Colors.accent)
            }

            Text(viewModel.statusMessage)
                .font(ConsensusTheme.Fonts.subheadline)
                .foregroundStyle(ConsensusTheme.Colors.textSecondary)

            if case .transcribing(_, let text) = viewModel.pipeline.state, let text {
                Text(text)
                    .font(ConsensusTheme.Fonts.caption)
                    .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button("Cancel", role: .cancel) {
                viewModel.cancelTranscription()
            }
            .buttonStyle(ConsensusSecondaryButtonStyle())
        }
        .padding(.horizontal)
    }

    private var transcribeButton: some View {
        Button {
            Task {
                await viewModel.startTranscription()
            }
        } label: {
            Label("Transcribe", systemImage: "waveform")
                .frame(maxWidth: 300)
        }
        .buttonStyle(ConsensusPrimaryButtonStyle())
        .controlSize(.large)
    }
}
