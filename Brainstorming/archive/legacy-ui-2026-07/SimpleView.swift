import SwiftUI

/// Simple Mode: a single-screen, zero-configuration transcription interface.
/// Light theme, no sidebar, no numbered steps. Drop audio, transcribe, export.
struct SimpleView: View {
    @Environment(TranscriptionViewModel.self) private var viewModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        @Bindable var vm = viewModel

        VStack(spacing: 0) {
            // Top bar with mode toggle
            topBar

            // Main content area
            ZStack {
                ConsensusTheme.LightColors.background
                    .ignoresSafeArea()

                if viewModel.hasResult {
                    transcriptBody
                } else if viewModel.pipeline.isRunning {
                    progressBody
                } else {
                    dropZoneBody
                }
            }

            // Bottom action bar
            actionBar
        }
        .fileImporter(
            isPresented: $vm.showFilePicker,
            allowedContentTypes: [.audio, .mpeg4Audio, .mp3, .wav, .aiff],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task { await viewModel.importAudio(url: url) }
            }
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: ConsensusTheme.Spacing.md) {
            Text("Consensus")
                .font(.headline.weight(.semibold))
                .foregroundStyle(ConsensusTheme.LightColors.textPrimary)

            if let project = viewModel.currentProject {
                Text(project.name)
                    .font(.subheadline)
                    .foregroundStyle(ConsensusTheme.LightColors.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            // Mode toggle
            Button {
                withAnimation(.snappy(duration: 0.3)) {
                    settings.isSimpleMode = false
                }
            } label: {
                HStack(spacing: ConsensusTheme.Spacing.xs) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.caption)
                    Text("Advanced")
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(ConsensusTheme.LightColors.textSecondary)
                .padding(.horizontal, ConsensusTheme.Spacing.sm)
                .padding(.vertical, ConsensusTheme.Spacing.xs)
                .background {
                    Capsule()
                        .fill(ConsensusTheme.LightColors.surfaceSecondary)
                        .overlay {
                            Capsule().stroke(ConsensusTheme.LightColors.border, lineWidth: 1)
                        }
                }
            }
            .buttonStyle(.plain)
            .help("Switch to Advanced mode for full control over models, quality metrics, and export options")
        }
        .padding(.horizontal, ConsensusTheme.Spacing.xl)
        .padding(.vertical, ConsensusTheme.Spacing.md)
        .background(ConsensusTheme.LightColors.surfacePrimary)
        .overlay(alignment: .bottom) {
            Divider().overlay(ConsensusTheme.LightColors.border)
        }
    }

    // MARK: - Drop Zone (No Audio Loaded)

    private var dropZoneBody: some View {
        VStack(spacing: ConsensusTheme.Spacing.xl) {
            Spacer()

            Image(systemName: "waveform.circle")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(ConsensusTheme.LightColors.accent.opacity(0.4))

            VStack(spacing: ConsensusTheme.Spacing.sm) {
                Text("Drop an audio file to transcribe")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(ConsensusTheme.LightColors.textPrimary)

                Text("M4A, MP3, WAV, or AIFF")
                    .font(.subheadline)
                    .foregroundStyle(ConsensusTheme.LightColors.textTertiary)
            }

            Button {
                viewModel.showFilePicker = true
            } label: {
                HStack(spacing: ConsensusTheme.Spacing.sm) {
                    Image(systemName: "folder")
                    Text("Browse Files")
                }
                .font(.body.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, ConsensusTheme.Spacing.xl)
                .padding(.vertical, ConsensusTheme.Spacing.md)
                .background(ConsensusTheme.LightColors.accent, in: RoundedRectangle(cornerRadius: ConsensusTheme.Radius.md))
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [.audio, .fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
            return true
        }
    }

    // MARK: - Progress (Transcribing)

    private var progressBody: some View {
        VStack(spacing: ConsensusTheme.Spacing.xl) {
            Spacer()

            ProgressView()
                .controlSize(.large)
                .tint(ConsensusTheme.LightColors.accent)

            VStack(spacing: ConsensusTheme.Spacing.sm) {
                Text(progressTitle)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(ConsensusTheme.LightColors.textPrimary)

                if case .transcribing(let progress, _) = viewModel.pipeline.state {
                    ProgressView(value: progress)
                        .tint(ConsensusTheme.LightColors.accent)
                        .frame(maxWidth: 300)

                    Text("\(Int(progress * 100))%")
                        .font(ConsensusTheme.Fonts.mono(.caption))
                        .foregroundStyle(ConsensusTheme.LightColors.textTertiary)
                }

                if case .transcribing(_, let text) = viewModel.pipeline.state, let text {
                    Text(text.suffix(100))
                        .font(.caption)
                        .foregroundStyle(ConsensusTheme.LightColors.textTertiary)
                        .lineLimit(2)
                        .frame(maxWidth: 400)
                }
            }

            Button("Cancel") {
                viewModel.cancelTranscription()
            }
            .font(.subheadline)
            .foregroundStyle(ConsensusTheme.LightColors.textSecondary)
            .buttonStyle(.plain)

            Spacer()
        }
    }

    // MARK: - Transcript Body

    private var transcriptBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let result = viewModel.result {
                    // File info header
                    HStack(spacing: ConsensusTheme.Spacing.sm) {
                        Text(result.audioFileName)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(ConsensusTheme.LightColors.textSecondary)
                        Text(TimeFormatting.durationDisplay(result.duration))
                            .font(ConsensusTheme.Fonts.mono(.caption))
                            .foregroundStyle(ConsensusTheme.LightColors.textTertiary)
                        Text("\(result.speakerCount) speakers")
                            .font(.caption)
                            .foregroundStyle(ConsensusTheme.LightColors.textTertiary)
                    }
                    .padding(.bottom, ConsensusTheme.Spacing.lg)

                    // Transcript text formatted as a document
                    let speakers = result.detectedSpeakers
                    let segments = result.segments

                    ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                        let displayName = viewModel.speakerMapping.displayName(for: segment.speakerID)
                        let isNewSpeaker = index == 0 || segment.speakerID != segments[index - 1].speakerID

                        if isNewSpeaker {
                            // Speaker header
                            HStack(alignment: .firstTextBaseline, spacing: ConsensusTheme.Spacing.sm) {
                                Text(displayName.uppercased())
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(SpeakerBadge.color(for: segment.speakerID, in: speakers))
                                    .tracking(0.5)

                                Text(TimeFormatting.timestamp(segment.start))
                                    .font(ConsensusTheme.Fonts.mono(.caption2))
                                    .foregroundStyle(ConsensusTheme.LightColors.textTertiary)
                            }
                            .padding(.top, index == 0 ? 0 : ConsensusTheme.Spacing.lg)
                            .padding(.bottom, ConsensusTheme.Spacing.xs)
                        }

                        // Segment text
                        Text(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))
                            .font(.body)
                            .foregroundStyle(ConsensusTheme.LightColors.textPrimary)
                            .lineSpacing(5)
                            .textSelection(.enabled)
                    }

                    // Inline speaker rename section
                    if !result.detectedSpeakers.isEmpty {
                        Divider()
                            .padding(.vertical, ConsensusTheme.Spacing.xl)

                        Text("SPEAKERS")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(ConsensusTheme.LightColors.textTertiary)
                            .tracking(1)
                            .padding(.bottom, ConsensusTheme.Spacing.sm)

                        ForEach(Array(result.detectedSpeakers.enumerated()), id: \.element) { idx, speakerID in
                            SimpleSpeakerRow(
                                speakerID: speakerID,
                                color: SpeakerBadge.color(for: idx),
                                currentName: viewModel.speakerMapping.names[speakerID] ?? "",
                                sampleQuote: viewModel.speakerSamples[speakerID] ?? "",
                                onRename: { name in
                                    viewModel.renameSpeaker(speakerID, to: name)
                                }
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, ConsensusTheme.Spacing.xxl)
            .padding(.vertical, ConsensusTheme.Spacing.xl)
        }
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack(spacing: ConsensusTheme.Spacing.lg) {
            if viewModel.hasResult {
                // Left: status
                HStack(spacing: ConsensusTheme.Spacing.sm) {
                    Image(systemName: viewModel.hasConsensusPass ? "checkmark.seal.fill" : "checkmark.circle")
                        .foregroundStyle(viewModel.hasConsensusPass
                            ? ConsensusTheme.LightColors.confidenceGreen
                            : ConsensusTheme.LightColors.accent)

                    Text(statusText)
                        .font(.subheadline)
                        .foregroundStyle(ConsensusTheme.LightColors.textSecondary)
                }

                Spacer()

                // Right: actions
                if !viewModel.hasConsensusPass && !viewModel.pipeline.isRunning {
                    Button {
                        Task { await viewModel.startDeepTranscription() }
                    } label: {
                        HStack(spacing: ConsensusTheme.Spacing.xs) {
                            Image(systemName: "sparkle.magnifyingglass")
                            Text("Deep Review")
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(ConsensusTheme.LightColors.accent)
                        .padding(.horizontal, ConsensusTheme.Spacing.lg)
                        .padding(.vertical, ConsensusTheme.Spacing.sm)
                        .background {
                            RoundedRectangle(cornerRadius: ConsensusTheme.Radius.md)
                                .stroke(ConsensusTheme.LightColors.accent.opacity(0.3), lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isCleanupRunning)
                }

                Button {
                    viewModel.currentPhase = .export
                    settings.isSimpleMode = false // Export uses Advanced mode views
                } label: {
                    HStack(spacing: ConsensusTheme.Spacing.xs) {
                        Image(systemName: "square.and.arrow.up")
                        Text("Export")
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, ConsensusTheme.Spacing.lg)
                    .padding(.vertical, ConsensusTheme.Spacing.sm)
                    .background(ConsensusTheme.LightColors.accent, in: RoundedRectangle(cornerRadius: ConsensusTheme.Radius.md))
                }
                .buttonStyle(.plain)

            } else if !viewModel.pipeline.isRunning && viewModel.hasAudio {
                Spacer()

                Button {
                    Task { await viewModel.startTranscription() }
                } label: {
                    HStack(spacing: ConsensusTheme.Spacing.xs) {
                        Image(systemName: "waveform")
                        Text("Transcribe")
                    }
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, ConsensusTheme.Spacing.xxl)
                    .padding(.vertical, ConsensusTheme.Spacing.md)
                    .background(ConsensusTheme.LightColors.accent, in: RoundedRectangle(cornerRadius: ConsensusTheme.Radius.md))
                }
                .buttonStyle(.plain)
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, ConsensusTheme.Spacing.xl)
        .padding(.vertical, ConsensusTheme.Spacing.md)
        .background(ConsensusTheme.LightColors.surfacePrimary)
        .overlay(alignment: .top) {
            Divider().overlay(ConsensusTheme.LightColors.border)
        }
    }

    // MARK: - Helpers

    private var progressTitle: String {
        switch viewModel.pipeline.state {
        case .loadingAudio: return "Loading audio..."
        case .downloadingModel(let progress):
            return progress < 1.0 ? "Downloading model... \(Int(progress * 100))%" : "Model ready"
        case .transcribing: return "Transcribing..."
        case .diarizing: return "Identifying speakers..."
        case .mergingResults: return "Finalizing..."
        default: return "Processing..."
        }
    }

    private var statusText: String {
        if viewModel.hasConsensusPass { return "Verified transcript" }
        if viewModel.hasMultiplePasses { return "Verification complete" }
        return "Transcript ready"
    }

    private func handleDrop(providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url") { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }

                let audioExtensions = ["m4a", "mp3", "wav", "aiff", "aif", "flac"]
                guard audioExtensions.contains(url.pathExtension.lowercased()) else { return }

                Task { @MainActor in
                    await viewModel.importAudio(url: url)
                }
            }
        }
    }
}

// MARK: - Simple Speaker Rename Row

private struct SimpleSpeakerRow: View {
    let speakerID: String
    let color: Color
    let currentName: String
    let sampleQuote: String
    let onRename: (String) -> Void

    @State private var editedName: String = ""

    var body: some View {
        HStack(spacing: ConsensusTheme.Spacing.md) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)

            Text(speakerID)
                .font(.caption.weight(.medium))
                .foregroundStyle(ConsensusTheme.LightColors.textTertiary)
                .frame(width: 80, alignment: .leading)

            TextField("Name this speaker...", text: $editedName)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .foregroundStyle(ConsensusTheme.LightColors.textPrimary)
                .onSubmit {
                    let trimmed = editedName.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { onRename(trimmed) }
                }

            if !sampleQuote.isEmpty {
                Text("\"\(sampleQuote.prefix(60))...\"")
                    .font(.caption)
                    .foregroundStyle(ConsensusTheme.LightColors.textTertiary)
                    .lineLimit(1)
                    .frame(maxWidth: 250, alignment: .leading)
            }
        }
        .padding(.vertical, ConsensusTheme.Spacing.xs)
        .onAppear { editedName = currentName }
    }
}
