import SwiftUI

// MARK: - Deep Review Step 1: Deep Transcription

/// Step 1: Runs a second transcription engine, auto-merges, and shows a summary.
struct DeepTranscriptionView: View {
    @Environment(TranscriptionViewModel.self) private var viewModel

    var body: some View {
        @Bindable var vm = viewModel

        VStack(spacing: 0) {
            deepReviewHeader(
                step: 1,
                title: "Deep Transcription",
                subtitle: "Run a second engine and merge results to catch transcription errors"
            )

            if viewModel.pipeline.isRunning {
                processingView(label: "Running second transcription engine...")
            } else if viewModel.isCleanupRunning {
                processingView(label: viewModel.cleanupProgress)
            } else if viewModel.deepReviewCompletedSteps.contains("transcription") {
                // Show summary of what was merged
                ScrollView {
                    VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.lg) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(ConsensusTheme.Colors.confidenceGreen)
                            .frame(maxWidth: .infinity)
                            .padding(.top, ConsensusTheme.Spacing.xl)

                        Text("Deep Transcription Complete")
                            .font(.title3.bold())
                            .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                            .frame(maxWidth: .infinity)

                        if let merged = viewModel.mergedTranscript {
                            HStack(spacing: ConsensusTheme.Spacing.xl) {
                                summaryCard(label: "Segments", value: "\(merged.segments.count)")
                                summaryCard(label: "Flagged", value: "\(merged.totalFlagCount)",
                                            color: merged.totalFlagCount > 0 ? ConsensusTheme.Colors.confidenceAmber : ConsensusTheme.Colors.confidenceGreen)
                            }
                            .frame(maxWidth: .infinity)
                        }

                        if let msg = viewModel.reconciliationStatusMessage {
                            Text(msg)
                                .font(.subheadline)
                                .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                                .frame(maxWidth: .infinity)
                        }

                        Text("The merged transcript will be used as the base for Deep Diarization in the next step.")
                            .font(.caption)
                            .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                            .frame(maxWidth: .infinity)
                    }
                    .padding(ConsensusTheme.Spacing.xl)
                }
            } else {
                // Ready to run — show engine selection and start button
                ScrollView {
                    VStack(spacing: ConsensusTheme.Spacing.xl) {
                        Spacer(minLength: ConsensusTheme.Spacing.xl)

                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 48, weight: .light))
                            .foregroundStyle(ConsensusTheme.Colors.accent.opacity(0.4))

                        Text("This will run a second transcription engine on your audio and merge the results using confidence-weighted word alignment. Any spots where the engines disagree will be flagged.")
                            .font(.subheadline)
                            .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 500)

