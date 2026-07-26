import SwiftUI

struct TranscriptView: View {
    @Environment(TranscriptionViewModel.self) private var viewModel
    @State private var searchText: String = ""
    @State private var playingSegmentID: UUID?
    @State private var selectedSegmentID: UUID?

    var body: some View {
        HSplitView {
            // Left: Transcript
            transcriptPanel
                .frame(minWidth: 400)

            // Right: Speaker Renaming
            speakerPanel
                .frame(minWidth: 250, maxWidth: 350)
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    viewModel.currentPhase = .setup
                } label: {
                    Label("Transcribe Again", systemImage: "arrow.counterclockwise")
                }

                // Copy to clipboard
                Button {
                    let text = viewModel.formattedPreview()
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Label("Copy Transcript", systemImage: "doc.on.doc")
                }
                .disabled(!viewModel.hasResult)
                .help("Copy the full transcript to the clipboard")

                Button {
                    viewModel.currentPhase = .export
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(!viewModel.hasResult)
            }
        }
        .searchable(text: $searchText, prompt: "Search transcript")
        .onKeyPress(.downArrow) {
            navigateSegment(direction: .forward)
            return .handled
        }
        .onKeyPress(.upArrow) {
            navigateSegment(direction: .backward)
            return .handled
        }
        .onKeyPress(.space) {
            guard selectedSegmentID != nil else { return .ignored }
            if let id = selectedSegmentID, let seg = viewModel.result?.segments.first(where: { $0.id == id }) {
                playSegmentAudio(seg)
            }
            return .handled
        }
        .onKeyPress("1") { guard selectedSegmentID != nil else { return .ignored }; reassignSelectedSpeaker(index: 0); return .handled }
        .onKeyPress("2") { guard selectedSegmentID != nil else { return .ignored }; reassignSelectedSpeaker(index: 1); return .handled }
        .onKeyPress("3") { guard selectedSegmentID != nil else { return .ignored }; reassignSelectedSpeaker(index: 2); return .handled }
        .onKeyPress("4") { guard selectedSegmentID != nil else { return .ignored }; reassignSelectedSpeaker(index: 3); return .handled }
    }

    private var transcriptPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            if let result = viewModel.result {
                HStack {
                    VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xs) {
                        Text("Transcript")
                            .font(.title2.bold())
                            .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                        HStack(spacing: ConsensusTheme.Spacing.xs) {
                            Text(result.audioFileName)
                                .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                            Text("\u{2022}")
                                .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                            Text(TimeFormatting.durationDisplay(result.duration))
                                .font(ConsensusTheme.Fonts.mono(.subheadline))
                                .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                            Text("\u{2022}")
                                .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                            Text("\(result.speakerCount) speakers")
                                .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                        }
                        .font(ConsensusTheme.Fonts.subheadline)

                        if let activePass = viewModel.activePass {
                            Text("\(activePass.kind.displayName) \u{2022} \(activePass.modelName)")
                                .font(ConsensusTheme.Fonts.mono(.caption))
                                .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                        }
                    }
                    Spacer()

                    if viewModel.hasResult {
                        Button {
                            viewModel.showManualEditor = true
                        } label: {
                            HStack(spacing: ConsensusTheme.Spacing.xs) {
                                Image(systemName: "square.and.pencil")
                                Text("Edit")
                            }
                            .font(.caption.weight(.medium))
                        }
                        .buttonStyle(ConsensusSecondaryButtonStyle())
                        .help("Open the manual editor to fix errors while listening to the audio.")
                    }
                }
                .padding(.horizontal, ConsensusTheme.Spacing.xl)
                .padding(.vertical, ConsensusTheme.Spacing.md)

                Divider()
                    .overlay(ConsensusTheme.Colors.border)
            }

            // Decision card — appears after transcription to guide next steps
            if viewModel.hasResult, !viewModel.pipeline.isRunning {
                TranscriptDecisionCard()
                    .padding(.horizontal, ConsensusTheme.Spacing.xl)
                    .padding(.vertical, ConsensusTheme.Spacing.md)

                Divider()
                    .overlay(ConsensusTheme.Colors.border)
            }

            // Segments
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if let result = viewModel.result {
                        let speakers = result.detectedSpeakers
                        let segments = filteredSegments(from: result.segments)

                        ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                            let displayName = viewModel.speakerMapping.displayName(for: segment.speakerID)
                            let color = SpeakerBadge.color(for: segment.speakerID, in: speakers)
                            let isNewSpeaker = index == 0 || segment.speakerID != segments[index - 1].speakerID

                            SegmentRow(
                                segment: segment,
                                displayName: displayName,
                                speakerColor: color,
                                showSpeakerHeader: isNewSpeaker,
                                searchHighlight: searchText.isEmpty ? nil : searchText,
                                isPlaying: playingSegmentID == segment.id,
                                isSelected: selectedSegmentID == segment.id,
                                onTap: {
                                    selectedSegmentID = segment.id
                                    playSegmentAudio(segment)
                                }
                            )
                        }
                    }
                }
                .padding(ConsensusTheme.Spacing.xl)
            }
        }
    }

    // MARK: - Search, Playback & Speaker Correction

    private func filteredSegments(from segments: [TranscriptionSegment]) -> [TranscriptionSegment] {
        guard !searchText.isEmpty else { return segments }
        return segments.filter { $0.text.localizedCaseInsensitiveContains(searchText) }
    }

    private func playSegmentAudio(_ segment: TranscriptionSegment) {
        guard let url = viewModel.currentAudioURL else { return }

        if playingSegmentID == segment.id {
            viewModel.stopReconciliationPlayback()
            playingSegmentID = nil
            return
        }

        playingSegmentID = segment.id
        let player = AudioContextPlayer()
        player.play(url: url, from: segment.start, to: segment.end) { [self] in
            playingSegmentID = nil
        }
    }

    private enum NavDirection { case forward, backward }

    private func navigateSegment(direction: NavDirection) {
        guard let segments = viewModel.result?.segments, !segments.isEmpty else { return }
        let filtered = filteredSegments(from: segments)
        guard !filtered.isEmpty else { return }

        if let currentID = selectedSegmentID,
           let currentIndex = filtered.firstIndex(where: { $0.id == currentID }) {
            let nextIndex: Int
            switch direction {
            case .forward: nextIndex = min(currentIndex + 1, filtered.count - 1)
            case .backward: nextIndex = max(currentIndex - 1, 0)
            }
            selectedSegmentID = filtered[nextIndex].id
        } else {
            selectedSegmentID = filtered.first?.id
        }
    }

    /// Reassign the selected segment to a different speaker by index.
    /// Press 1 for the first detected speaker, 2 for the second, etc.
    private func reassignSelectedSpeaker(index: Int) {
        guard let segmentID = selectedSegmentID,
              let result = viewModel.result else { return }

        let speakers = result.detectedSpeakers
        guard index < speakers.count else { return }

        let targetSpeakerID = speakers[index]

        // Find the segment and update its speaker
        if var project = viewModel.currentProject,
           let passIndex = project.passes.firstIndex(where: { $0.id == project.activePassID }),
           let segIndex = project.passes[passIndex].result.segments.firstIndex(where: { $0.id == segmentID }) {

            project.passes[passIndex].result.segments[segIndex].speakerID = targetSpeakerID
            viewModel.currentProject = project
            viewModel.result = project.passes[passIndex].result
            viewModel.persistProjectDraft()
        }
    }

    private var speakerPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Speakers")
                .font(.title3.bold())
                .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                .padding(.horizontal, ConsensusTheme.Spacing.lg)
                .padding(.vertical, ConsensusTheme.Spacing.md)

            Divider()
                .overlay(ConsensusTheme.Colors.border)

            if let result = viewModel.result {
                ScrollView {
                    VStack(spacing: ConsensusTheme.Spacing.lg) {
                        // Speaker rename cards
                        ForEach(Array(result.detectedSpeakers.enumerated()), id: \.element) { index, speakerID in
                            SpeakerRenameCard(
                                speakerID: speakerID,
                                sampleQuote: viewModel.speakerSamples[speakerID] ?? "",
                                color: SpeakerBadge.color(for: index),
                                currentName: viewModel.speakerMapping.names[speakerID] ?? "",
                                onRename: { newName in
                                    viewModel.renameSpeaker(speakerID, to: newName)
                                }
                            )
                        }

                        // Keyboard shortcuts hint
                        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xs) {
                            Text("KEYBOARD SHORTCUTS")
                                .font(ConsensusTheme.Fonts.mono(size: 9, weight: .bold))
                                .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                                .tracking(0.5)

                            Group {
                                Text("Click a segment to select + play")
                                Text("Up/Down arrows to navigate")
                                ForEach(Array(result.detectedSpeakers.prefix(4).enumerated()), id: \.element) { idx, spk in
                                    let name = viewModel.speakerMapping.displayName(for: spk)
                                    Text("Press \(idx + 1) to assign to \(name)")
                                }
                            }
                            .font(.caption2)
                            .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                        }
                        .padding(.top, ConsensusTheme.Spacing.md)

                        // Proper noun dictionary
                        ProperNounDictionarySection(viewModel: viewModel)
                    }
                    .padding(ConsensusTheme.Spacing.lg)
                }
            }
        }
        .background(ConsensusTheme.Colors.surfacePrimary)
    }
}

