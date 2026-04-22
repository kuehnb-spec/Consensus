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
                if project.mode != .studio {
                    // Studio tier rows already surface the tagline; don't
                    // echo it underneath.
                    Text(project.settings.speed.tagline)
                        .font(ConsensusType.displayCaption)
                        .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                        .animation(.easeInOut(duration: 0.15), value: project.settings.speed)
                }
            }

            divider

            // Domain hint — Studio-only
            if project.mode == .studio {
                VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xs) {
                    sectionHeader("Domain")
                    domainPicker(current: project.settings.domainHint)
                }

                divider
            }

            // Include
            VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xs) {
                sectionHeader("Include")
                includeToggles(settings: project.settings)

                // Studio adds advanced summary knobs when summary is on
                if project.mode == .studio && project.settings.includeSummary {
                    summaryAdvanced(project: project)
                        .padding(.top, ConsensusTheme.Spacing.sm)
                }
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
        // Deep Read exposes two choices (Quick / Deep). Studio exposes all
        // four tiers with the fuller labels.
        let tiers: [SpeedTier] = (viewModel.project?.mode == .studio)
            ? [.standard, .deep, .verified, .perfect]
            : [.standard, .deep]

        return VStack(spacing: ConsensusTheme.Spacing.sm) {
            if tiers.count <= 2 {
                HStack(spacing: ConsensusTheme.Spacing.sm) {
                    ForEach(tiers) { tier in
                        speedChip(tier: tier, selected: tier == current)
                    }
                }
            } else {
                // Studio tier picker — vertical stack with the Studio label.
                VStack(spacing: ConsensusTheme.Spacing.xs) {
                    ForEach(tiers) { tier in
                        studioTierRow(tier: tier, selected: tier == current)
                    }
                }
            }
        }
    }

    private func studioTierRow(tier: SpeedTier, selected: Bool) -> some View {
        Button {
            viewModel.setSpeed(tier)
        } label: {
            HStack(spacing: ConsensusTheme.Spacing.md) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(
                        selected ? ConsensusTheme.Colors.accent : ConsensusTheme.Colors.textTertiary
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(tier.studioLabel)
                        .font(ConsensusType.displayBody.weight(selected ? .semibold : .regular))
                        .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                    Text(tier.tagline)
                        .font(ConsensusType.displayCaption)
                        .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                }

                Spacer()
            }
            .padding(.horizontal, ConsensusTheme.Spacing.md)
            .padding(.vertical, ConsensusTheme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: ConsensusTheme.Radius.md, style: .continuous)
                    .fill(
                        selected
                        ? ConsensusTheme.Colors.accentSubtle
                        : ConsensusTheme.Colors.surfaceSecondary.opacity(0.3)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: ConsensusTheme.Radius.md, style: .continuous)
                            .stroke(
                                selected ? ConsensusTheme.Colors.accent : ConsensusTheme.Colors.borderSubtle,
                                lineWidth: selected ? 1.5 : 1
                            )
                    )
            )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.12), value: selected)
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

    // MARK: - Studio sections

    private func domainPicker(current: DomainHint) -> some View {
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xs) {
            HStack(spacing: ConsensusTheme.Spacing.xs) {
                ForEach(DomainHint.presets, id: \.promptToken) { preset in
                    domainChip(preset: preset, selected: isSelected(current: current, preset: preset))
                }
            }

            if case .custom(let text) = current {
                TextField("Custom domain hint", text: Binding(
                    get: { text },
                    set: { viewModel.setDomainHint(.custom($0)) }
                ))
                .textFieldStyle(.roundedBorder)
                .font(ConsensusType.displayBody)
            } else {
                Button {
                    viewModel.setDomainHint(.custom(""))
                } label: {
                    Text("Custom…")
                        .font(ConsensusType.displayCaption)
                        .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func domainChip(preset: DomainHint, selected: Bool) -> some View {
        Button {
            viewModel.setDomainHint(preset)
        } label: {
            Text(Self.domainLabel(preset))
                .font(ConsensusType.displayCaption.weight(selected ? .semibold : .regular))
                .padding(.horizontal, ConsensusTheme.Spacing.sm)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(selected ? ConsensusTheme.Colors.accentSubtle : Color.clear)
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(
                                    selected ? ConsensusTheme.Colors.accent : ConsensusTheme.Colors.border,
                                    lineWidth: selected ? 1.5 : 1
                                )
                        )
                )
                .foregroundStyle(
                    selected ? ConsensusTheme.Colors.accent : ConsensusTheme.Colors.textPrimary
                )
        }
        .buttonStyle(.plain)
    }

    private func isSelected(current: DomainHint, preset: DomainHint) -> Bool {
        switch (current, preset) {
        case (.general, .general),
             (.legal, .legal),
             (.medical, .medical),
             (.technical, .technical),
             (.business, .business):
            return true
        default:
            return false
        }
    }

    private static func domainLabel(_ hint: DomainHint) -> String {
        switch hint {
        case .general: return "General"
        case .legal: return "Legal"
        case .medical: return "Medical"
        case .technical: return "Technical"
        case .business: return "Business"
        case .custom(let t): return t.isEmpty ? "Custom" : t
        }
    }

    private func summaryAdvanced(project: ProjectDocument) -> some View {
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.sm) {
            HStack(spacing: ConsensusTheme.Spacing.xs) {
                Text("Summary length")
                    .font(ConsensusType.displayCaption)
                    .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                Spacer()
                Picker("", selection: Binding(
                    get: { viewModel.summary.length },
                    set: { viewModel.setSummaryLength($0) }
                )) {
                    ForEach(SummaryLength.allCases, id: \.self) { length in
                        Text(length.displayName).tag(length)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
            }

            VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xs) {
                Text("Special instructions")
                    .font(ConsensusType.displayCaption)
                    .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                TextField(
                    "e.g. Focus on financial commitments, exclude small talk",
                    text: Binding(
                        get: { viewModel.summary.specialInstructions },
                        set: { viewModel.setSummarySpecialInstructions($0) }
                    ),
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .font(ConsensusType.displayBody)
                .lineLimit(2...4)
            }
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
