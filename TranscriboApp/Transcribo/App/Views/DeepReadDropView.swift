import SwiftUI
import UniformTypeIdentifiers

/// The idle screen for the rewritten UI. Presents a centred drop target
/// plus an explicit "Choose audio file…" button, with the Consensus
/// wordmark and a single-line privacy reassurance.
///
/// Shown when `DeepReadViewModel.stage == .idle`.
struct DeepReadDropView: View {
    let viewModel: DeepReadViewModel

    @State private var isTargeted: Bool = false

    var body: some View {
        VStack(spacing: ConsensusTheme.Spacing.xxl) {
            Spacer(minLength: ConsensusTheme.Spacing.xxl)

            // Wordmark + tagline
            VStack(spacing: ConsensusTheme.Spacing.sm) {
                Image(systemName: "waveform")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(ConsensusTheme.Colors.accent)
                    .padding(.bottom, ConsensusTheme.Spacing.xs)

                Text("Consensus")
                    .font(ConsensusType.display(size: 34, weight: .semibold))
                    .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                    .tracking(-0.5)

                Text("Privacy-first transcription with speaker diarization.")
                    .font(ConsensusType.displayBody)
                    .foregroundStyle(ConsensusTheme.Colors.textSecondary)
            }

            // Drop zone card
            dropCard
                .frame(width: 520, height: 240)

            Spacer(minLength: ConsensusTheme.Spacing.lg)

            // Footer
            HStack(spacing: ConsensusTheme.Spacing.sm) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 12, weight: .regular))
                Text("All processing happens on this device.")
                    .font(ConsensusType.displayCaption)
            }
            .foregroundStyle(ConsensusTheme.Colors.textTertiary)
            .padding(.bottom, ConsensusTheme.Spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Drop card

    private var dropCard: some View {
        VStack(spacing: ConsensusTheme.Spacing.lg) {
            Image(systemName: isTargeted ? "arrow.down.circle.fill" : "arrow.down.to.line")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(iconColor)
                .contentTransition(.symbolEffect(.replace))

            VStack(spacing: ConsensusTheme.Spacing.xs) {
                Text(isTargeted ? "Release to import" : "Drop audio to begin")
                    .font(ConsensusType.displaySubheading)
                    .foregroundStyle(isTargeted ? ConsensusTheme.Colors.accent : ConsensusTheme.Colors.textPrimary)

                Text("Phone call, interview, meeting. M4A, MP3, WAV, AIFF.")
                    .font(ConsensusType.displayCaption)
                    .foregroundStyle(ConsensusTheme.Colors.textTertiary)
            }

            Button {
                viewModel.showFilePicker = true
            } label: {
                Label("Choose audio file…", systemImage: "folder")
                    .font(ConsensusType.displayBody.weight(.medium))
                    .padding(.horizontal, ConsensusTheme.Spacing.md)
                    .padding(.vertical, ConsensusTheme.Spacing.xs)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(ConsensusTheme.Colors.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(cardBackground)
        .animation(.easeInOut(duration: 0.15), value: isTargeted)
        .onDrop(of: supportedTypes, isTargeted: $isTargeted) { providers in
            handleDrop(providers)
        }
    }

    private var iconColor: Color {
        isTargeted ? ConsensusTheme.Colors.accent : ConsensusTheme.Colors.textTertiary
    }

    @ViewBuilder
    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: ConsensusTheme.Radius.xl, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: ConsensusTheme.Radius.xl, style: .continuous)
                    .stroke(
                        isTargeted ? ConsensusTheme.Colors.accent : ConsensusTheme.Colors.border,
                        style: StrokeStyle(
                            lineWidth: isTargeted ? 2 : 1,
                            dash: isTargeted ? [] : [8, 6]
                        )
                    )
            )
    }

    // MARK: - Drop handling

    private var supportedTypes: [UTType] {
        [.audio, .mpeg4Audio, .mp3, .wav, .aiff, .fileURL]
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in
                await viewModel.beginImport(from: url)
            }
        }
        return true
    }
}
