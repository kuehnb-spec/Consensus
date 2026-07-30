import SwiftUI

struct ReconciliationView: View {
    @Environment(TranscriptionViewModel.self) private var viewModel

    var body: some View {
        Group {
            if let merged = viewModel.mergedTranscript {
                mergedContent(merged: merged)
            } else {
                ContentUnavailableView(
                    "No Verification Data",
                    systemImage: "sparkle.magnifyingglass",
                    description: Text("Start Deep Review from the workflow to run a second engine and merge the results.")
                )
            }
        }
    }

    // MARK: - Main Content

    private func mergedContent(merged: MergedTranscript) -> some View {
        let speakers = allSpeakers(in: merged)
        let speakerGroups = buildSpeakerGroups(from: merged)

        return ScrollViewReader { proxy in
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    // Header bar
                    header(merged: merged)

                    // Transcript body — formatted like a final document
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(speakerGroups) { group in
                                SpeakerGroupView(
                                    group: group,
                                    speakers: speakers,
                                    speakerMapping: viewModel.speakerMapping,
                                    selectedFlagID: viewModel.selectedMergeFlagID,
                                    playingFlagID: viewModel.playingMergeFlagID,
                                    canPlayAudio: viewModel.canPlayCurrentAudio,
                                    onSelectFlag: { flagID in
                                        withAnimation(.snappy(duration: 0.2)) {
                                            viewModel.selectMergeFlag(id: flagID)
                                            proxy.scrollTo(flagID, anchor: .center)
                                        }
                                    },
                                    onPreviewResolution: { flagID, resolution in
                                        withAnimation(.snappy(duration: 0.2)) {
                                            viewModel.previewFlagResolution(id: flagID, resolution: resolution)
                                        }
                                    },
                                    onConfirmFlag: { flagID in
                                        withAnimation(.snappy(duration: 0.2)) {
                                            viewModel.confirmMergeFlag(id: flagID)
                                        }
                                    },
                                    onPlayFlag: { flagID in
                                        if viewModel.playingMergeFlagID == flagID {
                                            viewModel.stopReconciliationPlayback()
                                        } else {
                                            viewModel.playMergeFlagContext(for: flagID)
                                        }
                                    }
                                )
                            }
                        }
                        .padding(.horizontal, ConsensusTheme.Spacing.xxl)
                        .padding(.vertical, ConsensusTheme.Spacing.xl)
                    }
                }

                // Floating "All Resolved" badge — centered in window
                if merged.totalFlagCount > 0, merged.unresolvedFlagCount == 0 {
                    completionBadge
                        .allowsHitTesting(false)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .safeAreaInset(edge: .bottom) {
                bottomBar(merged: merged)
            }
            .onKeyPress(.space) {
                togglePlayback()
                return .handled
            }
            .onKeyPress("1") {
                if let flagID = viewModel.selectedMergeFlagID {
                    viewModel.previewFlagResolution(id: flagID, resolution: .useReference)
                }
                return .handled
            }
            .onKeyPress("2") {
                if let flagID = viewModel.selectedMergeFlagID {
                    viewModel.previewFlagResolution(id: flagID, resolution: .useCandidate)
                }
                return .handled
            }
            .onKeyPress(.return) {
                if let flagID = viewModel.selectedMergeFlagID {
                    // Confirm current selection, then advance
                    viewModel.confirmMergeFlag(id: flagID)
                } else {
                    navigateToNextUnresolvedFlag(proxy: proxy, merged: merged)
                }
                return .handled
            }
        }
    }

    // MARK: - Header

    private func header(merged: MergedTranscript) -> some View {
        HStack(spacing: ConsensusTheme.Spacing.lg) {
            Text("Verified Transcript")
                .font(.title2.bold())
                .foregroundStyle(ConsensusTheme.Colors.textPrimary)

            if merged.totalFlagCount > 0 {
                HStack(spacing: ConsensusTheme.Spacing.sm) {
                    SummaryChip(
                        label: "Flags",
                        value: "\(merged.totalFlagCount)",
                        tint: ConsensusTheme.Colors.confidenceAmber
                    )
                    SummaryChip(
                        label: "Unresolved",
                        value: "\(merged.unresolvedFlagCount)",
                        tint: merged.unresolvedFlagCount == 0
                            ? ConsensusTheme.Colors.confidenceGreen
                            : ConsensusTheme.Colors.confidenceRed
                    )
                }
            }

            // Forced-alignment status: while aligning, show a spinner; after
            // a successful pass, show a green "Timings refined" chip.
            if viewModel.isAligningWordTimings {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(viewModel.wordAlignmentProgress.isEmpty
                         ? "Aligning word timings…"
                         : viewModel.wordAlignmentProgress)
                        .font(.caption)
                        .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                        .lineLimit(1)
                }
            } else if merged.wordTimingsRefined {
                let delta = viewModel.lastWordAlignmentDelta
                let meanMs = delta.map { Int(($0.meanStartDelta * 1000).rounded()) }
                SummaryChip(
                    label: "Timings",
                    value: meanMs.map { "refined · Δ\($0)ms" } ?? "refined",
                    tint: ConsensusTheme.Colors.confidenceGreen
                )
            }

            Spacer()

            if let message = viewModel.reconciliationStatusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(ConsensusTheme.Colors.accent)
                    .lineLimit(1)
            }

            HStack(spacing: ConsensusTheme.Spacing.sm) {
                Button {
                    viewModel.currentPhase = .review
                } label: {
                    Label("Back to Review", systemImage: "chevron.left")
                }
                .buttonStyle(ConsensusSecondaryButtonStyle())

                Button {
                    Task {
                        await viewModel.saveMergedConsensus()
                        viewModel.currentPhase = .review
                    }
                } label: {
                    Label("Save & Continue", systemImage: "checkmark.circle")
                }
                .buttonStyle(ConsensusPrimaryButtonStyle())
            }
        }
        .padding(.horizontal, ConsensusTheme.Spacing.lg)
        .padding(.vertical, ConsensusTheme.Spacing.md)
        .background(ConsensusTheme.Colors.surfacePrimary.opacity(0.6))
        .overlay(alignment: .bottom) {
            Divider().overlay(ConsensusTheme.Colors.border)
        }
    }

    // MARK: - Bottom Bar

    private func bottomBar(merged: MergedTranscript) -> some View {
        HStack(spacing: ConsensusTheme.Spacing.lg) {
            if viewModel.canPlayCurrentAudio, viewModel.selectedMergeFlagID != nil {
                Button {
                    togglePlayback()
                } label: {
                    HStack(spacing: ConsensusTheme.Spacing.sm) {
                        Image(systemName: viewModel.playingMergeFlagID != nil ? "stop.fill" : "play.fill")
                            .font(.body.weight(.semibold))
                        Text(viewModel.playingMergeFlagID != nil ? "Stop" : "Play Context")
                            .font(.subheadline.weight(.medium))
                    }
                    .foregroundStyle(viewModel.playingMergeFlagID != nil
                        ? ConsensusTheme.Colors.confidenceAmber
                        : ConsensusTheme.Colors.accent)
                }
                .buttonStyle(.plain)
            }

            Spacer()

            // Keyboard hints
            if viewModel.selectedMergeFlagID != nil {
                HStack(spacing: ConsensusTheme.Spacing.md) {
                    KeyHint(key: "1", label: "Select A")
                    KeyHint(key: "2", label: "Select B")
                    KeyHint(key: "Return", label: "Accept")
                    KeyHint(key: "Space", label: "Play")
                }
            }
        }
        .padding(.horizontal, ConsensusTheme.Spacing.xl)
        .padding(.vertical, ConsensusTheme.Spacing.md)
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(alignment: .top) {
                    Rectangle().fill(ConsensusTheme.Colors.border).frame(height: 1)
                }
        }
    }

    // MARK: - Completion Badge

    private var completionBadge: some View {
        HStack(spacing: ConsensusTheme.Spacing.sm) {
            Image(systemName: "checkmark.seal.fill")
                .font(.title3)
                .foregroundStyle(ConsensusTheme.Colors.confidenceGreen)
            Text("Verification Complete")
                .font(.headline.weight(.semibold))
                .foregroundStyle(ConsensusTheme.Colors.confidenceGreen)
        }
        .padding(.horizontal, ConsensusTheme.Spacing.xl)
        .padding(.vertical, ConsensusTheme.Spacing.md)
        .background {
            Capsule()
                .fill(ConsensusTheme.Colors.surfacePrimary)
                .overlay {
                    Capsule().stroke(ConsensusTheme.Colors.confidenceGreen.opacity(0.3), lineWidth: 1)
                }
                .shadow(color: ConsensusTheme.Colors.confidenceGreen.opacity(0.2), radius: 12, y: 4)
        }
    }

    // MARK: - Helpers

    private func allSpeakers(in merged: MergedTranscript) -> [String] {
        Array(Set(merged.segments.map(\.speakerID))).sorted()
    }

    private func togglePlayback() {
        if viewModel.playingMergeFlagID != nil {
            viewModel.stopReconciliationPlayback()
        } else if let flagID = viewModel.selectedMergeFlagID {
            viewModel.playMergeFlagContext(for: flagID)
        }
    }

    private func navigateToNextUnresolvedFlag(proxy: ScrollViewProxy, merged: MergedTranscript) {
        let flags = merged.flags
        let currentIndex = flags.firstIndex(where: { $0.id == viewModel.selectedMergeFlagID }) ?? -1

        if let next = flags.dropFirst(currentIndex + 1).first(where: { !$0.isResolved }) {
            withAnimation(.snappy(duration: 0.25)) {
                viewModel.selectMergeFlag(id: next.id)
                proxy.scrollTo(next.id, anchor: .center)
            }
        } else if let first = flags.first(where: { !$0.isResolved }) {
            withAnimation(.snappy(duration: 0.25)) {
                viewModel.selectMergeFlag(id: first.id)
                proxy.scrollTo(first.id, anchor: .center)
            }
        }
    }

    // MARK: - Speaker Grouping

    /// Groups consecutive same-speaker segments into paragraph blocks.
    /// This produces the "formatted transcript" layout: speaker header, then
    /// continuous flowing text, only breaking for speaker changes.
    private func buildSpeakerGroups(from merged: MergedTranscript) -> [SpeakerGroup] {
        var groups: [SpeakerGroup] = []

        for segment in merged.segments {
            let flags = segment.flagIndices.compactMap { idx in
                idx < merged.flags.count ? merged.flags[idx] : nil
            }

            if let last = groups.last, last.speakerID == segment.speakerID {
                // Same speaker — append to current group
                groups[groups.count - 1].segments.append(segment)
                groups[groups.count - 1].flags.append(contentsOf: flags)
                groups[groups.count - 1].end = segment.end
            } else {
                // New speaker — start a new group
                groups.append(SpeakerGroup(
                    speakerID: segment.speakerID,
                    start: segment.start,
                    end: segment.end,
                    segments: [segment],
                    flags: flags
                ))
            }
        }

        return groups
    }
}

