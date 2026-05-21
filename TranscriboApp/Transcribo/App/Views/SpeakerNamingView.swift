import SwiftUI

/// Shown after transcription completes. Lets the user confirm or rename the
/// auto-detected speakers before dropping into the review view. Phase 1c.1
/// presents the raw diarizer output (Speaker 1, Speaker 2, …) with text
/// fields; Phase 1c.2 will pre-fill from "Hi, this is X" intros and voice
/// library matches, and surface per-speaker audio samples.
struct SpeakerNamingView: View {
    let viewModel: DeepReadViewModel
    let initialSuggestions: [DeepReadViewModel.SpeakerSuggestion]

    @State private var workingSuggestions: [DeepReadViewModel.SpeakerSuggestion]
    @State private var evidenceSpeakerID: String?
    @FocusState private var focusedID: String?

    /// How many sample utterances are visible per speaker before the user
    /// expands. Three matches the original "compact intro" feel.
    private let previewSampleCount = 3
    /// How many sample utterances are visible in the evidence inspector.
    private let evidenceSampleCount = 18

    init(
        viewModel: DeepReadViewModel,
        suggestions: [DeepReadViewModel.SpeakerSuggestion]
    ) {
        self.viewModel = viewModel
        self.initialSuggestions = suggestions
        self._workingSuggestions = State(initialValue: suggestions)
    }