                        // Engine selection
                        VStack(spacing: ConsensusTheme.Spacing.md) {
                            HStack {
                                Text("Comparison Engine")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                                Spacer()
                                Picker("", selection: $vm.deepReviewEngine) {
                                    ForEach(DeepReviewEngineChoice.allCases) { engine in
                                        Text(engine.displayName).tag(engine)
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(width: 220)
                            }

                            if viewModel.deepReviewEngine.usesWhisperModelSelection {
                                HStack {
                                    Text("Comparison Model")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                                    Spacer()
                                    Picker("", selection: $vm.deepReviewModel) {
                                        ForEach(WhisperModel.allCases) { model in
                                            Text(model.displayName).tag(model)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .frame(width: 180)
                                }
                            }
                        }
                        .padding(ConsensusTheme.Spacing.lg)
                        .frame(maxWidth: 500)
                        .background {
                            RoundedRectangle(cornerRadius: ConsensusTheme.Radius.md)
                                .fill(ConsensusTheme.Colors.surfaceSecondary)
                                .overlay {
                                    RoundedRectangle(cornerRadius: ConsensusTheme.Radius.md)
                                        .stroke(ConsensusTheme.Colors.border, lineWidth: 1)
                                }
                        }

                        Button {
                            Task {
                                await viewModel.startDeepTranscription()
                            }
                        } label: {
                            HStack(spacing: ConsensusTheme.Spacing.sm) {
                                Image(systemName: "play.fill")
                                Text("Run Deep Transcription")
                            }
                            .font(.body.weight(.medium))
                        }
                        .buttonStyle(ConsensusPrimaryButtonStyle())

                        Spacer(minLength: ConsensusTheme.Spacing.xl)
                    }
                    .padding(ConsensusTheme.Spacing.xl)
                }
            }

            Spacer(minLength: 0)

            bottomNav(
                backAction: { viewModel.currentPhase = .review },
                backLabel: "Back to Review",
                nextAction: viewModel.deepReviewCompletedSteps.contains("transcription") ? {
                    viewModel.currentPhase = .deepDiarization
                } : nil,
                nextLabel: "Continue to Deep Diarization"
            )
        }
    }

    private func summaryCard(label: String, value: String, color: Color = ConsensusTheme.Colors.textSecondary) -> some View {
        VStack(spacing: ConsensusTheme.Spacing.xs) {
            Text(value)
                .font(ConsensusTheme.Fonts.mono(.title2).bold())
                .foregroundStyle(color)
            Text(label)
                .font(.caption)
                .foregroundStyle(ConsensusTheme.Colors.textTertiary)
        }
        .padding(ConsensusTheme.Spacing.lg)
        .background {
            RoundedRectangle(cornerRadius: ConsensusTheme.Radius.md)
                .fill(ConsensusTheme.Colors.surfaceSecondary)
        }
    }
}

// MARK: - Deep Review Step 2: Deep Diarization

/// Step 2: Runs multi-pass diarization with LLM boundary confirmation.
/// Uses the verified/merged text from Step 1 as context for the LLM.
struct DeepDiarizationView: View {
    @Environment(TranscriptionViewModel.self) private var viewModel

    var body: some View {
        VStack(spacing: 0) {
            deepReviewHeader(
                step: 2,
                title: "Deep Diarization",
                subtitle: "Multi-pass speaker detection with AI-confirmed boundaries"
            )

            if viewModel.isCleanupRunning {
                processingView(label: viewModel.cleanupProgress)
            } else if viewModel.deepReviewCompletedSteps.contains("diarization") {
                completedView(message: "Deep Diarization complete. Speaker assignments refined.")
            } else {
                startView(
                    icon: "person.2.wave.2",
                    description: "This will run multiple diarization passes at different sensitivity levels, then use AI to confirm which speaker boundaries are real based on conversational context from the verified transcript.",
                    buttonLabel: "Run Deep Diarization",
                    action: {
                        Task {
                            await viewModel.refineSpeakers()
                        }
                    }
                )
            }

            Spacer(minLength: 0)

            bottomNav(
                backAction: { viewModel.currentPhase = .deepTranscription },
                backLabel: "Back to Transcription",
                nextAction: viewModel.deepReviewCompletedSteps.contains("diarization") ? {
                    viewModel.currentPhase = .deepSpeakerConfirm
                } : nil,
                nextLabel: "Continue to Speaker Confirmation"
            )
        }
    }
}

// MARK: - Deep Review Step 3: Speaker Confirmation

/// Shows auto-mapped speaker names alongside the full transcript, color-coded so the
/// user can scroll through and identify who's who from context rather than guessing
/// from a 120-character preview.
struct SpeakerConfirmView: View {
    @Environment(TranscriptionViewModel.self) private var viewModel

