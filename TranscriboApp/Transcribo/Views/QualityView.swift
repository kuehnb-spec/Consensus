import SwiftUI

struct QualityView: View {
    @Environment(TranscriptionViewModel.self) private var viewModel

    var body: some View {
        @Bindable var vm = viewModel

        ScrollView {
            VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xl) {
                header

                if viewModel.pipeline.isRunning {
                    progressSection
                }

                gaugeRow
                secondaryMetricsGrid
                activePassSection
                comparisonSection
                deepReviewSection

                if !viewModel.currentWarnings.isEmpty {
                    warningsSection
                }

                passHistorySection
                flaggedSegmentsSection
            }
            .padding(ConsensusTheme.Spacing.xl)
        }
        .onChange(of: viewModel.deepReviewEngine) { _, _ in
            viewModel.persistProjectDraft()
        }
        .onChange(of: viewModel.deepReviewModel) { _, _ in
            viewModel.persistProjectDraft()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.sm) {
            Text("Quality Review")
                .font(ConsensusTheme.Fonts.title)
                .foregroundStyle(ConsensusTheme.Colors.textPrimary)

            if let activePass = viewModel.activePass,
               let currentProject = viewModel.currentProject {
                Text("\(currentProject.audioFileName) \u{2022} \(activePass.kind.displayName) \u{2022} \(activePass.modelName)")
                    .font(ConsensusTheme.Fonts.mono(.caption))
                    .foregroundStyle(ConsensusTheme.Colors.textTertiary)
            } else {
                Text("Confidence metrics and review hotspots for the active transcript.")
                    .font(ConsensusTheme.Fonts.subtitle)
                    .foregroundStyle(ConsensusTheme.Colors.textSecondary)
            }
        }
    }

    // MARK: - Progress

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.md) {
            if isIndeterminate {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(ConsensusTheme.Colors.accent)
            } else {
                ProgressView(value: viewModel.pipelineProgress)
                    .progressViewStyle(.linear)
                    .tint(ConsensusTheme.Colors.accent)
            }

            Text(viewModel.statusMessage)
                .font(ConsensusTheme.Fonts.mono(.caption))
                .foregroundStyle(ConsensusTheme.Colors.textSecondary)

            Button("Cancel", role: .cancel) {
                viewModel.cancelTranscription()
            }
            .buttonStyle(ConsensusSecondaryButtonStyle())
        }
        .consensusCard(label: "Pipeline Status", icon: "gearshape.2")
    }

    // MARK: - Circular Gauges (Top 3)

    private var gaugeRow: some View {
        HStack(spacing: ConsensusTheme.Spacing.lg) {
            CircularProgressGauge(
                title: "Word Confidence",
                value: viewModel.qualitySummary?.averageWordConfidence,
                subtitle: "Avg across all words"
            )
            CircularProgressGauge(
                title: "Segment Confidence",
                value: viewModel.qualitySummary?.averageSegmentConfidence,
                subtitle: "Avg segment confidence"
            )
            CircularProgressGauge(
                title: "Diarization Quality",
                value: viewModel.qualitySummary?.averageDiarizationQuality,
                subtitle: "Speaker assignment quality"
            )
        }
    }

    // MARK: - Secondary Metrics (Remaining 6)

    private var secondaryMetricsGrid: some View {
        let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

        return LazyVGrid(columns: columns, spacing: ConsensusTheme.Spacing.md) {
            QualityMetricCard(
                title: "Avg Log Prob",
                value: Self.number(viewModel.qualitySummary?.averageLogProb),
                subtitle: "Decoder confidence signal"
            )
            QualityMetricCard(
                title: "Compression Ratio",
                value: Self.number(viewModel.qualitySummary?.averageCompressionRatio),
                subtitle: "High values may indicate repetition"
            )
            QualityMetricCard(
                title: "No-Speech Prob",
                value: Self.percent(viewModel.qualitySummary?.averageNoSpeechProbability),
                subtitle: "Avg silence probability"
            )
            QualityMetricCard(
                title: "Low-Confidence Words",
                value: Self.count(viewModel.qualitySummary?.lowConfidenceWordCount),
                subtitle: "Words below review threshold"
            )
            QualityMetricCard(
                title: "Flagged Segments",
                value: Self.count(viewModel.qualitySummary?.lowConfidenceSegmentCount),
                subtitle: "Weak transcript confidence"
            )
            QualityMetricCard(
                title: "Unknown Speakers",
                value: Self.count(viewModel.qualitySummary?.unknownSpeakerSegmentCount),
                subtitle: "No confident speaker assigned"
            )
        }
    }

    // MARK: - Active Pass

    private var activePassSection: some View {
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.md) {
            if let activePass = viewModel.activePass {
                let columns = [GridItem(.flexible()), GridItem(.flexible())]

                LazyVGrid(columns: columns, spacing: ConsensusTheme.Spacing.md) {
                    DetailLine(title: "Pass Type", value: activePass.kind.displayName)
                    DetailLine(title: "Created", value: Self.date(activePass.createdAt))
                    DetailLine(title: "Engine", value: activePass.engineName)
                    DetailLine(title: "Model", value: activePass.modelName)
                    DetailLine(title: "Language", value: activePass.language.uppercased())
                    DetailLine(title: "Speakers", value: Self.speakerRange(min: activePass.minSpeakers, max: activePass.maxSpeakers))
                }
            } else {
                Text("Run a transcription to see pass-level quality details.")
                    .foregroundStyle(ConsensusTheme.Colors.textSecondary)
            }
        }
        .consensusCard(label: "Active Pass", icon: "doc.text")
    }

    // MARK: - Deep Review

    private var deepReviewSection: some View {
        @Bindable var vm = viewModel

        return VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.md) {
            Text("Deep Review verifies your transcript in four guided steps: second-engine transcription, multi-pass speaker detection, speaker confirmation, and final review with optional AI polish.")
                .font(ConsensusTheme.Fonts.caption)
                .foregroundStyle(ConsensusTheme.Colors.textSecondary)

            VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xs) {
                Label("Step 1: Re-transcribe with a second engine and merge results", systemImage: "doc.on.doc")
                Label("Step 2: Multi-pass diarization with AI speaker resolution", systemImage: "person.2.wave.2")
                Label("Step 3: Confirm speaker names", systemImage: "person.badge.check")
                Label("Step 4: Review final transcript and export", systemImage: "checkmark.seal")
            }
            .font(ConsensusTheme.Fonts.caption)
            .foregroundStyle(ConsensusTheme.Colors.textSecondary)

            Button {
                viewModel.currentPhase = .deepTranscription
            } label: {
                Label("Start Deep Review", systemImage: "sparkles.rectangle.stack")
            }
            .buttonStyle(ConsensusPrimaryButtonStyle())
            .disabled(!viewModel.canRunDeepReview || viewModel.pipeline.isRunning)
        }
        .consensusCard(label: "Deep Review", icon: "sparkles.rectangle.stack")
    }

    // MARK: - Pass Comparison

    private var comparisonSection: some View {
        Group {
            if let summary = viewModel.passComparisonSummary {
                VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.lg) {
                    Text("Comparing \(summary.candidateLabel) against \(summary.referenceLabel).")
                        .font(ConsensusTheme.Fonts.caption)
                        .foregroundStyle(ConsensusTheme.Colors.textSecondary)

                    // Heatmap
                    if !summary.disagreements.isEmpty,
                       let project = viewModel.currentProject {
                        DisagreementHeatmapView(
                            disagreements: summary.disagreements,
                            audioDuration: project.audioDuration
                        )
                    }

                    let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

                    LazyVGrid(columns: columns, spacing: ConsensusTheme.Spacing.md) {
                        QualityMetricCard(
                            title: "Text Agreement",
                            value: Self.percent(summary.textAgreementRate),
                            subtitle: "Paired segments match"
                        )
                        QualityMetricCard(
                            title: "Speaker Agreement",
                            value: Self.percent(summary.speakerAgreementRate),
                            subtitle: "Speaker labels align"
                        )
                        QualityMetricCard(
                            title: "Disputed Segments",
                            value: "\(summary.disputedSegmentCount)",
                            subtitle: "Need review"
                        )
                        QualityMetricCard(
                            title: "Confidence Delta",
                            value: Self.delta(summary.confidenceDelta),
                            subtitle: "Word confidence change"
                        )
                        QualityMetricCard(
                            title: "Diarization Delta",
                            value: Self.delta(summary.diarizationQualityDelta),
                            subtitle: "Diarization quality change"
                        )
                        QualityMetricCard(
                            title: "Compared Segments",
                            value: "\(summary.comparedSegmentCount)",
                            subtitle: "In this comparison"
                        )
                    }

                    HStack {
                        Spacer()
                        Button {
                            viewModel.openReconciliation()
                        } label: {
                            Label("Open Reconciliation Workspace", systemImage: "rectangle.split.3x1")
                        }
                        .buttonStyle(ConsensusPrimaryButtonStyle())
                    }

                    if summary.disagreements.isEmpty {
                        Text("These two passes align closely in the current comparison.")
                            .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                    } else {
                        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.md) {
                            Text("Disagreement Hotspots")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(ConsensusTheme.Colors.textPrimary)

                            ForEach(summary.disagreements) { disagreement in
                                VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xs) {
                                    HStack {
                                        Text(disagreement.kind.displayName)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                                        Spacer()
                                        Text("\(TimeFormatting.timestamp(disagreement.start)) - \(TimeFormatting.timestamp(disagreement.end))")
                                            .font(ConsensusTheme.Fonts.mono(.caption2))
                                            .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                                    }

                                    if let referenceText = disagreement.referenceText {
                                        Text("Reference: \(referenceText)")
                                            .font(ConsensusTheme.Fonts.caption)
                                            .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                                    }

                                    if let candidateText = disagreement.candidateText {
                                        Text("Candidate: \(candidateText)")
                                            .font(ConsensusTheme.Fonts.caption)
                                            .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                                    }

                                    if let referenceSpeakerID = disagreement.referenceSpeakerID,
                                       let candidateSpeakerID = disagreement.candidateSpeakerID,
                                       referenceSpeakerID != candidateSpeakerID {
                                        Text("Speakers: \(referenceSpeakerID) vs \(candidateSpeakerID)")
                                            .font(ConsensusTheme.Fonts.mono(.caption2))
                                            .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                                    }
                                }

                                if disagreement.id != summary.disagreements.last?.id {
                                    Divider()
                                        .overlay(ConsensusTheme.Colors.border)
                                }
                            }
                        }
                    }
                }
                .consensusCard(label: "Pass Comparison", icon: "arrow.left.arrow.right")
            }
        }
    }

    // MARK: - Warnings

    private var warningsSection: some View {
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.md) {
            ForEach(viewModel.currentWarnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(ConsensusTheme.Fonts.caption)
                    .foregroundStyle(ConsensusTheme.Colors.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .consensusCard(label: "Pipeline Warnings", icon: "exclamationmark.triangle")
    }

    // MARK: - Pass History

    private var passHistorySection: some View {
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.md) {
            if viewModel.passHistory.isEmpty {
                Text("No saved passes yet.")
                    .foregroundStyle(ConsensusTheme.Colors.textSecondary)
            } else {
                ForEach(viewModel.passHistory) { pass in
                    PassHistoryRow(
                        pass: pass,
                        isActive: pass.id == viewModel.activePass?.id,
                        onSelect: {
                            viewModel.selectPass(id: pass.id)
                        }
                    )

                    if pass.id != viewModel.passHistory.last?.id {
                        Divider()
                            .overlay(ConsensusTheme.Colors.border)
                    }
                }
            }
        }
        .consensusCard(label: "Pass History", icon: "clock.arrow.circlepath")
    }

    // MARK: - Flagged Segments

    private var flaggedSegmentsSection: some View {
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.md) {
            if viewModel.qualityFlags.isEmpty {
                Text("No major hotspots were detected in the current transcript.")
                    .foregroundStyle(ConsensusTheme.Colors.textSecondary)
            } else {
                ForEach(viewModel.qualityFlags) { flag in
                    VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xs) {
                        HStack {
                            Text(flag.kind.displayName)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                            Spacer()
                            Text("\(TimeFormatting.timestamp(flag.start)) - \(TimeFormatting.timestamp(flag.end))")
                                .font(ConsensusTheme.Fonts.mono(.caption2))
                                .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                        }

                        Text(flag.message)
                            .font(ConsensusTheme.Fonts.caption)
                            .foregroundStyle(ConsensusTheme.Colors.textSecondary)

                        if let observed = flag.observedValue {
                            Text("Observed: \(Self.percent(observed))")
                                .font(ConsensusTheme.Fonts.mono(.caption2))
                                .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                        }

                        Text(flag.snippet)
                            .font(ConsensusTheme.Fonts.caption)
                            .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, ConsensusTheme.Spacing.xs)

                    if flag.id != viewModel.qualityFlags.last?.id {
                        Divider()
                            .overlay(ConsensusTheme.Colors.border)
                    }
                }
            }
        }
        .consensusCard(label: "Review Hotspots", icon: "flag")
    }

    // MARK: - Helpers

    private var isIndeterminate: Bool {
        switch viewModel.pipeline.state {
        case .downloadingModel(let progress) where progress >= 1.0:
            return true
        case .diarizing, .mergingResults, .loadingAudio:
            return true
        default:
            return false
        }
    }

    fileprivate static func percent(_ value: Float?) -> String {
        guard let value else { return "\u{2014}" }
        return "\(Int((Double(value) * 100).rounded()))%"
    }

    fileprivate static func delta(_ value: Float?) -> String {
        guard let value else { return "\u{2014}" }
        let percentage = Int((Double(value) * 100).rounded())
        return percentage >= 0 ? "+\(percentage)%" : "\(percentage)%"
    }

    private static func count(_ value: Int?) -> String {
        guard let value else { return "\u{2014}" }
        return "\(value)"
    }

    private static func number(_ value: Float?) -> String {
        guard let value else { return "\u{2014}" }
        return String(format: "%.2f", value)
    }

    private static func speakerRange(min: Int?, max: Int?) -> String {
        switch (min, max) {
        case let (min?, max?):
            return "\(min)-\(max)"
        case let (min?, nil):
            return "\(min)+"
        case let (nil, max?):
            return "up to \(max)"
        case (nil, nil):
            return "Auto"
        }
    }

    private static func date(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

// MARK: - Supporting Views

private struct QualityMetricCard: View {
    let title: String
    let value: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.sm) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(ConsensusTheme.Colors.textSecondary)
            Text(value)
                .font(ConsensusTheme.Fonts.mono(size: 20, weight: .bold))
                .foregroundStyle(ConsensusTheme.Colors.textPrimary)
            Text(subtitle)
                .font(ConsensusTheme.Fonts.caption)
                .foregroundStyle(ConsensusTheme.Colors.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ConsensusTheme.Spacing.lg)
        .background {
            RoundedRectangle(cornerRadius: ConsensusTheme.Radius.lg)
                .fill(ConsensusTheme.Colors.surfacePrimary)
                .overlay {
                    RoundedRectangle(cornerRadius: ConsensusTheme.Radius.lg)
                        .stroke(ConsensusTheme.Colors.border, lineWidth: 1)
                }
        }
    }
}

