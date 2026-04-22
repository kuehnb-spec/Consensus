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
        ScrollView {
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

                // Recent projects — only shown when there is at least one
                if !viewModel.library.index.isEmpty {
                    recentProjectsSection
                        .frame(maxWidth: 520)
                }

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
        .task {
            await viewModel.refreshRecentProjects()
        }
    }

    // MARK: - Recent projects

    private var recentProjectsSection: some View {
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.sm) {
            Text("RECENT")
                .font(ConsensusType.displayEyebrow)
                .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                .tracking(1.0)

            VStack(spacing: ConsensusTheme.Spacing.xs) {
                ForEach(viewModel.library.index.prefix(5)) { entry in
                    recentProjectRow(entry: entry)
                }
            }
        }
    }

    private func recentProjectRow(entry: ProjectLibrary.ProjectIndexEntry) -> some View {
        Button {
            Task { await viewModel.openProject(entry.id) }
        } label: {
            HStack(spacing: ConsensusTheme.Spacing.md) {
                Image(systemName: "waveform.circle")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(ConsensusTheme.Colors.accent)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .font(ConsensusType.displayBody.weight(.medium))
                        .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: ConsensusTheme.Spacing.xs) {
                        Text(Self.formatDuration(entry.durationSeconds))
                            .font(ConsensusType.monoMetric)
                        Text("·")
                            .foregroundStyle(ConsensusTheme.Colors.textMuted)
                        Text(Self.relative(entry.updatedAt))
                            .font(ConsensusType.displayCaption)
                        if !entry.speakerNames.isEmpty {
                            Text("·")
                                .foregroundStyle(ConsensusTheme.Colors.textMuted)
                            Text(entry.speakerNames.prefix(3).joined(separator: ", "))
                                .font(ConsensusType.displayCaption)
                                .lineLimit(1)
                        }
                    }
                    .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(ConsensusTheme.Colors.textTertiary)
            }
            .padding(.horizontal, ConsensusTheme.Spacing.md)
            .padding(.vertical, ConsensusTheme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: ConsensusTheme.Radius.md, style: .continuous)
                    .fill(ConsensusTheme.Colors.surfaceSecondary.opacity(0.5))
                    .overlay(
                        RoundedRectangle(cornerRadius: ConsensusTheme.Radius.md, style: .continuous)
                            .stroke(ConsensusTheme.Colors.borderSubtle, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    private static func relative(_ date: Date) -> String {
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .short
        return fmt.localizedString(for: date, relativeTo: Date())
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
