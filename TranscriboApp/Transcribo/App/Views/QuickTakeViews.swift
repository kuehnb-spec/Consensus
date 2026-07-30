import SwiftUI

// MARK: - Convergence mark

/// The Consensus identity motif: separate strands — one per voice in the
/// deliberation — drifting left to right until they converge into a single
/// line. Doubles as the Quick Take progress element: `progress` pulls the
/// convergence point from the far right edge (0, "still arguing") toward
/// the left (1, "consensus reached").
///
/// Drawn with `Canvas` inside a `TimelineView` so the strands breathe
/// slowly while work is underway. With `animates == false` it renders a
/// static mark suitable for headers and dividers.
struct ConvergenceMark: View {
    /// 0...1. How much of the width the strands have already merged over.
    var progress: Double
    /// Whether the strands drift. Turn off for static/ornamental use.
    var animates: Bool = true

    private static let strandPhases: [Double] = [0.0, 2.1, 4.2]

    var body: some View {
        if animates {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                canvas(time: context.date.timeIntervalSinceReferenceDate)
            }
        } else {
            canvas(time: 0)
        }
    }

    private func canvas(time: TimeInterval) -> some View {
        Canvas { context, size in
            let width = size.width
            let height = size.height
            let midY = height / 2

            // The x past which all strands ride the same line. progress 0
            // keeps it just off-canvas right; progress 1 brings it to 12%.
            let clamped = max(0, min(1, progress))
            let convergeX = width * (1.08 - 0.96 * clamped)

            let strandColors: [Color] = [
                ConsensusTheme.Colors.accent,
                ConsensusTheme.Colors.confidenceGreen,
                ConsensusTheme.Colors.textSecondary
            ]
            let baseAmplitude = height * 0.30

            for (index, phase) in Self.strandPhases.enumerated() {
                var path = Path()
                let spread = Double(index) - 1.0   // -1, 0, +1
                let steps = max(48, Int(width / 4))

                for step in 0...steps {
                    let x = width * Double(step) / Double(steps)
                    // How "apart" the strands still are at this x: full
                    // separation on the left, zero at and past the merge point.
                    let separation = smoothstep(1 - min(1, x / max(convergeX, 1)))
                    let drift = animates ? time * 0.9 : 0
                    let wave = sin(x / width * 4.6 + phase + drift)
                        + 0.4 * sin(x / width * 9.2 - phase + drift * 1.4)
                    let offset = separation * (spread * height * 0.26 + wave * baseAmplitude * 0.35)
                    // The merged line keeps one shared, nearly-flat wobble.
                    let merged = (1 - separation) * sin(x / width * 3.0 + drift * 0.5) * 0.8
                    let y = midY + offset + merged

                    if step == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }

                context.stroke(
                    path,
                    with: .color(strandColors[index % strandColors.count].opacity(0.62)),
                    style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Cubic smoothstep on 0...1 — keeps the merge organic, not conical.
    private func smoothstep(_ t: Double) -> Double {
        let x = max(0, min(1, t))
        return x * x * (3 - 2 * x)
    }
}

// MARK: - Quick Take progress

/// The calm, appliance-grade progress screen. One title, one human-language
/// status line, the convergence mark doing the storytelling, and a quiet
/// percentage. Deliberately no token counts, engine names, or metric tiles —
/// that theater belongs to Deep Read and Studio.
struct QuickTakeProgressView: View {
    enum Phase {
        /// The draft transcription pass.
        case listening
        /// The patch-review pass (second opinions + audio re-checks).
        case doubleChecking

        var statusLine: String {
            switch self {
            case .listening:      return "Listening to the recording"
            case .doubleChecking: return "Double-checking the tricky spots"
            }
        }

        /// The mark's convergence budget: the draft pass carries it partway,
        /// the verification pass brings it home.
        var progressRange: ClosedRange<Double> {
            switch self {
            case .listening:      return 0.05...0.55
            case .doubleChecking: return 0.55...0.96
            }
        }
    }

    let title: String
    let phase: Phase
    /// Pipeline fraction 0...1 for the current phase, if known.
    let fraction: Double?

    private var markProgress: Double {
        let range = phase.progressRange
        let f = max(0, min(1, fraction ?? 0))
        return range.lowerBound + (range.upperBound - range.lowerBound) * f
    }

    var body: some View {
        VStack(spacing: ConsensusTheme.Spacing.xl) {
            Spacer()

            ConvergenceMark(progress: markProgress)
                .frame(width: 440, height: 120)

            VStack(spacing: ConsensusTheme.Spacing.sm) {
                Text(title)
                    .font(ConsensusType.display(size: 22, weight: .semibold))
                    .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 480)

                HStack(spacing: ConsensusTheme.Spacing.sm) {
                    Text(phase.statusLine)
                        .font(ConsensusType.displayBody)
                        .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                    if let fraction {
                        Text("\(Int((max(0, min(1, fraction)) * 100).rounded()))%")
                            .font(ConsensusType.monoMetric)
                            .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                            .monospacedDigit()
                    }
                }
            }

            Spacer()

            Text("You can leave this window — the transcript will be here.")
                .font(ConsensusType.displayCaption)
                .foregroundStyle(ConsensusTheme.Colors.textMuted)
                .padding(.bottom, ConsensusTheme.Spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Quick Take result

/// The finished-transcript screen for the pushbutton flow: a readable
/// document with inline speaker rename, and a single always-visible action
/// bar. No review chrome, no metrics — the escape hatch into the full
/// workstation is one quiet button.
struct QuickTakeResultView: View {
    @Bindable var viewModel: DeepReadViewModel

    @State private var renamingSpeakerID: String?
    @State private var renameDraft: String = ""
    @State private var showingExportSheet: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xl) {
                header

                if let pass = viewModel.activePassContent {
                    if pass.segments.isEmpty {
                        emptyMessage
                    } else {
                        LazyVStack(alignment: .leading, spacing: ConsensusTheme.Spacing.lg) {
                            ForEach(Array(pass.segments.enumerated()), id: \.offset) { _, segment in
                                turnRow(segment: segment)
                            }
                        }
                    }
                } else {
                    ProgressView("Loading transcript…")
                        .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                        .padding(ConsensusTheme.Spacing.xxl)
                }
            }
            .padding(.horizontal, ConsensusTheme.Spacing.xxl)
            .padding(.top, ConsensusTheme.Spacing.xl)
            .padding(.bottom, ConsensusTheme.Spacing.xxl)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .safeAreaInset(edge: .bottom) { actionBar }
        .background(ConsensusTheme.Colors.background)
        .sheet(isPresented: $showingExportSheet) {
            ExportSheet(viewModel: viewModel)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.sm) {
            ConvergenceMark(progress: 1, animates: false)
                .frame(width: 96, height: 18)

            Text(viewModel.project?.title ?? "Transcript")
                .font(ConsensusType.display(size: 26, weight: .semibold))
                .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                .lineLimit(2)
                .truncationMode(.middle)

            HStack(spacing: ConsensusTheme.Spacing.sm) {
                if let duration = viewModel.project?.audio.durationSeconds {
                    Text(Self.formatDuration(duration))
                        .font(ConsensusType.monoMetric)
                }
                if let count = viewModel.project?.speakers.count, count > 0 {
                    Text("·")
                        .foregroundStyle(ConsensusTheme.Colors.textMuted)
                    Text(count == 1 ? "1 speaker" : "\(count) speakers")
                        .font(ConsensusType.displayCaption)
                }
                Text("·")
                    .foregroundStyle(ConsensusTheme.Colors.textMuted)
                Text("Click a name to change it")
                    .font(ConsensusType.displayCaption)
            }
            .foregroundStyle(ConsensusTheme.Colors.textSecondary)
        }
    }

    // MARK: Turn rows

    private func turnRow(segment: TranscriptionSegment) -> some View {
        let speaker = viewModel.project?.speakers.first { $0.id == segment.speakerID }
        let palette = ConsensusTheme.Colors.speakerPalette
        let color = palette[(speaker?.paletteIndex ?? 0) % palette.count]
        let displayName = speaker?.displayName ?? segment.speakerID

        return VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xs) {
            HStack(spacing: ConsensusTheme.Spacing.sm) {
                Circle()
                    .fill(color)
                    .frame(width: 9, height: 9)

                Button {
                    renameDraft = displayName
                    renamingSpeakerID = segment.speakerID
                } label: {
                    Text(displayName)
                        .font(ConsensusType.transcriptSpeaker)
                        .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                }
                .buttonStyle(.plain)
                .help("Rename this speaker")
                .popover(
                    isPresented: Binding(
                        get: { renamingSpeakerID == segment.speakerID },
                        set: { if !$0 { renamingSpeakerID = nil } }
                    ),
                    arrowEdge: .bottom
                ) {
                    renamePopover(speakerID: segment.speakerID)
                }

                Text(Self.formatTimestamp(segment.start))
                    .font(ConsensusType.monoTimestamp)
                    .foregroundStyle(ConsensusTheme.Colors.textTertiary)

                Spacer()
            }

            Text(segment.text)
                .font(ConsensusType.transcriptReader)
                .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                .lineSpacing(4)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func renamePopover(speakerID: String) -> some View {
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.sm) {
            Text("SPEAKER NAME")
                .font(ConsensusType.displayEyebrow)
                .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                .tracking(1.0)

            TextField("Name", text: $renameDraft)
                .textFieldStyle(.roundedBorder)
                .font(ConsensusType.displayBody)
                .frame(width: 220)
                .onSubmit { commitRename(speakerID: speakerID) }

            HStack {
                Spacer()
                Button("Rename") { commitRename(speakerID: speakerID) }
                    .buttonStyle(.borderedProminent)
                    .tint(ConsensusTheme.Colors.accent)
                    .disabled(renameDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(ConsensusTheme.Spacing.lg)
    }

    private func commitRename(speakerID: String) {
        viewModel.renameSpeaker(id: speakerID, to: renameDraft)
        renamingSpeakerID = nil
    }

    // MARK: Action bar

    private var actionBar: some View {
        HStack(spacing: ConsensusTheme.Spacing.md) {
            Menu {
                Button("Legal PDF…") {
                    _ = viewModel.exportToFile(
                        format: .legalPDF,
                        legalPDFOptions: viewModel.defaultLegalPDFOptions(includeSummary: false)
                    )
                }
                Button("Markdown…") { _ = viewModel.exportToFile(format: .md) }
                Button("Plain text…") { _ = viewModel.exportToFile(format: .txt) }
                Divider()
                Button("More formats…") { showingExportSheet = true }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
                    .font(ConsensusType.displayBody.weight(.semibold))
                    .padding(.horizontal, ConsensusTheme.Spacing.sm)
                    .padding(.vertical, 3)
            }
            .menuStyle(.button)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(ConsensusTheme.Colors.accent)

            Button {
                viewModel.copyToPasteboard(format: .md)
            } label: {
                Label(
                    viewModel.copyConfirmationVisible ? "Copied" : "Copy",
                    systemImage: viewModel.copyConfirmationVisible ? "checkmark" : "doc.on.doc"
                )
                .font(ConsensusType.displayBody)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Spacer()

            Button {
                viewModel.setMode(.deepRead)
            } label: {
                HStack(spacing: ConsensusTheme.Spacing.xs) {
                    Image(systemName: "book.closed")
                        .font(.system(size: 11, weight: .medium))
                    Text("Fine-tune in Deep Read")
                        .font(ConsensusType.displayCaption.weight(.medium))
                }
                .foregroundStyle(ConsensusTheme.Colors.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Open this transcript in the full review workspace")
        }
        .padding(.horizontal, ConsensusTheme.Spacing.xl)
        .padding(.vertical, ConsensusTheme.Spacing.md)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(ConsensusTheme.Colors.border)
                .frame(height: 1)
        }
    }

    // MARK: Empty state

    private var emptyMessage: some View {
        VStack(spacing: ConsensusTheme.Spacing.md) {
            Image(systemName: "waveform.slash")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(ConsensusTheme.Colors.textTertiary)
            Text("No speech detected")
                .font(ConsensusType.displaySubheading)
                .foregroundStyle(ConsensusTheme.Colors.textPrimary)
            Text("The recording didn't produce any transcribable speech. Check the source audio and try again.")
                .font(ConsensusType.displayCaption)
                .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(ConsensusTheme.Spacing.xxl)
    }

    // MARK: Formatters

    private static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    private static func formatTimestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}
