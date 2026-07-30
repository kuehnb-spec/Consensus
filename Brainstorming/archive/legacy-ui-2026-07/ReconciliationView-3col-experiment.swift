import SwiftUI

struct ReconciliationView: View {
    @Environment(TranscriptionViewModel.self) private var viewModel

    var body: some View {
        Group {
            if let draft = viewModel.reconciliationDraft {
                content(draft: draft)
            } else {
                ContentUnavailableView(
                    "No Reconciliation Draft",
                    systemImage: "rectangle.split.3x1",
                    description: Text("Run a Deep Review pass, then open reconciliation to compare the transcripts in context.")
                )
            }
        }
    }

    private func content(draft: ReconciliationDraft) -> some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                reconciliationHeader(draft: draft, proxy: proxy)

                // Column headers (sticky)
                columnHeaders(draft: draft)

                // Single scrollable area with 3-column rows
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(viewModel.reconciliationRows) { row in
                            ReconciliationRowView(
                                row: row,
                                isSelected: row.id == viewModel.reconciliationSelectedRowID,
                                isPlaying: row.id == viewModel.reconciliationPlayingRowID,
                                referenceLabel: draft.referenceLabel,
                                candidateLabel: draft.candidateLabel,
                                canPlayContext: viewModel.canPlayCurrentAudio,
                                onSelect: {
                                    withAnimation(.snappy(duration: 0.25)) {
                                        viewModel.selectReconciliationRow(id: row.id)
                                    }
                                },
                                onUseReference: {
                                    viewModel.chooseReferenceForReconciliationRow(row.id)
                                },
                                onUseCandidate: {
                                    viewModel.chooseCandidateForReconciliationRow(row.id)
                                },
                                onPlayContext: {
                                    if viewModel.reconciliationPlayingRowID == row.id {
                                        viewModel.stopReconciliationPlayback()
                                    } else {
                                        viewModel.playReconciliationContext(for: row.id)
                                    }
                                },
                                finalText: Binding(
                                    get: {
                                        viewModel.reconciliationRows.first(where: { $0.id == row.id })?.draftText ?? row.draftText
                                    },
                                    set: { newValue in
                                        viewModel.updateReconciliationText(newValue, for: row.id)
                                    }
                                )
                            )
                            .id(row.id)
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                FloatingAudioController(
                    isPlaying: viewModel.reconciliationPlayingRowID != nil,
                    canPlay: viewModel.canPlayCurrentAudio && viewModel.reconciliationSelectedRowID != nil,
                    currentTimestamp: playingTimestamp,
                    onPlayStop: {
                        togglePlaybackForSelectedRow()
                    }
                )
            }
            .onKeyPress(.space) {
                togglePlaybackForSelectedRow()
                return .handled
            }
            .onKeyPress("1") {
                if let rowID = viewModel.reconciliationSelectedRowID {
                    viewModel.chooseReferenceForReconciliationRow(rowID)
                }
                return .handled
            }
            .onKeyPress("2") {
                if let rowID = viewModel.reconciliationSelectedRowID {
                    viewModel.chooseCandidateForReconciliationRow(rowID)
                }
                return .handled
            }
            .onKeyPress(.downArrow) {
                navigateRow(direction: .forward, proxy: proxy)
                return .handled
            }
            .onKeyPress(.upArrow) {
                navigateRow(direction: .backward, proxy: proxy)
                return .handled
            }
            .onKeyPress(.return) {
                navigateToNextDisagreement(proxy: proxy)
                return .handled
            }
        }
    }

    // MARK: - Column Headers

    private func columnHeaders(draft: ReconciliationDraft) -> some View {
        HStack(spacing: 0) {
            Text("A: \(draft.referenceLabel)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, ConsensusTheme.Spacing.sm)
                .background(ConsensusTheme.Colors.surfacePrimary.opacity(0.8))

            Divider().overlay(ConsensusTheme.Colors.border).frame(height: 28)

            Text("Consensus")
                .font(.caption.weight(.bold))
                .foregroundStyle(ConsensusTheme.Colors.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, ConsensusTheme.Spacing.sm)
                .background(ConsensusTheme.Colors.surfacePrimary.opacity(0.8))

            Divider().overlay(ConsensusTheme.Colors.border).frame(height: 28)

            Text("B: \(draft.candidateLabel)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, ConsensusTheme.Spacing.sm)
                .background(ConsensusTheme.Colors.surfacePrimary.opacity(0.8))
        }
        .overlay(alignment: .bottom) {
            Divider().overlay(ConsensusTheme.Colors.border)
        }
    }

    // MARK: - Playback Helpers

    private var playingTimestamp: String? {
        guard let playingID = viewModel.reconciliationPlayingRowID,
              let row = viewModel.reconciliationRows.first(where: { $0.id == playingID }) else {
            return nil
        }
        return "\(TimeFormatting.timestamp(row.start)) \u{2013} \(TimeFormatting.timestamp(row.end))"
    }

    private func togglePlaybackForSelectedRow() {
        if viewModel.reconciliationPlayingRowID != nil {
            viewModel.stopReconciliationPlayback()
        } else if let rowID = viewModel.reconciliationSelectedRowID {
            viewModel.playReconciliationContext(for: rowID)
        }
    }

    // MARK: - Keyboard Navigation

    private enum NavigationDirection { case forward, backward }

    private func navigateRow(direction: NavigationDirection, proxy: ScrollViewProxy) {
        let rows = viewModel.reconciliationRows
        guard !rows.isEmpty else { return }

        let currentIndex = rows.firstIndex(where: { $0.id == viewModel.reconciliationSelectedRowID })

        let nextIndex: Int
        switch direction {
        case .forward:
            nextIndex = (currentIndex.map { $0 + 1 } ?? 0)
        case .backward:
            nextIndex = (currentIndex.map { $0 - 1 } ?? rows.count - 1)
        }

        guard rows.indices.contains(nextIndex) else { return }
        let nextRow = rows[nextIndex]

        withAnimation(.snappy(duration: 0.25)) {
            viewModel.selectReconciliationRow(id: nextRow.id)
            proxy.scrollTo(nextRow.id, anchor: .center)
        }
    }

    private func navigateToNextDisagreement(proxy: ScrollViewProxy) {
        let rows = viewModel.reconciliationRows
        let currentIndex = rows.firstIndex(where: { $0.id == viewModel.reconciliationSelectedRowID }) ?? -1

        if let nextDisagreement = rows.dropFirst(currentIndex + 1).first(where: { $0.differenceKind.hasDifference && $0.needsReview }) {
            withAnimation(.snappy(duration: 0.25)) {
                viewModel.selectReconciliationRow(id: nextDisagreement.id)
                proxy.scrollTo(nextDisagreement.id, anchor: .center)
            }
        } else if let firstDisagreement = rows.first(where: { $0.differenceKind.hasDifference && $0.needsReview }) {
            withAnimation(.snappy(duration: 0.25)) {
                viewModel.selectReconciliationRow(id: firstDisagreement.id)
                proxy.scrollTo(firstDisagreement.id, anchor: .center)
            }
        }
    }

    // MARK: - Header

    private func reconciliationHeader(draft: ReconciliationDraft, proxy: ScrollViewProxy) -> some View {
        let disagreementRows = draft.rows.filter { $0.differenceKind.hasDifference }
        let unresolvedRows = draft.rows.filter(\.needsReview)

        return HStack(spacing: ConsensusTheme.Spacing.lg) {
            // Title
            VStack(alignment: .leading, spacing: 2) {
                Text("Reconciliation")
                    .font(ConsensusTheme.Fonts.title)
                    .foregroundStyle(ConsensusTheme.Colors.textPrimary)
            }

            // Summary counts
            HStack(spacing: ConsensusTheme.Spacing.sm) {
                SummaryChip(label: "Blocks", value: "\(draft.rows.count)", tint: ConsensusTheme.Colors.textSecondary)
                SummaryChip(label: "Differences", value: "\(disagreementRows.count)", tint: ConsensusTheme.Colors.confidenceAmber)
                SummaryChip(label: "Unresolved", value: "\(unresolvedRows.count)", tint: unresolvedRows.isEmpty ? ConsensusTheme.Colors.confidenceGreen : ConsensusTheme.Colors.confidenceRed)
            }

            Spacer()

            // Status message
            if let message = viewModel.reconciliationStatusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(ConsensusTheme.Colors.accent)
                    .lineLimit(1)
            }

            // Actions
            HStack(spacing: ConsensusTheme.Spacing.sm) {
                Button {
                    viewModel.currentPhase = .quality
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(ConsensusSecondaryButtonStyle())

                Button {
                    Task {
                        await viewModel.runLLMPreResolution()
                    }
                } label: {
                    Label("AI Resolve", systemImage: "wand.and.stars")
                }
                .buttonStyle(ConsensusSecondaryButtonStyle())
                .disabled(viewModel.isCleanupRunning)

                Button {
                    Task {
                        await viewModel.saveReconciliationConsensus()
                    }
                } label: {
                    Label("Save Consensus", systemImage: "square.and.arrow.down")
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
}

// MARK: - Single Row (3 Columns Side by Side)

/// A single reconciliation row rendered as 3 aligned columns.
/// Aligned (identical) rows are collapsed to save space. Discrepancy rows are expanded
/// with highlighted differences and source arrows.
private struct ReconciliationRowView: View {
    let row: ReconciliationRow
    let isSelected: Bool
    let isPlaying: Bool
    let referenceLabel: String
    let candidateLabel: String
    let canPlayContext: Bool
    let onSelect: () -> Void
    let onUseReference: () -> Void
    let onUseCandidate: () -> Void
    let onPlayContext: () -> Void
    @Binding var finalText: String

    private let hasDifference: Bool
    @State private var isExpanded: Bool = false

    init(
        row: ReconciliationRow,
        isSelected: Bool,
        isPlaying: Bool,
        referenceLabel: String,
        candidateLabel: String,
        canPlayContext: Bool,
        onSelect: @escaping () -> Void,
        onUseReference: @escaping () -> Void,
        onUseCandidate: @escaping () -> Void,
        onPlayContext: @escaping () -> Void,
        finalText: Binding<String>
    ) {
        self.row = row
        self.isSelected = isSelected
        self.isPlaying = isPlaying
        self.referenceLabel = referenceLabel
        self.candidateLabel = candidateLabel
        self.canPlayContext = canPlayContext
        self.onSelect = onSelect
        self.onUseReference = onUseReference
        self.onUseCandidate = onUseCandidate
        self.onPlayContext = onPlayContext
        self._finalText = finalText
        self.hasDifference = row.differenceKind.hasDifference
    }

    var body: some View {
        if hasDifference {
            discrepancyRow
        } else {
            collapsedAlignedRow
        }
    }

    // MARK: - Collapsed Aligned Row (identical text — show minimal)

    private var collapsedAlignedRow: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: ConsensusTheme.Spacing.sm) {
                    Image(systemName: "checkmark")
                        .font(.caption2)
                        .foregroundStyle(ConsensusTheme.Colors.confidenceGreen.opacity(0.5))
                        .frame(width: 14)

                    Text(TimeFormatting.timestamp(row.start))
                        .font(ConsensusTheme.Fonts.mono(.caption2))
                        .foregroundStyle(ConsensusTheme.Colors.textTertiary)

                    SpeakerBadge(
                        name: row.resolvedSpeakerID,
                        color: SpeakerBadge.color(for: row.resolvedSpeakerID, in: allSpeakers)
                    )

                    Text(previewText)
                        .font(.subheadline)
                        .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                        .lineLimit(isExpanded ? nil : 1)

                    Spacer()

                    if !isExpanded {
                        let wordCount = row.referenceText.split(whereSeparator: \.isWhitespace).count
                        if wordCount > 15 {
                            Text("\(wordCount) words")
                                .font(ConsensusTheme.Fonts.mono(.caption2))
                                .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                        }

                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                    }
                }
                .padding(.horizontal, ConsensusTheme.Spacing.md)
                .padding(.vertical, ConsensusTheme.Spacing.sm)
            }
            .buttonStyle(.plain)

            Divider().overlay(ConsensusTheme.Colors.borderSubtle.opacity(0.3))
        }
    }

    private var previewText: String {
        let text = row.referenceText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count <= 80 { return text }
        return String(text.prefix(80)) + "..."
    }

    // MARK: - Discrepancy Row (expanded with 3 columns)

    @ViewBuilder
    private var discrepancyRow: some View {
        VStack(spacing: 0) {
            // Discrepancy header bar
            discrepancyHeader

            // 3-column content with source arrow
            HStack(alignment: .top, spacing: 0) {
                // Left: Reference (A)
                sideColumn(
                    text: row.referenceText,
                    speakerID: row.referenceSpeakerID,
                    isSource: row.selectedSource == .reference,
                    sourceLabel: "A"
                )
                .onTapGesture { onUseReference() }

                // Arrow from consensus to source A (if chosen)
                sourceArrow(isActive: row.selectedSource == .reference, pointsLeft: true)

                // Center: Consensus
                consensusColumn

                // Arrow from consensus to source B (if chosen)
                sourceArrow(isActive: row.selectedSource == .candidate, pointsLeft: false)

                // Right: Candidate (B)
                sideColumn(
                    text: row.candidateText,
                    speakerID: row.candidateSpeakerID,
                    isSource: row.selectedSource == .candidate,
                    sourceLabel: "B"
                )
                .onTapGesture { onUseCandidate() }
            }
        }
        .background {
            if isSelected {
                ConsensusTheme.Colors.accentMuted.opacity(0.3)
            } else {
                row.differenceKind.themedBackground.opacity(0.04)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)

        Divider()
            .overlay(row.differenceKind.themedTint.opacity(0.3))
    }

    // MARK: - Discrepancy Header

    private var discrepancyHeader: some View {
        HStack(spacing: ConsensusTheme.Spacing.sm) {
            // Colored indicator bar on the left edge
            RoundedRectangle(cornerRadius: 2)
                .fill(row.differenceKind.themedTint)
                .frame(width: 4, height: 18)

            Text(TimeFormatting.timestamp(row.start))
                .font(ConsensusTheme.Fonts.mono(.caption2))
                .foregroundStyle(ConsensusTheme.Colors.textTertiary)

            HStack(spacing: 3) {
                Image(systemName: row.differenceKind.themedSystemImage)
                Text(row.differenceKind.displayName)
            }
            .font(.caption2.weight(.bold))
            .foregroundStyle(row.differenceKind.themedTint)

            if row.needsReview {
                Text("NEEDS REVIEW")
                    .font(ConsensusTheme.Fonts.mono(.caption2))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(ConsensusTheme.Colors.confidenceAmber.opacity(0.15), in: Capsule())
                    .foregroundStyle(ConsensusTheme.Colors.confidenceAmber)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(ConsensusTheme.Colors.confidenceGreen)
            }

            Spacer()

            if canPlayContext {
                Button {
                    onPlayContext()
                } label: {
                    Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle")
                        .font(.caption)
                        .foregroundStyle(isPlaying ? ConsensusTheme.Colors.confidenceAmber : ConsensusTheme.Colors.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, ConsensusTheme.Spacing.md)
        .padding(.vertical, ConsensusTheme.Spacing.xs + 2)
        .background(row.differenceKind.themedBackground.opacity(0.12))
    }

    // MARK: - Source Arrow

    private func sourceArrow(isActive: Bool, pointsLeft: Bool) -> some View {
        VStack {
            Spacer()
            if isActive {
                Image(systemName: pointsLeft ? "arrowtriangle.left.fill" : "arrowtriangle.right.fill")
                    .font(.caption)
                    .foregroundStyle(ConsensusTheme.Colors.confidenceGreen)
            }
            Spacer()
        }
        .frame(width: 16)
    }

    // MARK: - Side Column

    private func sideColumn(
        text: String,
        speakerID: String,
        isSource: Bool,
        sourceLabel: String
    ) -> some View {
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.sm) {
            // Speaker + source indicator
            HStack(spacing: ConsensusTheme.Spacing.xs) {
                SpeakerBadge(
                    name: speakerID,
                    color: SpeakerBadge.color(for: speakerID, in: allSpeakers)
                )
                Spacer()
                // "Use A" / "Use B" label
                Text("Use \(sourceLabel)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isSource ? ConsensusTheme.Colors.confidenceGreen : ConsensusTheme.Colors.textTertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(
                            isSource
                                ? ConsensusTheme.Colors.confidenceGreen.opacity(0.15)
                                : ConsensusTheme.Colors.surfacePrimary.opacity(0.5)
                        )
                    )
            }

            // Text with readable line breaks
            if text.isEmpty {
                Text("(no text)")
                    .font(.subheadline)
                    .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                    .italic()
            } else {
                Text(readableText(text))
                    .font(.subheadline)
                    .foregroundStyle(
                        isSource
                            ? ConsensusTheme.Colors.textPrimary
                            : ConsensusTheme.Colors.textSecondary.opacity(0.7)
                    )
                    .textSelection(.enabled)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(ConsensusTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isSource {
                ConsensusTheme.Colors.confidenceGreen.opacity(0.04)
            }
        }
        .overlay(alignment: .leading) {
            if isSource {
                Rectangle()
                    .fill(ConsensusTheme.Colors.confidenceGreen)
                    .frame(width: 3)
            }
        }
    }

    // MARK: - Consensus Column

    private var consensusColumn: some View {
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.sm) {
            // Header
            HStack(spacing: ConsensusTheme.Spacing.xs) {
                Text("CONSENSUS")
                    .font(ConsensusTheme.Fonts.mono(.caption2))
                    .foregroundStyle(ConsensusTheme.Colors.accent)

                Spacer()

                HStack(spacing: 4) {
                    Button("A") { onUseReference() }
                        .font(ConsensusTheme.Fonts.mono(.caption2))
                        .buttonStyle(ConsensusPillButtonStyle())
                        .disabled(row.referenceText.isEmpty)

                    Button("B") { onUseCandidate() }
                        .font(ConsensusTheme.Fonts.mono(.caption2))
                        .buttonStyle(ConsensusPillButtonStyle())
                        .disabled(row.candidateText.isEmpty)
                }
            }

            // Editable text when selected, static otherwise
            if isSelected {
                TextEditor(text: $finalText)
                    .font(.subheadline)
                    .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                    .frame(minHeight: editorHeight)
                    .padding(ConsensusTheme.Spacing.xs)
                    .background(
                        ConsensusTheme.Colors.surfacePrimary,
                        in: RoundedRectangle(cornerRadius: ConsensusTheme.Radius.sm)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: ConsensusTheme.Radius.sm)
                            .stroke(ConsensusTheme.Colors.borderAccent, lineWidth: 1)
                    }
                    .scrollContentBackground(.hidden)
                    .lineSpacing(4)
            } else {
                Text(readableText(row.draftText))
                    .font(.subheadline)
                    .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                    .textSelection(.enabled)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(ConsensusTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ConsensusTheme.Colors.accent.opacity(0.03))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(ConsensusTheme.Colors.accent.opacity(0.3))
                .frame(width: 2)
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(ConsensusTheme.Colors.accent.opacity(0.3))
                .frame(width: 2)
        }
    }

    // MARK: - Helpers

    private var allSpeakers: [String] {
        let ref = row.referenceSegments.map(\.speakerID)
        let cand = row.candidateSegments.map(\.speakerID)
        return Array(Set(ref + cand)).sorted()
    }

    private var editorHeight: CGFloat {
        let characters = max(row.referenceText.count, row.candidateText.count, finalText.count)
        let estimatedLines = max(3, min(8, Int(ceil(Double(characters) / 40.0))))
        return CGFloat(estimatedLines * 22)
    }

    /// Add line breaks to long text for readability.
    /// Inserts a newline roughly every 2 sentences or ~120 characters.
    private func readableText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 120 else { return trimmed }

        var result = ""
        var charsSinceBreak = 0
        var sentencesSinceBreak = 0

        for char in trimmed {
            result.append(char)
            charsSinceBreak += 1

            if char == "." || char == "?" || char == "!" {
                sentencesSinceBreak += 1
                if sentencesSinceBreak >= 2 && charsSinceBreak > 80 {
                    result.append("\n\n")
                    charsSinceBreak = 0
                    sentencesSinceBreak = 0
                }
            }
        }

        return result
    }
}

// (HighlightedTranscriptText removed — word-level LCS diff was causing UI freezes)

// MARK: - Summary Chip

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

// MARK: - Diff Highlighter

private enum ReconciliationDiffHighlighter {
    struct Token {
        let raw: String
        let normalized: String
    }

    /// Maximum word count for LCS diff highlighting.
    /// Beyond this, we skip word-level diff to avoid freezing the UI.
    private static let maxDiffTokens = 150

    static func highlighted(
        text: String,
        comparedTo other: String,
        kind: ReconciliationDifferenceKind
    ) -> AttributedString {
        guard kind.hasDifference, !other.isEmpty else {
            return AttributedString(text)
        }

        let tokens = tokenize(text)
        let otherTokens = tokenize(other)

        guard !tokens.isEmpty else {
            return AttributedString(text)
        }

        // Skip expensive LCS for long texts — just show with a subtle tint
        guard tokens.count <= maxDiffTokens, otherTokens.count <= maxDiffTokens else {
            var attributed = AttributedString(text)
            attributed.backgroundColor = ConsensusTheme.Colors.diffText.opacity(0.15)
            return attributed
        }

        let matches = Dictionary(uniqueKeysWithValues: lcsMatches(lhs: tokens, rhs: otherTokens).map { ($0.0, $0.1) })
        var attributed = AttributedString()

        for index in tokens.indices {
            var segment = AttributedString(tokens[index].raw + (index == tokens.count - 1 ? "" : " "))

            if let otherIndex = matches[index] {
                if tokens[index].raw != otherTokens[otherIndex].raw {
                    segment.backgroundColor = ConsensusTheme.Colors.diffPunctuation
                }
            } else {
                segment.backgroundColor = ConsensusTheme.Colors.diffText
            }

            attributed.append(segment)
        }

        return attributed
    }

    private static func tokenize(_ text: String) -> [Token] {
        text
            .split(whereSeparator: \.isWhitespace)
            .map { raw in
                let rawText = String(raw)
                return Token(
                    raw: rawText,
                    normalized: rawText
                        .lowercased()
                        .replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
                )
            }
    }

    private static func lcsMatches(lhs: [Token], rhs: [Token]) -> [(Int, Int)] {
        guard !lhs.isEmpty, !rhs.isEmpty else { return [] }

        let lhsCount = lhs.count
        let rhsCount = rhs.count
        var table = Array(
            repeating: Array(repeating: 0, count: rhsCount + 1),
            count: lhsCount + 1
        )

        for lhsIndex in 0..<lhsCount {
            for rhsIndex in 0..<rhsCount {
                if lhs[lhsIndex].normalized == rhs[rhsIndex].normalized {
                    table[lhsIndex + 1][rhsIndex + 1] = table[lhsIndex][rhsIndex] + 1
                } else {
                    table[lhsIndex + 1][rhsIndex + 1] = max(
                        table[lhsIndex][rhsIndex + 1],
                        table[lhsIndex + 1][rhsIndex]
                    )
                }
            }
        }

        var matches: [(Int, Int)] = []
        var lhsIndex = lhsCount
        var rhsIndex = rhsCount

        while lhsIndex > 0, rhsIndex > 0 {
            if lhs[lhsIndex - 1].normalized == rhs[rhsIndex - 1].normalized {
                matches.append((lhsIndex - 1, rhsIndex - 1))
                lhsIndex -= 1
                rhsIndex -= 1
            } else if table[lhsIndex - 1][rhsIndex] >= table[lhsIndex][rhsIndex - 1] {
                lhsIndex -= 1
            } else {
                rhsIndex -= 1
            }
        }

        return matches.reversed()
    }
}

// MARK: - Themed Difference Kind Properties

private extension ReconciliationDifferenceKind {
    var themedTint: Color {
        switch self {
        case .aligned:        return ConsensusTheme.Colors.diffAlignedSolid
        case .punctuation:    return ConsensusTheme.Colors.diffPunctuationSolid
        case .speaker:        return ConsensusTheme.Colors.diffSpeakerSolid
        case .text:           return ConsensusTheme.Colors.diffTextSolid
        case .textAndSpeaker: return ConsensusTheme.Colors.diffTextSpeakerSolid
        case .missing:        return ConsensusTheme.Colors.diffMissingSolid
        }
    }

    var themedBackground: Color {
        switch self {
        case .aligned:        return ConsensusTheme.Colors.diffAligned
        case .punctuation:    return ConsensusTheme.Colors.diffPunctuation
        case .speaker:        return ConsensusTheme.Colors.diffSpeaker
        case .text:           return ConsensusTheme.Colors.diffText
        case .textAndSpeaker: return ConsensusTheme.Colors.diffTextSpeaker
        case .missing:        return ConsensusTheme.Colors.diffMissing
        }
    }

    var themedSystemImage: String {
        switch self {
        case .aligned:        return "checkmark.circle.fill"
        case .punctuation:    return "text.quote"
        case .speaker:        return "person.2.wave.2"
        case .text:           return "text.insert"
        case .textAndSpeaker: return "exclamationmark.bubble.fill"
        case .missing:        return "minus.circle.fill"
        }
    }
}