// MARK: - Speaker Group Model

private struct SpeakerGroup: Identifiable {
    let id = UUID()
    let speakerID: String
    let start: TimeInterval
    var end: TimeInterval
    var segments: [MergedSegment]
    var flags: [MergeFlag]

    var text: String {
        segments.map(\.text).joined(separator: " ")
    }

    var allWords: [MergedWord] {
        segments.flatMap(\.words)
    }
}

// MARK: - Speaker Group View

/// Renders a speaker's turn as a formatted paragraph: speaker name header,
/// timestamp, then continuous flowing text with inline flag highlights.
private struct SpeakerGroupView: View {
    let group: SpeakerGroup
    let speakers: [String]
    let speakerMapping: SpeakerMapping
    let selectedFlagID: UUID?
    let playingFlagID: UUID?
    let canPlayAudio: Bool
    let onSelectFlag: (UUID) -> Void
    let onPreviewResolution: (UUID, MergeFlagResolution) -> Void
    let onConfirmFlag: (UUID) -> Void
    let onPlayFlag: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.sm) {
            // Speaker header — only shown once per speaker turn
            HStack(alignment: .firstTextBaseline, spacing: ConsensusTheme.Spacing.sm) {
                Text(speakerMapping.displayName(for: group.speakerID).uppercased())
                    .font(.caption.weight(.bold).leading(.tight))
                    .foregroundStyle(SpeakerBadge.color(for: group.speakerID, in: speakers))
                    .tracking(0.5)

                Text(TimeFormatting.timestamp(group.start))
                    .font(ConsensusTheme.Fonts.mono(.caption2))
                    .foregroundStyle(ConsensusTheme.Colors.textTertiary)
            }
            .padding(.top, ConsensusTheme.Spacing.lg)

            // Flowing paragraph text with inline flag highlights
            TranscriptParagraph(
                words: group.allWords,
                flags: group.flags,
                selectedFlagID: selectedFlagID,
                onTapFlag: onSelectFlag
            )

            // Inline flag resolution popover — appears below the paragraph when a flag is selected
            ForEach(group.flags) { flag in
                if flag.id == selectedFlagID {
                    FlagPopover(
                        flag: flag,
                        isPlaying: flag.id == playingFlagID,
                        canPlayAudio: canPlayAudio,
                        onPreview: { resolution in
                            onPreviewResolution(flag.id, resolution)
                        },
                        onConfirm: {
                            onConfirmFlag(flag.id)
                        },
                        onPlay: {
                            onPlayFlag(flag.id)
                        }
                    )
                    .id(flag.id)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                }
            }
        }
    }
}

