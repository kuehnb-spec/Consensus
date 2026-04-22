import SwiftUI

/// Diagnostic panel for the pass currently on screen. Shows which engines
/// ran, their attribution, per-stage timings, and quality signals. Surfaced
/// as a Studio-only toolbar button that presents this as a sheet. Read-only;
/// the fields here shape how the Studio user reasons about their output.
struct PipelineInspectorView: View {
    let viewModel: DeepReadViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.lg) {
            header

            if let pass = viewModel.activePassContent {
                content(for: pass)
            } else {
                Text("No pass loaded.")
                    .foregroundStyle(ConsensusTheme.Colors.textSecondary)
            }

            Spacer(minLength: ConsensusTheme.Spacing.md)

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(ConsensusTheme.Spacing.xxl)
        .frame(width: 560, height: 520)
        .background(ConsensusTheme.Colors.background)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xs) {
            Text("Pipeline inspector")
                .font(ConsensusType.display(size: 22, weight: .semibold))
                .foregroundStyle(ConsensusTheme.Colors.textPrimary)
            if let title = viewModel.project?.title {
                Text(title)
                    .font(ConsensusType.displayCaption)
                    .foregroundStyle(ConsensusTheme.Colors.textSecondary)
            }
        }
    }

    private func content(for pass: TranscriptPass) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.lg) {
                section(title: "PASS") {
                    keyValue("Kind", pass.kind.displayName)
                    keyValue("Created", DateFormatter.localizedString(
                        from: pass.createdAt,
                        dateStyle: .short,
                        timeStyle: .medium
                    ))
                    keyValue("Segments", "\(pass.segments.count)")
                    if !pass.uncertainSegmentIndices.isEmpty {
                        keyValue(
                            "LLM-flagged",
                            "\(pass.uncertainSegmentIndices.count) of \(pass.segments.count)"
                        )
                    }
                }

                section(title: "ENGINES") {
                    keyValue("Primary", pass.engineAttribution.primaryEngine.isEmpty
                        ? "—"
                        : pass.engineAttribution.primaryEngine)
                    if !pass.engineAttribution.supportingEngines.isEmpty {
                        keyValue(
                            "Supporting",
                            pass.engineAttribution.supportingEngines.joined(separator: ", ")
                        )
                    }
                    keyValue("Diarizer", pass.engineAttribution.diarizer ?? "—")
                    keyValue("Language", pass.engineAttribution.language)
                }

                section(title: "QUALITY") {
                    if let conf = pass.quality.diarizationConfidence {
                        keyValue(
                            "Diarization confidence",
                            String(format: "%.1f%%", conf * 100)
                        )
                    }
                    keyValue("Uncertain segments", "\(pass.quality.uncertainSegmentCount)")
                }

                if !pass.quality.stageTimings.isEmpty {
                    section(title: "STAGE TIMINGS") {
                        ForEach(stageTimingsSorted(pass.quality.stageTimings), id: \.0) { stage, seconds in
                            keyValue(
                                Self.prettyStageName(stage),
                                String(format: "%.2fs", seconds),
                                valueFont: ConsensusType.monoMetric
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: - Section scaffolding

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xs) {
            Text(title)
                .font(ConsensusType.displayEyebrow)
                .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                .tracking(1.0)

            VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xs) {
                content()
            }
            .padding(ConsensusTheme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: ConsensusTheme.Radius.md, style: .continuous)
                    .fill(ConsensusTheme.Colors.surfaceSecondary.opacity(0.5))
                    .overlay(
                        RoundedRectangle(cornerRadius: ConsensusTheme.Radius.md, style: .continuous)
                            .stroke(ConsensusTheme.Colors.borderSubtle, lineWidth: 1)
                    )
            )
        }
    }

    private func keyValue(
        _ key: String,
        _ value: String,
        valueFont: Font = ConsensusType.displayBody
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: ConsensusTheme.Spacing.md) {
            Text(key)
                .font(ConsensusType.displayCaption)
                .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                .frame(width: 180, alignment: .leading)

            Text(value)
                .font(valueFont)
                .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                .textSelection(.enabled)

            Spacer(minLength: 0)
        }
    }

    // MARK: - Helpers

    private func stageTimingsSorted(_ dict: [String: Double]) -> [(String, Double)] {
        // Preserve a sensible ordering (pipeline stage order roughly), then
        // anything else alphabetical.
        let priority: [String] = [
            "modelPrep", "transcribe", "diarize", "merge",
            "whisperLoad", "whisperRun",
            "llmLoad", "llmReconcile",
            "total", "deepTotal",
        ]
        let priorityIndex = Dictionary(uniqueKeysWithValues: priority.enumerated().map { ($1, $0) })
        return dict.sorted { lhs, rhs in
            switch (priorityIndex[lhs.key], priorityIndex[rhs.key]) {
            case (let a?, let b?): return a < b
            case (_?, nil):        return true
            case (nil, _?):        return false
            default:               return lhs.key < rhs.key
            }
        }
    }

    private static func prettyStageName(_ raw: String) -> String {
        switch raw {
        case "modelPrep":     return "Model prep"
        case "transcribe":    return "Transcribe (Engine A)"
        case "diarize":       return "Diarize"
        case "merge":         return "Merge"
        case "whisperLoad":   return "Whisper load"
        case "whisperRun":    return "Whisper run (Engine B)"
        case "llmLoad":       return "LLM load"
        case "llmReconcile":  return "LLM reconcile"
        case "total":         return "Total (Standard)"
        case "deepTotal":     return "Total (Deep)"
        default:              return raw
        }
    }
}