    var body: some View {
        GeometryReader { geometry in
            let usesSidePane = geometry.size.width >= 960

            Group {
                if usesSidePane {
                    HStack(alignment: .top, spacing: ConsensusTheme.Spacing.xl) {
                        namingColumn

                        if selectedEvidenceSuggestion != nil {
                            evidencePanel
                                .frame(width: 360)
                                .frame(maxHeight: .infinity, alignment: .top)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else {
                    ScrollView {
                        VStack(spacing: ConsensusTheme.Spacing.xl) {
                            namingColumn
                            if selectedEvidenceSuggestion != nil {
                                evidencePanel
                                    .frame(maxWidth: 560)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .scrollIndicators(.visible)
                }
            }
            .padding(ConsensusTheme.Spacing.xxl)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .onAppear {
            // Auto-focus the first field so the user can start typing
            focusedID = workingSuggestions.first?.id
        }
    }

    private var namingColumn: some View {
        VStack(spacing: ConsensusTheme.Spacing.xl) {
            header
            speakerList
            footerActions
        }
        .frame(maxWidth: 560, maxHeight: .infinity)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: ConsensusTheme.Spacing.xs) {
            Text("Who's speaking?")
                .font(ConsensusType.display(size: 24, weight: .semibold))
                .foregroundStyle(ConsensusTheme.Colors.textPrimary)

            Text("Name the voices we detected so the transcript reads naturally.")
                .font(ConsensusType.displayBody)
                .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Speaker list

    private var speakerList: some View {
        ScrollView {
            VStack(spacing: ConsensusTheme.Spacing.sm) {
                ForEach($workingSuggestions) { $suggestion in
                    speakerRow(suggestion: $suggestion)
                }
            }
            .padding(.vertical, 1)
        }
        .scrollIndicators(.visible)
        .frame(maxWidth: 560, maxHeight: .infinity)
    }

    private func speakerRow(suggestion: Binding<DeepReadViewModel.SpeakerSuggestion>) -> some View {
        let speaker = viewModel.project?.speakers.first { $0.id == suggestion.wrappedValue.id }
        let palette = ConsensusTheme.Colors.speakerPalette
        let colorIndex = speaker?.paletteIndex ?? 0
        let color = palette[colorIndex % palette.count]
        let fallbackLabel = defaultLabel(for: suggestion.wrappedValue.id)
        let samples = suggestion.wrappedValue.samples

        return VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.sm) {
            HStack(spacing: ConsensusTheme.Spacing.md) {
                Circle()
                    .fill(color)
                    .frame(width: 14, height: 14)

                VStack(alignment: .leading, spacing: 2) {
                    Text(fallbackLabel)
                        .font(ConsensusType.displayEyebrow)
                        .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                        .tracking(0.8)

                    TextField(fallbackLabel, text: suggestion.suggestedName)
                        .font(ConsensusType.display(size: 16, weight: .medium))
                        .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                        .textFieldStyle(.plain)
                        .focused($focusedID, equals: suggestion.wrappedValue.id)
                        .onSubmit { focusNext(after: suggestion.wrappedValue.id) }
                }

                Spacer()
            }

            if !samples.isEmpty {
                sampleStack(
                    samples: samples,
                    speakerID: suggestion.wrappedValue.id,
                    tint: color
                )
                .padding(.leading, 26) // line up under the text field (dot + gap)
            }
        }
        .padding(.horizontal, ConsensusTheme.Spacing.lg)
        .padding(.vertical, ConsensusTheme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: ConsensusTheme.Radius.md, style: .continuous)
                .fill(ConsensusTheme.Colors.surfaceSecondary)
                .overlay(
                    RoundedRectangle(cornerRadius: ConsensusTheme.Radius.md, style: .continuous)
                        .stroke(
                            focusedID == suggestion.wrappedValue.id || evidenceSpeakerID == suggestion.wrappedValue.id
                            ? ConsensusTheme.Colors.borderAccent
                            : ConsensusTheme.Colors.border,
                            lineWidth: focusedID == suggestion.wrappedValue.id || evidenceSpeakerID == suggestion.wrappedValue.id ? 1.5 : 1
                        )
                )
        )
        .animation(.easeInOut(duration: 0.12), value: focusedID)
        .animation(.easeInOut(duration: 0.12), value: evidenceSpeakerID)
    }

    @ViewBuilder
    private func sampleStack(
        samples: [DeepReadViewModel.SpeakerSuggestion.UtteranceSample],
        speakerID: String,
        tint: Color
    ) -> some View {
        let isSelected = evidenceSpeakerID == speakerID
        let canExpand = samples.count > previewSampleCount
        let visible = Array(samples.prefix(previewSampleCount))
        let extraCount = samples.count - previewSampleCount

        Button {
            guard canExpand else { return }
            withAnimation(.easeInOut(duration: 0.18)) {
                if isSelected {
                    evidenceSpeakerID = nil
                } else {
                    evidenceSpeakerID = speakerID
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xs) {
                ForEach(visible) { sample in
                    HStack(alignment: .firstTextBaseline, spacing: ConsensusTheme.Spacing.sm) {
                        Text(TimeFormatting.timestamp(sample.timestamp))
                            .font(ConsensusType.monoMetric)
                            .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                            .frame(width: 44, alignment: .leading)

                        Text("\u{201C}\(sample.text)\u{201D}")
                            .font(ConsensusType.displayCaption)
                            .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if canExpand {
                    HStack(spacing: 6) {
                        Image(systemName: isSelected ? "xmark" : "sidebar.right")
                            .font(.system(size: 9, weight: .semibold))
                        Text(isSelected
                             ? "Hide examples"
                             : "Review \(extraCount) more example\(extraCount == 1 ? "" : "s")")
                            .font(ConsensusType.displayCaption.weight(.medium))
                    }
                    .foregroundStyle(tint.opacity(0.85))
                    .padding(.top, 2)
                    .padding(.leading, 44 + ConsensusTheme.Spacing.sm) // align under quote text
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .disabled(!canExpand)
        .padding(.leading, ConsensusTheme.Spacing.sm)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(tint.opacity(0.35))
                .frame(width: 2)
        }
    }

    @ViewBuilder
    private var evidencePanel: some View {
        if let suggestion = selectedEvidenceSuggestion {
            SpeakerEvidencePanel(
                title: suggestion.suggestedName.isEmpty ? defaultLabel(for: suggestion.id) : suggestion.suggestedName,
                subtitle: defaultLabel(for: suggestion.id),
                tint: speakerTint(for: suggestion.id),
                samples: Self.distributedSamples(suggestion.samples, count: evidenceSampleCount),
                onClose: {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        evidenceSpeakerID = nil
                    }
                }
            )
            .transition(.opacity.combined(with: .move(edge: .trailing)))
        }
    }

    /// Pick `count` samples evenly distributed across the input array. Used
    /// when a speaker has more samples than the expanded view shows; spreading
    /// by index (which mirrors timestamp order, since we collect in segment
    /// order) gives the user a representative cross-section of the call rather
    /// than an arbitrary slice from the start.
    private static func distributedSamples(
        _ all: [DeepReadViewModel.SpeakerSuggestion.UtteranceSample],
        count: Int
    ) -> [DeepReadViewModel.SpeakerSuggestion.UtteranceSample] {
        guard count > 0, !all.isEmpty else { return [] }
        if all.count <= count { return all }
        var picked: [DeepReadViewModel.SpeakerSuggestion.UtteranceSample] = []
        let step = Double(all.count - 1) / Double(count - 1)
        var seenIndices = Set<Int>()
        for i in 0..<count {
            let idx = min(all.count - 1, Int((Double(i) * step).rounded()))
            if seenIndices.insert(idx).inserted {
                picked.append(all[idx])
            }
        }
        return picked
    }

    // MARK: - Footer

    private var footerActions: some View {
        HStack(spacing: ConsensusTheme.Spacing.md) {
            Button {
                // Skip = accept defaults
                Task { await viewModel.confirmSpeakers(initialSuggestions) }
            } label: {
                Text("Skip")
                    .font(ConsensusType.displayBody)
                    .padding(.horizontal, ConsensusTheme.Spacing.md)
                    .padding(.vertical, ConsensusTheme.Spacing.xs)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Spacer()

            Button {
                Task { await viewModel.confirmSpeakers(workingSuggestions) }
            } label: {
                HStack(spacing: ConsensusTheme.Spacing.xs) {
                    Text("Continue")
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

    // MARK: - Helpers

    private var selectedEvidenceSuggestion: DeepReadViewModel.SpeakerSuggestion? {
        guard let evidenceSpeakerID else { return nil }
        return workingSuggestions.first { $0.id == evidenceSpeakerID }
    }

    private func speakerTint(for speakerID: String) -> Color {
        let speaker = viewModel.project?.speakers.first { $0.id == speakerID }
        let palette = ConsensusTheme.Colors.speakerPalette
        let colorIndex = speaker?.paletteIndex ?? 0
        return palette[colorIndex % palette.count]
    }

    private func focusNext(after id: String) {
        guard let idx = workingSuggestions.firstIndex(where: { $0.id == id }) else { return }
        let nextIdx = idx + 1
        if nextIdx < workingSuggestions.count {
            focusedID = workingSuggestions[nextIdx].id
        } else {
            focusedID = nil
        }
    }

    private func defaultLabel(for speakerID: String) -> String {
        if speakerID.uppercased().hasPrefix("SPEAKER_"),
           let n = Int(speakerID.split(separator: "_").last ?? "") {
            return "Speaker \(n + 1)"
        }
        return speakerID
    }
}

private struct SpeakerEvidencePanel: View {
    let title: String
    let subtitle: String
    let tint: Color
    let samples: [DeepReadViewModel.SpeakerSuggestion.UtteranceSample]
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: ConsensusTheme.Spacing.md) {
                Circle()
                    .fill(tint)
                    .frame(width: 14, height: 14)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(ConsensusType.displaySubheading)
                        .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text("\(subtitle) examples")
                        .font(ConsensusType.displayCaption)
                        .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: ConsensusTheme.Spacing.md)

                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                .background(
                    Circle()
                        .fill(ConsensusTheme.Colors.surfaceSecondary.opacity(0.7))
                )
                .help("Close examples")
            }
            .padding(ConsensusTheme.Spacing.lg)

            Divider()
                .overlay(ConsensusTheme.Colors.border)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: ConsensusTheme.Spacing.md) {
                    ForEach(samples) { sample in
                        SpeakerEvidenceSampleRow(sample: sample, tint: tint)
                    }
                }
                .padding(ConsensusTheme.Spacing.lg)
            }
            .scrollIndicators(.visible)
        }
        .background(
            RoundedRectangle(cornerRadius: ConsensusTheme.Radius.md, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: ConsensusTheme.Radius.md, style: .continuous)
                        .stroke(ConsensusTheme.Colors.border, lineWidth: 1)
                )
        )
    }
}

private struct SpeakerEvidenceSampleRow: View {
    let sample: DeepReadViewModel.SpeakerSuggestion.UtteranceSample
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.sm) {
            Text(TimeFormatting.timestamp(sample.timestamp))
                .font(ConsensusType.monoMetric)
                .foregroundStyle(tint.opacity(0.9))
                .monospacedDigit()

            Text(sample.text)
                .font(ConsensusType.transcriptBody)
                .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(ConsensusTheme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: ConsensusTheme.Radius.md, style: .continuous)
                .fill(ConsensusTheme.Colors.surfacePrimary.opacity(0.58))
                .overlay(
                    RoundedRectangle(cornerRadius: ConsensusTheme.Radius.md, style: .continuous)
                        .stroke(ConsensusTheme.Colors.borderSubtle, lineWidth: 1)
                )
        )
    }
}