// MARK: - Transcript Paragraph

/// Renders a continuous paragraph of text with flagged regions highlighted inline.
private struct TranscriptParagraph: View {
    let words: [MergedWord]
    let flags: [MergeFlag]
    let selectedFlagID: UUID?
    let onTapFlag: (UUID) -> Void

    var body: some View {
        buildText()
            .font(.body)
            .foregroundColor(ConsensusTheme.Colors.textPrimary)
            .lineSpacing(6)
            .textSelection(.enabled)
    }

    private func buildText() -> Text {
        // Map word indices to their flags
        var wordToFlag: [Int: MergeFlag] = [:]
        for flag in flags {
            for idx in flag.wordRange where idx < words.count {
                wordToFlag[idx] = flag
            }
        }

        var result = Text("")
        var i = 0

        while i < words.count {
            if let flag = wordToFlag[i] {
                // Flagged region — use the resolved text if the flag has been resolved,
                // otherwise show the auto-merged text from the original words
                let flagEnd = min(flag.wordRange.upperBound, words.count)
                let displayText: String
                if flag.isResolved {
                    // Show the resolution choice (Engine A text, Engine B text, or manual edit)
                    displayText = flag.mergedText
                } else {
                    displayText = words[i..<flagEnd].map(\.word).joined(separator: " ")
                }

                let isSelected = flag.id == selectedFlagID
                let tint = flagTint(for: flag)

                if displayText.isEmpty {
                    // Resolved to empty (e.g., Engine A heard nothing) — skip this region
                    i = flagEnd
                    if i < words.count { result = result + Text(" ") }
                    continue
                }

                if isSelected {
                    result = result + Text(displayText)
                        .foregroundColor(tint)
                        .bold()
                        .underline(true, color: tint)
                } else if flag.isResolved {
                    result = result + Text(displayText)
                        .foregroundColor(ConsensusTheme.Colors.textPrimary)
                } else {
                    result = result + Text(displayText)
                        .foregroundColor(ConsensusTheme.Colors.textPrimary)
                        .underline(true, color: tint.opacity(0.5))
                }

                i = flagEnd
            } else {
                result = result + Text(words[i].word)
                i += 1
            }

            if i < words.count {
                result = result + Text(" ")
            }
        }

        return result
    }

