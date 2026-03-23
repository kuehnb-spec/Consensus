import SwiftUI
import UniformTypeIdentifiers

struct AudioDropZone: View {
    @Environment(TranscriptionViewModel.self) private var viewModel
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: ConsensusTheme.Spacing.lg) {
            if let url = viewModel.audioFileURL {
                // File loaded state
                HStack(spacing: ConsensusTheme.Spacing.md) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(ConsensusTheme.Colors.accent)

                    VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xs) {
                        Text(viewModel.audioFileName)
                            .font(.headline)
                            .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                        Text(TimeFormatting.durationDisplay(viewModel.audioDuration))
                            .font(ConsensusTheme.Fonts.mono(.subheadline))
                            .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                        Text(url.lastPathComponent)
                            .font(ConsensusTheme.Fonts.caption)
                            .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                    }

                    Spacer()

                    Button {
                        viewModel.showFilePicker = true
                    } label: {
                        Label("Change", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(ConsensusSecondaryButtonStyle())
                }
                .padding(ConsensusTheme.Spacing.xl)
                .background {
                    RoundedRectangle(cornerRadius: ConsensusTheme.Radius.lg)
                        .fill(ConsensusTheme.Colors.surfacePrimary)
                        .overlay {
                            RoundedRectangle(cornerRadius: ConsensusTheme.Radius.lg)
                                .stroke(ConsensusTheme.Colors.border, lineWidth: 1)
                        }
                }
            } else {
                // Empty drop zone
                VStack(spacing: ConsensusTheme.Spacing.md) {
                    Image(systemName: "waveform.badge.plus")
                        .font(.system(size: 44))
                        .foregroundStyle(isTargeted ? ConsensusTheme.Colors.accent : ConsensusTheme.Colors.textTertiary)

                    Text("Drop an audio file here")
                        .font(.title3)
                        .foregroundStyle(isTargeted ? ConsensusTheme.Colors.textPrimary : ConsensusTheme.Colors.textSecondary)

                    Text("or")
                        .font(ConsensusTheme.Fonts.caption)
                        .foregroundStyle(ConsensusTheme.Colors.textTertiary)

                    Button {
                        viewModel.showFilePicker = true
                    } label: {
                        Label("Browse Files", systemImage: "folder")
                    }
                    .buttonStyle(ConsensusSecondaryButtonStyle())

                    Text("Supports M4A, MP3, WAV, AIFF, FLAC, and more")
                        .font(ConsensusTheme.Fonts.caption)
                        .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(40)
                .background(
                    RoundedRectangle(cornerRadius: ConsensusTheme.Radius.lg)
                        .strokeBorder(
                            isTargeted ? ConsensusTheme.Colors.accent : ConsensusTheme.Colors.textMuted,
                            style: StrokeStyle(lineWidth: 2, dash: [8, 4])
                        )
                )
                .background(
                    isTargeted ? ConsensusTheme.Colors.accentMuted : Color.clear,
                    in: RoundedRectangle(cornerRadius: ConsensusTheme.Radius.lg)
                )
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers: providers)
        }
        .animation(.easeInOut(duration: 0.2), value: isTargeted)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }

            if AudioFileValidator.isSupported(url) {
                Task { @MainActor in
                    await viewModel.importAudio(url: url)
                }
            }
        }
        return true
    }
}
