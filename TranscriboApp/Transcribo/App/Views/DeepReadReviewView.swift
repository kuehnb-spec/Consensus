import SwiftUI

/// Shows the transcript produced by the pipeline. Phase 1b renders the
/// standard-pass output (Engine A + SpeakerKit): speaker turns in time
/// order, with Source Serif body text and JetBrains Mono timestamps.
///
/// Phase 1c layers on the speaker-naming result, verbatim/clean toggle,
/// and inline LLM-surfaced uncertainty popovers. Phase 1d adds the
/// summary pane and export sheet.
struct DeepReadReviewView: View {
    @Bindable var viewModel: DeepReadViewModel

    /// Which uncertainty popover is open, by segment index. `nil` = none.
    @State private var activePopoverIndex: Int?

    var body: some View {
        HStack(spacing: 0) {
            transcriptColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if viewModel.showSummaryPane {
                SummaryPane(viewModel: viewModel)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.showSummaryPane)
        .background(ConsensusTheme.Colors.background)
        .background(keyboardShortcutHost)
        .onAppear {
            viewModel.loadSummaryIfNeeded()
        }
    }

    /// Hidden buttons that register global keyboard shortcuts for the
    /// review view. Zero-sized so they never take focus or paint pixels;
    /// `.keyboardShortcut` still binds them at the window level.
    @ViewBuilder
    private var keyboardShortcutHost: some View {
        Group {
            Button("Next uncertainty") { jumpNext() }
                .keyboardShortcut("j", modifiers: [.command])
            Button("Previous uncertainty") { jumpPrevious() }
                .keyboardShortcut("k", modifiers: [.command])
            Button("Close popover") { activePopoverIndex = nil }
                .keyboardShortcut(".", modifiers: [.command])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func jumpNext() {
        guard let next = viewModel.nextUncertainty(after: activePopoverIndex) else { return }
        activePopoverIndex = next
    }

    private func jumpPrevious() {
        guard let prev = viewModel.previousUncertainty(before: activePopoverIndex) else { return }
        activePopoverIndex = prev
    }

    // MARK: - Transcript column

    private var transcriptColumn: some View {
        VStack(spacing: 0) {
            transcriptHeader
                .padding(.horizontal, ConsensusTheme.Spacing.xl)
                .padding(.vertical, ConsensusTheme.Spacing.md)
                .background(ConsensusTheme.Colors.surfacePrimary.opacity(0.6))
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(ConsensusTheme.Colors.borderSubtle)
                        .frame(height: 1)
                }

            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: ConsensusTheme.Spacing.lg) {
                        if let pass = viewModel.activePassContent {
                            if pass.segments.isEmpty {
                                emptyPassMessage
                            } else {
                                ForEach(Array(pass.segments.enumerated()), id: \.offset) { index, segment in
                                    turnRow(index: index, segment: segment)
                                        .id(index)
                                }
                            }
                        } else {
                            ProgressView("Loading transcript…")
                                .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                                .padding(ConsensusTheme.Spacing.xxl)
                        }
                    }
                    .padding(.horizontal, ConsensusTheme.Spacing.xxl)
                    .padding(.vertical, ConsensusTheme.Spacing.xl)
                    .frame(maxWidth: 820, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .onChange(of: activePopoverIndex) { _, newValue in
                    if let newValue {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            scrollProxy.scrollTo(newValue, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Header

    private var transcriptHeader: some View {
        HStack(spacing: ConsensusTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.project?.title ?? "Untitled")
                    .font(ConsensusType.displayHeading)
                    .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: ConsensusTheme.Spacing.sm) {
                    if let duration = viewModel.project?.audio.durationSeconds {
                        Text(formattedDuration(duration))
                            .font(ConsensusType.monoMetric)
                    }
                    if let pass = viewModel.activePassContent {
                        Text("·")
                            .foregroundStyle(ConsensusTheme.Colors.textMuted)
                        Text("\(pass.segments.count) turn\(pass.segments.count == 1 ? "" : "s")")
                            .font(ConsensusType.displayCaption)
                        if !pass.engineAttribution.primaryEngine.isEmpty {
                            Text("·")
                                .foregroundStyle(ConsensusTheme.Colors.textMuted)
                            Text(pass.engineAttribution.primaryEngine)
                                .font(ConsensusType.displayCaption)
                        }
                    }
                }
                .foregroundStyle(ConsensusTheme.Colors.textSecondary)
            }

            Spacer()

            if viewModel.unresolvedUncertaintyCount > 0 {
                reviewCountBadge(count: viewModel.unresolvedUncertaintyCount)
            }

            if let diarizationConfidence = viewModel.activePassContent?.quality.diarizationConfidence {
                confidenceBadge(value: diarizationConfidence)
            }
        }
    }

    private func reviewCountBadge(count: Int) -> some View {
        Button {
            guard let next = viewModel.nextUncertainty(after: activePopoverIndex) else { return }
            activePopoverIndex = next
        } label: {
            HStack(spacing: ConsensusTheme.Spacing.xs) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 11))
                Text("\(count) to review")
                    .font(ConsensusType.displayCaption.weight(.medium))
            }
            .foregroundStyle(ConsensusTheme.Colors.confidenceAmber)
            .padding(.horizontal, ConsensusTheme.Spacing.sm)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(ConsensusTheme.Colors.confidenceAmber.opacity(0.12))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(ConsensusTheme.Colors.confidenceAmber.opacity(0.35), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .help("Jump to the next uncertain turn (⌘J next, ⌘K previous)")
    }

    private func confidenceBadge(value: Double) -> some View {
        let tier = ConsensusTheme.Colors.confidenceTier(Float(value))
        return HStack(spacing: ConsensusTheme.Spacing.xs) {
            Circle()
                .fill(tier)
                .frame(width: 6, height: 6)
            Text(String(format: "%.0f%%", value * 100))
                .font(ConsensusType.monoMetric)
                .foregroundStyle(ConsensusTheme.Colors.textSecondary)
            Text("diarization")
                .font(ConsensusType.displayCaption)
                .foregroundStyle(ConsensusTheme.Colors.textTertiary)
        }
        .padding(.horizontal, ConsensusTheme.Spacing.sm)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(ConsensusTheme.Colors.surfaceSecondary)
                .overlay(Capsule(style: .continuous).stroke(ConsensusTheme.Colors.borderSubtle, lineWidth: 1))
        )
    }

    // MARK: - Empty state

    private var emptyPassMessage: some View {
        VStack(spacing: ConsensusTheme.Spacing.md) {
            Image(systemName: "waveform.slash")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(ConsensusTheme.Colors.textTertiary)
            Text("No speech detected")
                .font(ConsensusType.displaySubheading)
                .foregroundStyle(ConsensusTheme.Colors.textPrimary)
            Text("The pipeline ran, but the audio didn't produce any transcribable segments. Check the source recording and try again.")
                .font(ConsensusType.displayCaption)
                .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(ConsensusTheme.Spacing.xxl)
    }

    // MARK: - Turn row

    private func turnRow(index: Int, segment: TranscriptionSegment) -> some View {
        let speaker = viewModel.project?.speakers.first { $0.id == segment.speakerID }
        let palette = ConsensusTheme.Colors.speakerPalette
        let colorIndex = speaker?.paletteIndex ?? 0
        let color = palette[colorIndex % palette.count]
        let displayName = speaker?.displayName ?? segment.speakerID
        let isUncertain = viewModel.isUncertain(index: index)

        return VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xs) {
            HStack(spacing: ConsensusTheme.Spacing.sm) {
                Circle()
                    .fill(color)
                    .frame(width: 10, height: 10)

                Text(displayName)
                    .font(ConsensusType.transcriptSpeaker)
                    .foregroundStyle(ConsensusTheme.Colors.textPrimary)

                Text(formattedTimestamp(segment.start))
                    .font(ConsensusType.monoTimestamp)
                    .foregroundStyle(ConsensusTheme.Colors.textTertiary)

                Spacer()

                if isUncertain {
                    Button {
                        activePopoverIndex = (activePopoverIndex == index) ? nil : index
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "questionmark.circle.fill")
                                .font(.system(size: 11))
                            Text("Review")
                                .font(ConsensusType.displayCaption.weight(.medium))
                        }
                        .foregroundStyle(ConsensusTheme.Colors.confidenceAmber)
                    }
                    .buttonStyle(.plain)
                    .popover(
                        isPresented: Binding(
                            get: { activePopoverIndex == index },
                            set: { if !$0 { activePopoverIndex = nil } }
                        ),
                        arrowEdge: .trailing
                    ) {
                        uncertaintyPopover(index: index, segment: segment)
                    }
                }
            }

            Text(segment.text)
                .font(ConsensusType.transcriptBody)
                .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, isUncertain ? ConsensusTheme.Spacing.md : 0)
        .padding(.vertical, isUncertain ? ConsensusTheme.Spacing.sm : 0)
        .background(
            isUncertain
            ? RoundedRectangle(cornerRadius: ConsensusTheme.Radius.md, style: .continuous)
                .fill(ConsensusTheme.Colors.confidenceAmber.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: ConsensusTheme.Radius.md, style: .continuous)
                        .stroke(ConsensusTheme.Colors.confidenceAmber.opacity(0.35), lineWidth: 1)
                )
            : nil
        )
    }

    // MARK: - Uncertainty popover

    private func uncertaintyPopover(index: Int, segment: TranscriptionSegment) -> some View {
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xs) {
                Text("LLM flagged this turn")
                    .font(ConsensusType.displayEyebrow)
                    .foregroundStyle(ConsensusTheme.Colors.confidenceAmber)
                    .tracking(0.8)
                Text("The reconciliation had low confidence here. Play the context to verify the transcript against the audio.")
                    .font(ConsensusType.displayCaption)
                    .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: ConsensusTheme.Spacing.sm) {
                Button {
                    if viewModel.isPlayingContext {
                        viewModel.stopContext()
                    } else {
                        viewModel.playContext(for: segment)
                    }
                } label: {
                    Label(
                        viewModel.isPlayingContext ? "Stop" : "Play context",
                        systemImage: viewModel.isPlayingContext ? "stop.fill" : "play.fill"
                    )
                    .font(ConsensusType.displayBody.weight(.medium))
                    .padding(.horizontal, ConsensusTheme.Spacing.sm)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(ConsensusTheme.Colors.accent)
                .keyboardShortcut("p", modifiers: [.command])

                Button {
                    viewModel.markUncertaintyResolved(at: index)
                    activePopoverIndex = nil
                } label: {
                    Label("Mark resolved", systemImage: "checkmark")
                        .font(ConsensusType.displayBody.weight(.medium))
                        .padding(.horizontal, ConsensusTheme.Spacing.sm)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("r", modifiers: [.command])
            }
        }
        .padding(ConsensusTheme.Spacing.lg)
        .frame(width: 320)
    }

    // MARK: - Formatters

    private func formattedDuration(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    private func formattedTimestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}