private struct DetailLine: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xs) {
            Text(title)
                .font(ConsensusTheme.Fonts.mono(.caption2))
                .foregroundStyle(ConsensusTheme.Colors.textTertiary)
            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(ConsensusTheme.Colors.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PassHistoryRow: View {
    let pass: TranscriptionPass
    let isActive: Bool
    let onSelect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.sm) {
            HStack {
                VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xs) {
                    Text("\(pass.kind.displayName) \u{2022} \(pass.modelName)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                    Text(pass.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(ConsensusTheme.Fonts.mono(.caption2))
                        .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                }

                Spacer()

                if isActive {
                    Text("Active")
                        .font(ConsensusTheme.Fonts.mono(.caption2).bold())
                        .foregroundStyle(ConsensusTheme.Colors.confidenceGreen)
                } else {
                    Button("Use Pass") {
                        onSelect()
                    }
                    .buttonStyle(ConsensusPillButtonStyle())
                }
            }

            HStack(spacing: ConsensusTheme.Spacing.md) {
                Label(QualityView.percent(pass.qualitySummary.averageWordConfidence), systemImage: "waveform.badge.magnifyingglass")
                Label(QualityView.percent(pass.qualitySummary.averageDiarizationQuality), systemImage: "person.2.badge.gearshape")
                Label("\(pass.qualitySummary.riskySegments.count) flags", systemImage: "flag")
            }
            .font(ConsensusTheme.Fonts.mono(.caption2))
            .foregroundStyle(ConsensusTheme.Colors.textTertiary)
        }
    }
}