    var body: some View {
        VStack(spacing: 0) {
            deepReviewHeader(
                step: 3,
                title: "Confirm Speakers",
                subtitle: "Verify that speaker names are correctly assigned after refinement"
            )

            if let result = viewModel.result {
                HStack(spacing: 0) {
                    // Left: speaker cards
                    ScrollView {
                        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.lg) {
                            Text("Scroll the transcript to confirm who each speaker is, then name them below. Names from Review & Label Speakers carry over automatically.")
                                .font(.subheadline)
                                .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                                .padding(.bottom, ConsensusTheme.Spacing.sm)
                                .fixedSize(horizontal: false, vertical: true)

                            ForEach(Array(result.detectedSpeakers.enumerated()), id: \.element) { index, speakerID in
                                SpeakerConfirmCard(
                                    speakerID: speakerID,
                                    color: SpeakerBadge.color(for: index),
                                    currentName: viewModel.speakerMapping.names[speakerID] ?? "",
                                    sampleQuote: viewModel.speakerSamples[speakerID] ?? "",
                                    segmentCount: result.segments.filter { $0.speakerID == speakerID }.count,
                                    onRename: { name in
                                        viewModel.renameSpeaker(speakerID, to: name)
                                    }
                                )
                            }
                        }
                        .padding(ConsensusTheme.Spacing.xl)
                    }
                    .frame(width: 460)

                    Divider().overlay(ConsensusTheme.Colors.border)

                    // Right: full transcript, color-coded by speaker
                    SpeakerConfirmTranscript(result: result, viewModel: viewModel)
                }
            }

            Spacer(minLength: 0)

            bottomNav(
                backAction: { viewModel.currentPhase = .deepDiarization },
                backLabel: "Back to Diarization",
                nextAction: {
                    viewModel.deepReviewCompletedSteps.insert("speakerConfirm")
                    viewModel.currentPhase = .deepReviewCompare
                },
                nextLabel: "Continue to Review & Export"
            )
        }
    }
}

/// Full transcript panel rendered with coalesced same-speaker turns and color-coded
/// speaker headers so the user can scan the conversation to identify each voice.
private struct SpeakerConfirmTranscript: View {
    let result: TranscriptionResult
    let viewModel: TranscriptionViewModel

    var body: some View {
        ScrollView {
            let speakers = result.detectedSpeakers
            let turns = DeepReviewCompareView.coalesceSameSpeakerSegments(result.segments)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                    let speakerIndex = speakers.firstIndex(of: turn.speakerID) ?? 0
                    let color = SpeakerBadge.color(for: speakerIndex)

                    HStack(alignment: .firstTextBaseline, spacing: ConsensusTheme.Spacing.sm) {
                        Text(displayLabel(for: turn.speakerID).uppercased())
                            .font(.caption.weight(.bold).leading(.tight))
                            .foregroundStyle(color)
                            .tracking(0.5)

                        Text(TimeFormatting.timestamp(turn.start))
                            .font(ConsensusTheme.Fonts.mono(.caption2))
                            .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                    }
                    .padding(.top, index == 0 ? ConsensusTheme.Spacing.md : ConsensusTheme.Spacing.lg)

                    Text(turn.text)
                        .font(.body)
                        .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .padding(.top, 2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, ConsensusTheme.Spacing.xl)
            .padding(.bottom, ConsensusTheme.Spacing.xl)
        }
    }

    /// Show the user-entered name if one exists, otherwise fall back to the raw
    /// speaker ID ("SPEAKER_0") — but abbreviated so the header stays compact.
    private func displayLabel(for speakerID: String) -> String {
        let name = viewModel.speakerMapping.displayName(for: speakerID)
        if name != speakerID { return name }
        return speakerID
            .replacingOccurrences(of: "SPEAKER_", with: "Speaker ")
    }
}

// MARK: - Deep Review Step 4: Review & Polish & Export

/// Shows the full final transcript, offers AI polish, then export.
struct DeepReviewCompareView: View {
    @Environment(TranscriptionViewModel.self) private var viewModel
    @State private var hasPolished = false

