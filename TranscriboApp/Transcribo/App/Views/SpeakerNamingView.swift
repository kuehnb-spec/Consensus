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
    @FocusState private var focusedID: String?

    init(
        viewModel: DeepReadViewModel,
        suggestions: [DeepReadViewModel.SpeakerSuggestion]
    ) {
        self.viewModel = viewModel
        self.initialSuggestions = suggestions
        self._workingSuggestions = State(initialValue: suggestions)
    }

    var body: some View {
        VStack(spacing: ConsensusTheme.Spacing.xl) {
            header
                .frame(maxWidth: 560)

            speakerList
                .frame(maxWidth: 560)

            footerActions
                .frame(maxWidth: 560)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(ConsensusTheme.Spacing.xxl)
        .onAppear {
            // Auto-focus the first field so the user can start typing
            focusedID = workingSuggestions.first?.id
        }
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
        VStack(spacing: ConsensusTheme.Spacing.sm) {
            ForEach($workingSuggestions) { $suggestion in
                speakerRow(suggestion: $suggestion)
            }
        }
    }

    private func speakerRow(suggestion: Binding<DeepReadViewModel.SpeakerSuggestion>) -> some View {
        let speaker = viewModel.project?.speakers.first { $0.id == suggestion.wrappedValue.id }
        let palette = ConsensusTheme.Colors.speakerPalette
        let colorIndex = speaker?.paletteIndex ?? 0
        let color = palette[colorIndex % palette.count]
        let fallbackLabel = defaultLabel(for: suggestion.wrappedValue.id)

        return HStack(spacing: ConsensusTheme.Spacing.md) {
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
        .padding(.horizontal, ConsensusTheme.Spacing.lg)
        .padding(.vertical, ConsensusTheme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: ConsensusTheme.Radius.md, style: .continuous)
                .fill(ConsensusTheme.Colors.surfaceSecondary)
                .overlay(
                    RoundedRectangle(cornerRadius: ConsensusTheme.Radius.md, style: .continuous)
                        .stroke(
                            focusedID == suggestion.wrappedValue.id
                            ? ConsensusTheme.Colors.borderAccent
                            : ConsensusTheme.Colors.border,
                            lineWidth: focusedID == suggestion.wrappedValue.id ? 1.5 : 1
                        )
                )
        )
        .animation(.easeInOut(duration: 0.12), value: focusedID)
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
