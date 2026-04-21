import SwiftUI

/// The compact setup card shown after an audio file has been imported but
/// before transcription starts. Exposes the two Deep Read choices:
/// **Speed** (Quick / Deep) and **Include** (Summary, To-dos).
///
/// In Studio mode this view grows to surface additional knobs — tier picker,
/// engine selection, domain hint dropdown. Phase 1a ships the Deep Read
/// surface; Studio extensions land in Phase 3.
struct DeepReadSetupView: View {
    @Bindable var viewModel: DeepReadViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: ConsensusTheme.Spacing.xl) {
                if let project = viewModel.project {
                    audioSummaryCard(project: project)
                        .frame(maxWidth: 560)

                    setupCard(project: project)
                        .frame(maxWidth: 560)
                } else {
                    // Defensive — shouldn't happen in `.setup`
                    ProgressView()
                }
            }
            .padding(ConsensusTheme.Spacing.xxl)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Audio summary (what we just imported)

    private func audioSummaryCard(project: ProjectDocument) -> some View {
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xs) {
            HStack(spacing: ConsensusTheme.Spacing.sm) {
                Image(systemName: "waveform")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(ConsensusTheme.Colors.accent)

                VStack(alignment: .leading, spacing: 2) {
                    Text(project.title)
                        .font(ConsensusType.displaySubheading)
                        .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: ConsensusTheme.Spacing.sm) {
                        Text(formattedDuration(project.audio.durationSeconds))
                            .font(ConsensusType.monoMetric)
                        if let start = project.audio.recordingStartTime {
                            Text("·")
                                .foregroundStyle(ConsensusTheme.Colors.textMuted)
                            Text(formattedRecordingTime(start))
                                .font(ConsensusType.displayCaption)
                        }
                    }
                    .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                }

                Spacer()
            }
        }
        .padding(ConsensusTheme.Spacing.lg)
        .background(cardBackground)
    }

    // MARK: - Setup card (Speed + Include)

    private func setupCard(project: ProjectDocument) -> some View {
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.lg) {
            // Speed
            VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xs) {
                sectionHeader("Speed")
                speedPicker(current: project.settings.speed)
                Text(project.settings.speed.tagline)
                    .font(ConsensusType.displayCaption)
                    .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                    .animation(.easeInOut(duration: 0.15), value: project.settings.speed)
            }

            divider

            // Include
            VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xs) {
                sectionHeader("Include")
                includeToggles(settings: project.settings)
            }

            divider

            // Transcribe button
            HStack {
                Spacer()
                Button {
                    Task { await viewModel.startTranscription() }
                } label: {
                    HStack(spacing: ConsensusTheme.Spacing.xs) {
                        Text("Transcribe")
                            .font(ConsensusType.displayBody.weight(.semibold))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .padding(.horizontal, ConsensusTheme.Spacing.md)
                    .padding(.vertical, ConsensusTheme.Spacing.xs)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(ConsensusTheme.Colors.accent)
                .keyboardShortcut(.return, modifiers: [.command])
            }
        }
        .padding(ConsensusTheme.Spacing.lg)
        .background(cardBackground)
    }

    // MARK: - Setup card pieces

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(ConsensusType.displayEyebrow)
            .foregroundStyle(ConsensusTheme.Colors.textTertiary)
            .tracking(1.0)
    }

    private func speedPicker(current: SpeedTier) -> some View {
        // Deep Read exposes only two choices; Studio (Phase 3) will show all four.
        HStack(spacing: ConsensusTheme.Spacing.sm) {
            ForEach([SpeedTier.standard, SpeedTier.deep]) { tier in
                speedChip(tier: tier, selected: tier == current)
            }
        }
    }

    private func speedChip(tier: SpeedTier, selected: Bool) -> some View {
        Button {
            viewModel.setSpeed(tier)
        } label: {
            Text(tier.deepReadLabel)
                .font(ConsensusType.displayBody.weight(selected ? .semibold : .regular))
                .padding(.horizontal, ConsensusTheme.Spacing.md)
                .padding(.vertical, ConsensusTheme.Spacing.sm)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: ConsensusTheme.Radius.md, style: .continuous)
                        .fill(selected ? ConsensusTheme.Colors.accentSubtle : Color.clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: ConsensusTheme.Radius.md, style: .continuous)
                                .stroke(
                                    selected ? ConsensusTheme.Colors.accent : ConsensusTheme.Colors.border,
                                    lineWidth: selected ? 1.5 : 1
                                )
                        )
                )
                .foregroundStyle(
                    selected
                    ? ConsensusTheme.Colors.accent
                    : ConsensusTheme.Colors.textPrimary
                )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: selected)
    }

    private func includeToggles(settings: ProjectSettings) -> some View {
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xs) {
            toggleRow(
                label: "Summary",
                detail: "Editable summary in the right-side pane",
                isOn: Binding(
                    get: { settings.includeSummary },
                    set: { viewModel.setIncludeSummary($0) }
                )
            )
            toggleRow(
                label: "To-dos",
                detail: "Extracted action items, per-speaker",
                isOn: Binding(
                    get: { settings.includeTodos },
                    set: { viewModel.setIncludeTodos($0) }
                )
            )
        }
    }

    private func toggleRow(label: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: ConsensusTheme.Spacing.md) {
            Toggle(isOn: isOn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(ConsensusType.displayBody)
                        .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                    Text(detail)
                        .font(ConsensusType.displayCaption)
                        .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                }
            }
            .toggleStyle(.switch)
            .tint(ConsensusTheme.Colors.accent)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(ConsensusTheme.Colors.borderSubtle)
            .frame(height: 1)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: ConsensusTheme.Radius.lg, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: ConsensusTheme.Radius.lg, style: .continuous)
                    .stroke(ConsensusTheme.Colors.border, lineWidth: 1)
            )
    }

    // MARK: - Formatters

    private func formattedDuration(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    private func formattedRecordingTime(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt.string(from: date)
    }
}