    var body: some View {
        VStack(spacing: 0) {
            deepReviewHeader(
                step: 4,
                title: "Review Final Transcript",
                subtitle: "Review, polish with AI if desired, then save and export"
            )

            // Summary bar
            if let result = viewModel.result {
                HStack(spacing: ConsensusTheme.Spacing.xl) {
                    summaryMetric(label: "Segments", value: "\(result.segments.count)")
                    summaryMetric(label: "Speakers", value: "\(result.speakerCount)")
                    if let conf = viewModel.qualitySummary?.averageWordConfidence {
                        summaryMetric(label: "Confidence", value: "\(Int(conf * 100))%", color: ConsensusTheme.Colors.confidenceTier(conf))
                    }
                    summaryMetric(label: "Status", value: hasPolished ? "Polished" : "Verified",
                                  color: ConsensusTheme.Colors.confidenceGreen)

                    Spacer()

                    // Manual edit button — always available
                    Button {
                        viewModel.showManualEditor = true
                    } label: {
                        HStack(spacing: ConsensusTheme.Spacing.xs) {
                            Image(systemName: "square.and.pencil")
                            Text("Edit Transcript")
                        }
                        .font(.caption.weight(.medium))
                    }
                    .buttonStyle(ConsensusSecondaryButtonStyle())
                    .help("Open the manual editor to fix errors while listening to the audio.")

                    // Polish button + Undo
                    if !hasPolished && !viewModel.isCleanupRunning {
                        Button {
                            Task {
                                await viewModel.runDeepCleanup()
                                hasPolished = true
                            }
                        } label: {
                            HStack(spacing: ConsensusTheme.Spacing.xs) {
                                Image(systemName: "wand.and.stars")
                                Text("Polish with AI")
                            }
                            .font(.caption.weight(.medium))
                        }
                        .buttonStyle(ConsensusSecondaryButtonStyle())
                        .help("Fix repeated words, punctuation, and formatting with AI")
                    } else if viewModel.isCleanupRunning {
                        HStack(spacing: ConsensusTheme.Spacing.xs) {
                            ProgressView().controlSize(.mini)
                            Text("Polishing...")
                                .font(.caption)
                                .foregroundStyle(ConsensusTheme.Colors.accent)
                        }
                    } else if hasPolished {
                        HStack(spacing: ConsensusTheme.Spacing.sm) {
                            HStack(spacing: ConsensusTheme.Spacing.xs) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(ConsensusTheme.Colors.confidenceGreen)
                                Text("Polished")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(ConsensusTheme.Colors.confidenceGreen)
                            }
                            if viewModel.canUndoPolish {
                                Button {
                                    viewModel.undoPolish()
                                    hasPolished = false
                                } label: {
                                    HStack(spacing: ConsensusTheme.Spacing.xs) {
                                        Image(systemName: "arrow.uturn.backward")
                                        Text("Undo Polish")
                                    }
                                    .font(.caption.weight(.medium))
                                }
                                .buttonStyle(ConsensusSecondaryButtonStyle())
                                .help("Restore the transcript to the state before AI Polish")
                            }
                        }
                    }
                }
                .padding(.horizontal, ConsensusTheme.Spacing.xl)
                .padding(.vertical, ConsensusTheme.Spacing.md)
                .background(ConsensusTheme.Colors.surfaceSecondary.opacity(0.5))

                Divider().overlay(ConsensusTheme.Colors.border)
            }

            // Full transcript (scrollable).
            // Consecutive same-speaker segments are coalesced into one flowing paragraph
            // so the transcript reads as natural prose rather than fragmented lines.
            ScrollView {
                if let result = viewModel.result {
                    let speakerTurns = DeepReviewCompareView.coalesceSameSpeakerSegments(result.segments)
                    VStack(alignment: .leading, spacing: 0) {
                        let speakers = result.detectedSpeakers

                        ForEach(Array(speakerTurns.enumerated()), id: \.element.id) { index, turn in
                            HStack(alignment: .firstTextBaseline, spacing: ConsensusTheme.Spacing.sm) {
                                Text(viewModel.speakerMapping.displayName(for: turn.speakerID).uppercased())
                                    .font(.caption.weight(.bold).leading(.tight))
                                    .foregroundStyle(SpeakerBadge.color(for: turn.speakerID, in: speakers))
                                    .tracking(0.5)

                                Text(TimeFormatting.timestamp(turn.start))
                                    .font(ConsensusTheme.Fonts.mono(.caption2))
                                    .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                            }
                            .padding(.top, index == 0 ? ConsensusTheme.Spacing.md : ConsensusTheme.Spacing.lg)

                            Text(turn.text)
                                .font(.body)
                                .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                                .lineSpacing(5)
                                .textSelection(.enabled)
                                .padding(.top, 2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, ConsensusTheme.Spacing.xxl)
                    .padding(.bottom, ConsensusTheme.Spacing.xl)
                }
            }

            // Bottom action bar
            HStack(spacing: ConsensusTheme.Spacing.md) {
                Button {
                    viewModel.currentPhase = .deepSpeakerConfirm
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(ConsensusSecondaryButtonStyle())

                Spacer()

                // Copy to clipboard
                Button {
                    let text = viewModel.formattedPreview()
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(ConsensusSecondaryButtonStyle())

                Button {
                    Task {
                        await viewModel.saveMergedConsensus()
                        viewModel.currentPhase = .export
                    }
                } label: {
                    HStack(spacing: ConsensusTheme.Spacing.xs) {
                        Image(systemName: "checkmark.seal")
                        Text("Save & Export")
                    }
                }
                .buttonStyle(ConsensusPrimaryButtonStyle())
            }
            .padding(.horizontal, ConsensusTheme.Spacing.xl)
            .padding(.vertical, ConsensusTheme.Spacing.md)
            .background(ConsensusTheme.Colors.surfacePrimary.opacity(0.6))
            .overlay(alignment: .top) {
                Divider().overlay(ConsensusTheme.Colors.border)
            }
        }
    }

    private func summaryMetric(label: String, value: String, color: Color = ConsensusTheme.Colors.textSecondary) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(ConsensusTheme.Fonts.mono(.caption).bold())
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(ConsensusTheme.Colors.textTertiary)
        }
    }

    // MARK: - Same-speaker Coalescing

    /// A contiguous block of speech from a single speaker, collapsed from any number of
    /// underlying short ASR segments so the transcript renders as flowing prose.
    fileprivate struct SpeakerTurn: Identifiable {
        let id: UUID
        let speakerID: String
        let start: TimeInterval
        let end: TimeInterval
        let text: String
    }

    /// Group consecutive same-speaker segments into one `SpeakerTurn`, joining their
    /// text with a single space. This is purely a rendering convenience — the underlying
    /// segments on the model are untouched so exports, click-to-play, and keyboard
    /// navigation still work at segment granularity.
    fileprivate static func coalesceSameSpeakerSegments(
        _ segments: [TranscriptionSegment]
    ) -> [SpeakerTurn] {
        guard !segments.isEmpty else { return [] }

        var turns: [SpeakerTurn] = []
        var bufferSpeaker = segments[0].speakerID
        var bufferStart = segments[0].start
        var bufferEnd = segments[0].end
        var bufferText = segments[0].text.trimmingCharacters(in: .whitespacesAndNewlines)

        func flush() {
            let cleaned = collapseAdjacentDuplicateTokens(
                bufferText.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            guard !cleaned.isEmpty else { return }
            turns.append(SpeakerTurn(
                id: UUID(),
                speakerID: bufferSpeaker,
                start: bufferStart,
                end: bufferEnd,
                text: cleaned
            ))
        }

        for segment in segments.dropFirst() {
            let segText = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if segment.speakerID == bufferSpeaker {
                if !segText.isEmpty {
                    bufferText = bufferText.isEmpty ? segText : "\(bufferText) \(segText)"
                }
                bufferEnd = segment.end
            } else {
                flush()
                bufferSpeaker = segment.speakerID
                bufferStart = segment.start
                bufferEnd = segment.end
                bufferText = segText
            }
        }
        flush()

        return turns
    }

    /// Display-side safety net for adjacent duplicate words in transcripts that were
    /// merged before the upstream dedup landed. Collapses runs like "cost cost" and
    /// "fine. fine." to a single token while leaving genuine wider-spaced repetition
    /// alone (we only operate on immediately adjacent tokens — a speaker saying
    /// "pay down ... pay down" has other words between, so neither "pay" nor "down"
    /// appears twice in a row).
    fileprivate static func collapseAdjacentDuplicateTokens(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let tokens = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard tokens.count >= 2 else { return text }

        var result: [String] = []
        result.reserveCapacity(tokens.count)

        for token in tokens {
            if let previous = result.last,
               duplicateKey(previous) == duplicateKey(token),
               !duplicateKey(previous).isEmpty {
                // Keep whichever token carries more punctuation so the final sentence
                // still ends in a period. If both are equally punctuated, keep the first.
                if token.rangeOfCharacter(from: .punctuationCharacters) != nil
                   && previous.rangeOfCharacter(from: .punctuationCharacters) == nil {
                    result[result.count - 1] = token
                }
                continue
            }
            result.append(token)
        }

        return result.joined(separator: " ")
    }

    /// Normalize a token for duplicate comparison: lowercase, strip surrounding
    /// punctuation so "position." and "position" compare equal.
    private static func duplicateKey(_ token: String) -> String {
        token
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
    }
}

// MARK: - Shared Deep Review Components

/// Standard header bar for all Deep Review steps with full progress tracker.
private func deepReviewHeader(step: Int, title: String, subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.md) {
        HStack(spacing: ConsensusTheme.Spacing.sm) {
            Text("DEEP REVIEW")
                .font(ConsensusTheme.Fonts.mono(size: 10, weight: .bold))
                .foregroundStyle(ConsensusTheme.Colors.accent)
                .tracking(1)

            Spacer()
        }

        Text(title)
            .font(.title2.bold())
            .foregroundStyle(ConsensusTheme.Colors.textPrimary)

        Text(subtitle)
            .font(.subheadline)
            .foregroundStyle(ConsensusTheme.Colors.textSecondary)

        // Step progress tracker
        HStack(spacing: 0) {
            stepIndicator(number: 1, label: "Transcription", state: step > 1 ? .done : (step == 1 ? .active : .upcoming))
            stepConnector(isDone: step > 1)
            stepIndicator(number: 2, label: "Diarization", state: step > 2 ? .done : (step == 2 ? .active : .upcoming))
            stepConnector(isDone: step > 2)
            stepIndicator(number: 3, label: "Speakers", state: step > 3 ? .done : (step == 3 ? .active : .upcoming))
            stepConnector(isDone: step > 3)
            stepIndicator(number: 4, label: "Export", state: step > 4 ? .done : (step == 4 ? .active : .upcoming))
        }
    }
    .padding(.horizontal, ConsensusTheme.Spacing.xl)
    .padding(.top, ConsensusTheme.Spacing.xl)
    .padding(.bottom, ConsensusTheme.Spacing.lg)
    .background(ConsensusTheme.Colors.surfacePrimary.opacity(0.6))
    .overlay(alignment: .bottom) {
        Divider().overlay(ConsensusTheme.Colors.border)
    }
}

/// Shown when a step is ready to run but hasn't started yet.
private enum StepState { case done, active, upcoming }

private func stepIndicator(number: Int, label: String, state: StepState) -> some View {
    VStack(spacing: 3) {
        ZStack {
            switch state {
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(ConsensusTheme.Colors.confidenceGreen)
            case .active:
                Text("\(number)")
                    .font(ConsensusTheme.Fonts.mono(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(ConsensusTheme.Colors.accent))
            case .upcoming:
                Text("\(number)")
                    .font(ConsensusTheme.Fonts.mono(size: 10, weight: .bold))
                    .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                    .frame(width: 18, height: 18)
                    .background(
                        Circle().stroke(ConsensusTheme.Colors.border, lineWidth: 1)
                    )
            }
        }

        Text(label)
            .font(.system(size: 9))
            .foregroundStyle(state == .active ? ConsensusTheme.Colors.textPrimary : ConsensusTheme.Colors.textTertiary)
    }
}

private func stepConnector(isDone: Bool) -> some View {
    Rectangle()
        .fill(isDone ? ConsensusTheme.Colors.confidenceGreen : ConsensusTheme.Colors.border)
        .frame(height: 2)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 2)
        .padding(.bottom, 14) // Align with circle centers
}

private func startView(icon: String, description: String, buttonLabel: String, action: @escaping () -> Void) -> some View {
    VStack(spacing: ConsensusTheme.Spacing.xl) {
        Spacer()

        Image(systemName: icon)
            .font(.system(size: 48, weight: .light))
            .foregroundStyle(ConsensusTheme.Colors.accent.opacity(0.4))

        Text(description)
            .font(.subheadline)
            .foregroundStyle(ConsensusTheme.Colors.textSecondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 500)

        Button(action: action) {
            HStack(spacing: ConsensusTheme.Spacing.sm) {
                Image(systemName: "play.fill")
                Text(buttonLabel)
            }
            .font(.body.weight(.medium))
        }
        .buttonStyle(ConsensusPrimaryButtonStyle())

        Spacer()
    }
    .padding(ConsensusTheme.Spacing.xl)
}

/// Shown while a step is processing — fills the available space with details.
private func processingView(label: String) -> some View {
    ProcessingDetailView(label: label)
}

private struct ProcessingDetailView: View {
    let label: String
    @Environment(TranscriptionViewModel.self) private var viewModel