// MARK: - Speaker Rename Card

struct SpeakerRenameCard: View {
    let speakerID: String
    let sampleQuote: String
    let color: Color
    let currentName: String
    let onRename: (String) -> Void

    @State private var editedName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.sm) {
            SpeakerBadge(name: speakerID, color: color)

            if !sampleQuote.isEmpty {
                Text("\"\(sampleQuote)\"")
                    .font(ConsensusTheme.Fonts.caption)
                    .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                    .lineLimit(3)
                    .italic()
            }

            HStack(spacing: ConsensusTheme.Spacing.sm) {
                TextField("Enter name...", text: $editedName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        let trimmed = editedName.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty {
                            onRename(trimmed)
                        }
                    }

                Button("Save") {
                    let trimmed = editedName.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        onRename(trimmed)
                    }
                }
                .buttonStyle(ConsensusPillButtonStyle())
            }
        }
        .padding(ConsensusTheme.Spacing.md)
        .background {
            RoundedRectangle(cornerRadius: ConsensusTheme.Radius.md)
                .fill(ConsensusTheme.Colors.surfaceSecondary)
                .overlay {
                    RoundedRectangle(cornerRadius: ConsensusTheme.Radius.md)
                        .stroke(ConsensusTheme.Colors.border, lineWidth: 1)
                }
        }
        .onAppear {
            editedName = currentName
        }
    }
}

