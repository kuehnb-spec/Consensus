import SwiftUI

struct TranscriptView: View {
    @Environment(TranscriptionViewModel.self) private var viewModel

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

                Button {
                    viewModel.currentPhase = .quality
                } label: {
                    Label("Quality", systemImage: "gauge.with.dots.needle.50percent")
                }
                .disabled(!viewModel.hasResult)

                Button {
                    viewModel.currentPhase = .quality
                    Task {
                        await viewModel.startDeepReview()
                    }
                } label: {
                    Label("Deep Review", systemImage: "sparkles.rectangle.stack")
                }
                .disabled(!viewModel.canRunDeepReview || viewModel.pipeline.isRunning)

                Button {
                    viewModel.openReconciliation()
                } label: {
                    Label("Reconcile", systemImage: "rectangle.split.3x1")
                }
                .disabled(!viewModel.canOpenReconciliation)

                Button {
                    viewModel.currentPhase = .export
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(!viewModel.hasResult)
            }
        }
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
                }
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
                        let segments = result.segments

                        ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                            let displayName = viewModel.speakerMapping.displayName(for: segment.speakerID)
                            let color = SpeakerBadge.color(for: segment.speakerID, in: speakers)
                            let isNewSpeaker = index == 0 || segment.speakerID != segments[index - 1].speakerID

                            SegmentRow(
                                segment: segment,
                                displayName: displayName,
                                speakerColor: color,
                                showSpeakerHeader: isNewSpeaker
                            )
                        }
                    }
                }
                .padding(ConsensusTheme.Spacing.xl)
            }
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