    var body: some View {
        VStack(spacing: ConsensusTheme.Spacing.xl) {
            Spacer(minLength: ConsensusTheme.Spacing.xl)

            // Main progress indicator
            VStack(spacing: ConsensusTheme.Spacing.lg) {
                ProgressView()
                    .controlSize(.large)
                    .tint(ConsensusTheme.Colors.accent)

                Text(label)
                    .font(.headline)
                    .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                    .multilineTextAlignment(.center)

                if viewModel.globalProgress > 0 {
                    VStack(spacing: ConsensusTheme.Spacing.xs) {
                        ProgressView(value: viewModel.globalProgress)
                            .tint(ConsensusTheme.Colors.accent)
                            .frame(maxWidth: 300)

                        Text("\(Int(viewModel.globalProgress * 100))%")
                            .font(ConsensusTheme.Fonts.mono(.caption))
                            .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                    }
                }
            }

            // What's happening now
            VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.md) {
                if !viewModel.cleanupProgress.isEmpty && viewModel.cleanupProgress != label {
                    HStack(spacing: ConsensusTheme.Spacing.sm) {
                        Image(systemName: "gearshape.2")
                            .font(.caption)
                            .foregroundStyle(ConsensusTheme.Colors.accent)
                        Text(viewModel.cleanupProgress)
                            .font(.caption)
                            .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                    }
                }

                // Process log entries (recent)
                if !viewModel.processLog.entries.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ACTIVITY")
                            .font(ConsensusTheme.Fonts.mono(size: 9, weight: .bold))
                            .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                            .tracking(0.5)

                        ForEach(viewModel.processLog.entries.suffix(8)) { entry in
                            HStack(alignment: .top, spacing: ConsensusTheme.Spacing.xs) {
                                Circle()
                                    .fill(logEntryColor(entry.level))
                                    .frame(width: 5, height: 5)
                                    .padding(.top, 5)

                                Text(entry.message)
                                    .font(.caption)
                                    .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                    .frame(maxWidth: 500, alignment: .leading)
                }

                // Live transcription output
                if !viewModel.processLog.outputText.isEmpty {
                    VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xs) {
                        HStack(spacing: ConsensusTheme.Spacing.xs) {
                            Image(systemName: "text.justify.left")
                                .font(.caption2)
                            Text("LIVE OUTPUT")
                                .font(ConsensusTheme.Fonts.mono(size: 9, weight: .bold))
                                .tracking(0.5)
                        }
                        .foregroundStyle(ConsensusTheme.Colors.accent)

                        ScrollView {
                            Text(String(viewModel.processLog.outputText.suffix(1000)))
                                .font(ConsensusTheme.Fonts.mono(size: 11))
                                .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .lineSpacing(4)
                        }
                        .frame(maxHeight: 200)
                        .padding(ConsensusTheme.Spacing.md)
                        .background {
                            RoundedRectangle(cornerRadius: ConsensusTheme.Radius.md)
                                .fill(ConsensusTheme.Colors.background)
                                .overlay {
                                    RoundedRectangle(cornerRadius: ConsensusTheme.Radius.md)
                                        .stroke(ConsensusTheme.Colors.border, lineWidth: 1)
                                }
                        }
                    }
                    .frame(maxWidth: 600)
                }
            }
            .padding(.horizontal, ConsensusTheme.Spacing.xl)

            Spacer(minLength: ConsensusTheme.Spacing.xl)
        }
    }