    private func flagTint(for flag: MergeFlag) -> Color {
        if flag.isResolved { return ConsensusTheme.Colors.confidenceGreen }
        switch flag.kind {
        case .lowConfidence: return ConsensusTheme.Colors.confidenceAmber
        case .ambiguousText: return ConsensusTheme.Colors.diffTextSolid
        case .speakerDispute: return ConsensusTheme.Colors.diffSpeakerSolid
        case .missingPhrase: return ConsensusTheme.Colors.confidenceRed
        case .namedEntityDispute: return ConsensusTheme.Colors.accent
        }
    }
}

// MARK: - Flag Popover

/// A compact resolution dialog that appears inline when a flagged region is clicked.
private struct FlagPopover: View {
    let flag: MergeFlag
    let isPlaying: Bool
    let canPlayAudio: Bool
    let onPreview: (MergeFlagResolution) -> Void
    let onConfirm: () -> Void
    let onPlay: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.md) {
            // Top bar: flag kind + timestamp + play button
            HStack(spacing: ConsensusTheme.Spacing.sm) {
                Image(systemName: flag.kind.systemImage)
                    .font(.caption)
                    .foregroundStyle(tint)

                Text(flag.kind.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)

                Text("at \(TimeFormatting.timestamp(flag.start))")
                    .font(ConsensusTheme.Fonts.mono(.caption2))
                    .foregroundStyle(ConsensusTheme.Colors.textTertiary)

                Spacer()

                if flag.isResolved {
                    Label("Resolved", systemImage: "checkmark.circle.fill")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(ConsensusTheme.Colors.confidenceGreen)
                }

                if canPlayAudio {
                    Button(action: onPlay) {
                        HStack(spacing: ConsensusTheme.Spacing.xs) {
                            Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                            Text(isPlaying ? "Stop" : "Listen to Context")
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(isPlaying ? ConsensusTheme.Colors.confidenceAmber : ConsensusTheme.Colors.accent)
                    }
                    .buttonStyle(ConsensusSecondaryButtonStyle())
                }
            }

            // Options: A / B (preview selection) + Accept (confirm)
            HStack(alignment: .top, spacing: ConsensusTheme.Spacing.md) {
                // Engine A — click to preview this choice
                optionCard(
                    label: "Engine A",
                    text: flag.referenceText,
                    confidence: flag.referenceConfidence,
                    isActive: isChoice(.useReference),
                    action: { onPreview(.useReference) }
                )

                // Engine B — click to preview this choice
                optionCard(
                    label: "Engine B",
                    text: flag.candidateText,
                    confidence: flag.candidateConfidence,
                    isActive: isChoice(.useCandidate),
                    action: { onPreview(.useCandidate) }
                )

                // Accept — confirms the current selection and moves on
                VStack(spacing: ConsensusTheme.Spacing.xs) {
                    Button(action: onConfirm) {
                        VStack(spacing: ConsensusTheme.Spacing.xs) {
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                            Text("Accept")
                                .font(.caption.weight(.medium))
                        }
                        .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(ConsensusPrimaryButtonStyle())
                }
                .frame(width: 80)
            }
        }
        .padding(ConsensusTheme.Spacing.md)
        .background {
            RoundedRectangle(cornerRadius: ConsensusTheme.Radius.lg)
                .fill(ConsensusTheme.Colors.surfacePrimary)
                .overlay {
                    RoundedRectangle(cornerRadius: ConsensusTheme.Radius.lg)
                        .stroke(tint.opacity(0.25), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
        }
    }

    private func optionCard(
        label: String,
        text: String,
        confidence: Float,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xs) {
                HStack {
                    Text(label)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(isActive ? ConsensusTheme.Colors.confidenceGreen : ConsensusTheme.Colors.textTertiary)
                    Spacer()
                    Text("\(Int(confidence * 100))%")
                        .font(ConsensusTheme.Fonts.mono(.caption2))
                        .foregroundStyle(ConsensusTheme.Colors.confidenceTier(confidence))
                }

                if text.isEmpty {
                    Text("(not heard)")
                        .font(.subheadline)
                        .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                        .italic()
                } else {
                    Text(text)
                        .font(.subheadline)
                        .foregroundStyle(isActive ? ConsensusTheme.Colors.textPrimary : ConsensusTheme.Colors.textSecondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(ConsensusTheme.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: ConsensusTheme.Radius.sm)
                    .fill(isActive ? ConsensusTheme.Colors.confidenceGreen.opacity(0.08) : ConsensusTheme.Colors.surfaceSecondary.opacity(0.5))
                    .overlay {
                        if isActive {
                            RoundedRectangle(cornerRadius: ConsensusTheme.Radius.sm)
                                .stroke(ConsensusTheme.Colors.confidenceGreen.opacity(0.3), lineWidth: 1)
                        }
                    }
            }
        }
        .buttonStyle(.plain)
    }

    private var tint: Color {
        if flag.isResolved { return ConsensusTheme.Colors.confidenceGreen }
        switch flag.kind {
        case .lowConfidence: return ConsensusTheme.Colors.confidenceAmber
        case .ambiguousText: return ConsensusTheme.Colors.diffTextSolid
        case .speakerDispute: return ConsensusTheme.Colors.diffSpeakerSolid
        case .missingPhrase: return ConsensusTheme.Colors.confidenceRed
        case .namedEntityDispute: return ConsensusTheme.Colors.accent
        }
    }

    private func isChoice(_ check: MergeFlagResolution) -> Bool {
        switch (flag.resolution, check) {
        case (.merged, .merged): return true
        case (.useReference, .useReference): return true
        case (.useCandidate, .useCandidate): return true
        default: return false
        }
    }
}

// MARK: - Small Components

private struct KeyHint: View {
    let key: String
    let label: String

    var body: some View {
        HStack(spacing: 2) {
            Text(key)
                .font(ConsensusTheme.Fonts.mono(size: 9, weight: .medium))
                .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(ConsensusTheme.Colors.surfaceSecondary)
                        .overlay {
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(ConsensusTheme.Colors.border, lineWidth: 0.5)
                        }
                }
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(ConsensusTheme.Colors.textTertiary)
        }
    }
}

private struct SummaryChip: View {
    let label: String
    let value: String
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(ConsensusTheme.Fonts.mono(.caption2))
                .foregroundStyle(ConsensusTheme.Colors.textTertiary)
            Text(value)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, ConsensusTheme.Spacing.sm)
        .background {
            Capsule()
                .fill(tint.opacity(0.08))
                .overlay { Capsule().stroke(tint.opacity(0.12), lineWidth: 1) }
        }
    }
}
