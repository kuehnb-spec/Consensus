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

                // Template picker
                TemplatePicker(viewModel: viewModel)
                    .padding(.horizontal)

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
            // Transcription engine picker
            HStack {
                VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xs) {
                    Text("Transcription Engine")
                        .font(.headline)
                        .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                    Text(viewModel.primaryEngine.description)
                        .font(ConsensusTheme.Fonts.caption)
                        .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                }
                Spacer()
                Picker("", selection: $vm.primaryEngine) {
                    ForEach(TranscriptionViewModel.PrimaryEngine.allCases) { engine in
                        Text(engine.rawValue).tag(engine)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 200)
            }

            // Whisper model size (only shown when WhisperKit is selected)
            if viewModel.primaryEngine == .whisper {
                HStack {
                    VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xs) {
                        Text("Model Size")
                            .font(.subheadline.weight(.medium))
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
                .padding(.leading, ConsensusTheme.Spacing.lg)
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

// MARK: - Template Picker

private struct TemplatePicker: View {
    let viewModel: TranscriptionViewModel
    @EnvironmentObject private var settings: AppSettings
    @State private var selectedTemplateID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.sm) {
            Text("PRESETS")
                .font(ConsensusTheme.Fonts.mono(size: 9, weight: .bold))
                .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                .tracking(0.5)

            HStack(spacing: ConsensusTheme.Spacing.sm) {
                ForEach(settings.projectTemplates) { template in
                    let isSelected = selectedTemplateID == template.id

                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            selectedTemplateID = template.id
                        }
                        applyTemplate(template)
                    } label: {
                        VStack(spacing: 3) {
                            Text(template.name)
                                .font(.caption.weight(isSelected ? .bold : .medium))
                                .foregroundStyle(isSelected ? ConsensusTheme.Colors.accent : ConsensusTheme.Colors.textPrimary)
                            Text(template.minSpeakers == 0 ? "auto" : "\(template.minSpeakers)-\(template.maxSpeakers) spk")
                                .font(ConsensusTheme.Fonts.mono(size: 9))
                                .foregroundStyle(isSelected ? ConsensusTheme.Colors.accent.opacity(0.7) : ConsensusTheme.Colors.textTertiary)
                        }
                        .padding(.horizontal, ConsensusTheme.Spacing.md)
                        .padding(.vertical, ConsensusTheme.Spacing.sm)
                        .background {
                            ZStack {
                                RoundedRectangle(cornerRadius: ConsensusTheme.Radius.md)
                                    .fill(isSelected
                                        ? ConsensusTheme.Colors.accent.opacity(0.08)
                                        : ConsensusTheme.Colors.surfaceSecondary
                                    )

                                if isSelected {
                                    // Gradient glow border
                                    RoundedRectangle(cornerRadius: ConsensusTheme.Radius.md)
                                        .stroke(
                                            LinearGradient(
                                                colors: [
                                                    ConsensusTheme.Colors.accent,
                                                    ConsensusTheme.Colors.accent.opacity(0.5),
                                                    Color(red: 0.30, green: 0.60, blue: 0.98),
                                                    ConsensusTheme.Colors.accent.opacity(0.5),
                                                    ConsensusTheme.Colors.accent,
                                                ],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            ),
                                            lineWidth: 1.5
                                        )

                                    // Subtle outer glow
                                    RoundedRectangle(cornerRadius: ConsensusTheme.Radius.md + 2)
                                        .stroke(ConsensusTheme.Colors.accent.opacity(0.15), lineWidth: 3)
                                        .blur(radius: 2)
                                } else {
                                    RoundedRectangle(cornerRadius: ConsensusTheme.Radius.md)
                                        .stroke(ConsensusTheme.Colors.border, lineWidth: 1)
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        // Deselect preset if the user manually changes speaker counts
        .onChange(of: viewModel.minSpeakers) { _, _ in
            if !isCurrentTemplateMatch() { selectedTemplateID = nil }
        }
        .onChange(of: viewModel.maxSpeakers) { _, _ in
            if !isCurrentTemplateMatch() { selectedTemplateID = nil }
        }
    }

    private func applyTemplate(_ template: ProjectTemplate) {
        if let model = WhisperModel(rawValue: template.model) {
            viewModel.selectedModel = model
        }
        viewModel.minSpeakers = template.minSpeakers
        viewModel.maxSpeakers = template.maxSpeakers
        viewModel.language = template.language
    }

    /// Check if current settings still match the selected template.
    private func isCurrentTemplateMatch() -> Bool {
        guard let id = selectedTemplateID,
              let template = settings.projectTemplates.first(where: { $0.id == id }) else {
            return false
        }
        return viewModel.minSpeakers == template.minSpeakers
            && viewModel.maxSpeakers == template.maxSpeakers
    }
}