    private func logEntryColor(_ level: ProcessLogEntry.Level) -> Color {
        switch level {
        case .info: return ConsensusTheme.Colors.textTertiary
        case .progress: return ConsensusTheme.Colors.accent
        case .success: return ConsensusTheme.Colors.confidenceGreen
        case .warning: return ConsensusTheme.Colors.confidenceAmber
        case .error: return ConsensusTheme.Colors.confidenceRed
        case .aiThinking: return ConsensusTheme.Colors.accent
        }
    }
}

/// Shown when a step has completed successfully.
private func completedView(message: String) -> some View {
    VStack(spacing: ConsensusTheme.Spacing.lg) {
        Spacer()

        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 48))
            .foregroundStyle(ConsensusTheme.Colors.confidenceGreen)

        Text(message)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(ConsensusTheme.Colors.textPrimary)

        Spacer()
    }
}

/// Bottom navigation bar with back/next buttons.
private func bottomNav(
    backAction: @escaping () -> Void,
    backLabel: String,
    nextAction: (() -> Void)?,
    nextLabel: String
) -> some View {
    HStack {
        Button(action: backAction) {
            Label(backLabel, systemImage: "chevron.left")
        }
        .buttonStyle(ConsensusSecondaryButtonStyle())

        Spacer()

        if let nextAction {
            Button(action: nextAction) {
                HStack(spacing: ConsensusTheme.Spacing.xs) {
                    Text(nextLabel)
                    Image(systemName: "chevron.right")
                }
            }
            .buttonStyle(ConsensusPrimaryButtonStyle())
        }
    }
    .padding(.horizontal, ConsensusTheme.Spacing.xl)
    .padding(.vertical, ConsensusTheme.Spacing.md)
    .background(ConsensusTheme.Colors.surfacePrimary.opacity(0.6))
    .overlay(alignment: .top) {
        Divider().overlay(ConsensusTheme.Colors.border)
    }
}