// MARK: - Decision Card

/// Appears in the Review phase to guide the user to their next action.
/// Shows transcript stats and offers two clear paths: Export Now or Verify Accuracy.
/// Decision card shown in the Review phase. Offers two clear terminal actions:
/// export as standard, or enter Deep Review for maximum accuracy.
private struct TranscriptDecisionCard: View {
    @Environment(TranscriptionViewModel.self) private var viewModel

    var body: some View {
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.md) {
            // Status
            HStack(spacing: ConsensusTheme.Spacing.sm) {
                Image(systemName: viewModel.hasConsensusPass ? "checkmark.seal.fill" : "checkmark.circle")
                    .foregroundStyle(viewModel.hasConsensusPass ? ConsensusTheme.Colors.confidenceGreen : ConsensusTheme.Colors.accent)
                    .font(.body.weight(.semibold))

                Text(viewModel.hasConsensusPass ? "Deep Review complete. Verified transcript ready." : "Standard transcript ready.")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(ConsensusTheme.Colors.textPrimary)
            }

            // Stats
            if let result = viewModel.result {
                let wordCount = result.segments.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
                let avgConfidence = viewModel.qualitySummary?.averageWordConfidence

                HStack(spacing: ConsensusTheme.Spacing.lg) {
                    statItem(label: "Words", value: "\(wordCount)")
                    statItem(label: "Speakers", value: "\(result.speakerCount)")
                    if let conf = avgConfidence {
                        statItem(label: "Confidence", value: "\(Int(conf * 100))%", color: ConsensusTheme.Colors.confidenceTier(conf))
                    }
                    statItem(label: "Quality", value: viewModel.hasConsensusPass ? "Verified" : "Standard",
                             color: viewModel.hasConsensusPass ? ConsensusTheme.Colors.confidenceGreen : ConsensusTheme.Colors.textSecondary)
                }
                .font(ConsensusTheme.Fonts.mono(.caption))
            }

            // Two clear actions
            HStack(spacing: ConsensusTheme.Spacing.md) {
                Button {
                    viewModel.currentPhase = .export
                } label: {
                    HStack(spacing: ConsensusTheme.Spacing.xs) {
                        Image(systemName: "square.and.arrow.up")
                        Text("Export as Standard")
                    }
                }
                .buttonStyle(ConsensusSecondaryButtonStyle())

                if !viewModel.hasConsensusPass {
                    Button {
                        viewModel.currentPhase = .deepTranscription
                    } label: {
                        HStack(spacing: ConsensusTheme.Spacing.xs) {
                            Image(systemName: "sparkles.rectangle.stack")
                            Text("Enter Deep Review")
                        }
                    }
                    .buttonStyle(ConsensusPrimaryButtonStyle())
                    .disabled(viewModel.pipeline.isRunning || viewModel.isCleanupRunning)
                }
            }

            // Deep Review description — show what's included
            if !viewModel.hasConsensusPass {
                VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.sm) {
                    Text("Deep Review includes:")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ConsensusTheme.Colors.textSecondary)

                    deepReviewStep(number: "1", title: "Deep Transcription", description: "Run a second engine and merge results to catch errors")
                    deepReviewStep(number: "2", title: "Deep Diarization", description: "Multi-pass speaker detection with AI-verified boundaries")
                    deepReviewStep(number: "3", title: "LLM Reconciliation", description: "AI reviews the transcript for speaker and text corrections")
                    deepReviewStep(number: "4", title: "Review & Export", description: "Compare results and export as Verified")
                }
                .padding(ConsensusTheme.Spacing.md)
                .background {
                    RoundedRectangle(cornerRadius: ConsensusTheme.Radius.md)
                        .fill(ConsensusTheme.Colors.accent.opacity(0.04))
                }
            } else {
                Text("This transcript has been through Deep Review. Export from here or from the Deep Review panel.")
                    .font(.caption)
                    .foregroundStyle(ConsensusTheme.Colors.textTertiary)
            }
        }
        .padding(ConsensusTheme.Spacing.lg)
        .background {
            RoundedRectangle(cornerRadius: ConsensusTheme.Radius.lg)
                .fill(ConsensusTheme.Colors.surfacePrimary)
                .overlay {
                    RoundedRectangle(cornerRadius: ConsensusTheme.Radius.lg)
                        .stroke((viewModel.hasConsensusPass ? ConsensusTheme.Colors.confidenceGreen : ConsensusTheme.Colors.accent).opacity(0.2), lineWidth: 1)
                }
        }
    }

    private func deepReviewStep(number: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: ConsensusTheme.Spacing.sm) {
            Text(number)
                .font(ConsensusTheme.Fonts.mono(size: 10, weight: .bold))
                .foregroundStyle(ConsensusTheme.Colors.accent)
                .frame(width: 16, height: 16)
                .background(
                    Circle().fill(ConsensusTheme.Colors.accent.opacity(0.1))
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                Text(description)
                    .font(.caption2)
                    .foregroundStyle(ConsensusTheme.Colors.textTertiary)
            }
        }
    }

    private func statItem(label: String, value: String, color: Color = ConsensusTheme.Colors.textSecondary) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(ConsensusTheme.Fonts.mono(.caption).bold())
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(ConsensusTheme.Colors.textTertiary)
        }
    }
}

