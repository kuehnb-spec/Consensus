import SwiftUI

struct WelcomeTourView: View {
    @Environment(TranscriptionViewModel.self) private var viewModel
    @State private var currentStep = 0

    private let steps: [WelcomeStep] = [
        WelcomeStep(
            title: "Local From The Start",
            subtitle: "Consensus keeps transcription, diarization, and saved projects on your Mac.",
            systemImage: "lock.shield",
            tint: ConsensusTheme.Colors.accent,
            bullets: [
                "Import audio and create a saved project immediately.",
                "Export is a copy of your work, not the only place your transcript exists.",
                "You can reopen projects later to relabel speakers, rerun Deep Review, and export again."
            ]
        ),
        WelcomeStep(
            title: "Standard Workflow",
            subtitle: "Most recordings should succeed with a single transcription pass.",
            systemImage: "waveform",
            tint: ConsensusTheme.Colors.confidenceGreen,
            bullets: [
                "Import audio and run a standard transcript.",
                "Check Quality for confidence, diarization quality, and hotspots.",
                "Rename speakers and review the transcript before exporting."
            ]
        ),
        WelcomeStep(
            title: "Deep Review When It Matters",
            subtitle: "For hard audio or high-stakes work, run a second pass and reconcile in context.",
            systemImage: "rectangle.split.3x1",
            tint: ConsensusTheme.Colors.confidenceAmber,
            bullets: [
                "Deep Review saves a comparison pass next to the original transcript.",
                "Reconcile shows both transcripts in a unified diff view with inline disagreement highlighting.",
                "Sentence-break disagreements stay visible in context instead of being hidden in tiny snippets."
            ]
        ),
        WelcomeStep(
            title: "Try It Two Ways",
            subtitle: "Start with your own audio or open the built-in demo project to explore safely.",
            systemImage: "play.rectangle",
            tint: ConsensusTheme.Colors.diffSpeakerSolid,
            bullets: [
                "Browse Audio starts a real project with your own recording.",
                "Open Demo Project loads a prebuilt sample with saved passes and reconciliation data.",
                "The demo does not include source audio, so playback is intentionally unavailable there."
            ]
        )
    ]

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.sm) {
                Text("Welcome To Consensus")
                    .font(ConsensusTheme.Fonts.title)
                    .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                Text("A quick tour of the workflow, then you can jump straight into real audio or the built-in demo.")
                    .font(ConsensusTheme.Fonts.subtitle)
                    .foregroundStyle(ConsensusTheme.Colors.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(ConsensusTheme.Spacing.xl)

            Divider()
                .overlay(ConsensusTheme.Colors.border)

            WelcomeStepCard(step: steps[currentStep])
                .padding(28)

            HStack(spacing: ConsensusTheme.Spacing.sm) {
                ForEach(Array(steps.indices), id: \.self) { index in
                    Capsule()
                        .fill(index == currentStep ? steps[currentStep].tint : ConsensusTheme.Colors.textMuted)
                        .frame(width: index == currentStep ? 28 : 10, height: 10)
                }
            }
            .padding(.bottom, ConsensusTheme.Spacing.lg)

            Divider()
                .overlay(ConsensusTheme.Colors.border)

            footer
                .padding(ConsensusTheme.Spacing.xl)
        }
        .background(ConsensusTheme.Colors.background)
        .frame(width: 820, height: 620)
    }

    private var footer: some View {
        HStack(spacing: ConsensusTheme.Spacing.md) {
            Button("Not Now") {
                viewModel.completeWelcomeTour()
            }
            .buttonStyle(ConsensusGhostButtonStyle())

            if currentStep > 0 {
                Button("Back") {
                    withAnimation(.snappy(duration: 0.2)) {
                        currentStep -= 1
                    }
                }
                .buttonStyle(ConsensusSecondaryButtonStyle())
            }

            Spacer()

            Button {
                viewModel.completeWelcomeTour()
                viewModel.openHelpCenter()
            } label: {
                Label("Open Help Center", systemImage: "questionmark.circle")
            }
            .buttonStyle(ConsensusSecondaryButtonStyle())

            Button {
                Task {
                    await viewModel.loadDemoProject()
                }
            } label: {
                Label("Open Demo Project", systemImage: "play.rectangle")
            }
            .buttonStyle(ConsensusSecondaryButtonStyle())

            Button {
                viewModel.openAudioPickerFromWelcomeTour()
            } label: {
                Label("Browse Audio", systemImage: "waveform.badge.plus")
            }
            .buttonStyle(ConsensusPrimaryButtonStyle())

            if currentStep < steps.count - 1 {
                Button("Next") {
                    withAnimation(.snappy(duration: 0.2)) {
                        currentStep += 1
                    }
                }
                .buttonStyle(ConsensusSecondaryButtonStyle())
            }
        }
    }
}

private struct WelcomeStep {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    let bullets: [String]
}

private struct WelcomeStepCard: View {
    let step: WelcomeStep

    var body: some View {
        HStack(spacing: 28) {
            VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xl) {
                Image(systemName: step.systemImage)
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(step.tint)
                    .frame(width: 82, height: 82)
                    .background(step.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: ConsensusTheme.Radius.xl))

                Text(step.title)
                    .font(.title.bold())
                    .foregroundStyle(ConsensusTheme.Colors.textPrimary)

                Text(step.subtitle)
                    .font(.title3)
                    .foregroundStyle(ConsensusTheme.Colors.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

            VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.lg) {
                ForEach(step.bullets, id: \.self) { bullet in
                    HStack(alignment: .top, spacing: ConsensusTheme.Spacing.md) {
                        RoundedRectangle(cornerRadius: 999)
                            .fill(step.tint)
                            .frame(width: 8, height: 8)
                            .padding(.top, 7)

                        Text(bullet)
                            .font(ConsensusTheme.Fonts.body)
                            .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(ConsensusTheme.Spacing.xl)
            .background {
                RoundedRectangle(cornerRadius: ConsensusTheme.Radius.xl)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: ConsensusTheme.Radius.xl)
                            .stroke(ConsensusTheme.Colors.border, lineWidth: 1)
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