// MARK: - Speaker Confirm Card

private struct SpeakerConfirmCard: View {
    let speakerID: String
    let color: Color
    let currentName: String
    let sampleQuote: String
    let segmentCount: Int
    let onRename: (String) -> Void

    @State private var editedName: String = ""

    var body: some View {
        HStack(spacing: ConsensusTheme.Spacing.lg) {
            // Speaker badge
            VStack(spacing: ConsensusTheme.Spacing.xs) {
                SpeakerBadge(name: speakerID, color: color)
                Text("\(segmentCount) segments")
                    .font(ConsensusTheme.Fonts.mono(.caption2))
                    .foregroundStyle(ConsensusTheme.Colors.textTertiary)
            }
            .frame(width: 100)

            VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.sm) {
                // Name field
                HStack(spacing: ConsensusTheme.Spacing.sm) {
                    TextField("Speaker name...", text: $editedName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            let trimmed = editedName.trimmingCharacters(in: .whitespaces)
                            if !trimmed.isEmpty { onRename(trimmed) }
                        }

                    Button("Save") {
                        let trimmed = editedName.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty { onRename(trimmed) }
                    }
                    .buttonStyle(ConsensusPillButtonStyle())
                }

                // Sample quote
                if !sampleQuote.isEmpty {
                    Text("\"\(sampleQuote.prefix(120))\"")
                        .font(.caption)
                        .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                        .italic()
                        .lineLimit(2)
                }
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