// MARK: - Proper Noun Dictionary

private struct ProperNounDictionarySection: View {
    let viewModel: TranscriptionViewModel
    @State private var newMisspelling: String = ""
    @State private var newCorrect: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.sm) {
            Text("PROPER NOUN CORRECTIONS")
                .font(ConsensusTheme.Fonts.mono(size: 9, weight: .bold))
                .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                .tracking(0.5)

            Text("Auto-correct misspelled names throughout the transcript.")
                .font(.caption2)
                .foregroundStyle(ConsensusTheme.Colors.textTertiary)

            // Existing entries
            if let dict = viewModel.currentProject?.properNounDictionary, !dict.isEmpty {
                ForEach(dict.sorted(by: { $0.key < $1.key }), id: \.key) { misspelling, correct in
                    HStack(spacing: ConsensusTheme.Spacing.sm) {
                        Text(misspelling)
                            .font(.caption)
                            .foregroundStyle(ConsensusTheme.Colors.confidenceRed)
                            .strikethrough()
                        Image(systemName: "arrow.right")
                            .font(.caption2)
                            .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                        Text(correct)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(ConsensusTheme.Colors.confidenceGreen)
                    }
                }
            }

            // Add new entry
            HStack(spacing: ConsensusTheme.Spacing.xs) {
                TextField("Wrong", text: $newMisspelling)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 100)

                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(ConsensusTheme.Colors.textTertiary)

                TextField("Correct", text: $newCorrect)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 100)

                Button("Add") {
                    let m = newMisspelling.trimmingCharacters(in: .whitespaces)
                    let c = newCorrect.trimmingCharacters(in: .whitespaces)
                    guard !m.isEmpty, !c.isEmpty else { return }
                    viewModel.addProperNounCorrection(misspelling: m, correct: c)
                    newMisspelling = ""
                    newCorrect = ""
                }
                .buttonStyle(ConsensusPillButtonStyle())
                .disabled(newMisspelling.trimmingCharacters(in: .whitespaces).isEmpty || newCorrect.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.top, ConsensusTheme.Spacing.md)
    }
}
