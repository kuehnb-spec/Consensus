import AppKit
import SwiftUI

struct HelpCenterView: View {
    @Environment(TranscriptionViewModel.self) private var viewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xl) {
                header
                quickActions
                gettingStarted
                deepReview
                exportsAndProjects
                troubleshooting
                privacyAndStorage
            }
            .padding(ConsensusTheme.Spacing.xl)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.sm) {
            Text("Help Center")
                .font(ConsensusTheme.Fonts.title)
                .foregroundStyle(ConsensusTheme.Colors.textPrimary)
            Text("Everything a new user needs to get from first launch to a clean exported transcript.")
                .font(ConsensusTheme.Fonts.subtitle)
                .foregroundStyle(ConsensusTheme.Colors.textSecondary)
        }
    }

    private var quickActions: some View {
        HelpSectionCard(title: "Quick Actions", systemImage: "bolt.circle") {
            HStack(spacing: ConsensusTheme.Spacing.md) {
                QuickActionButton(
                    title: "Browse Audio",
                    subtitle: "Start a real transcript",
                    systemImage: "waveform.badge.plus",
                    tint: ConsensusTheme.Colors.accent
                ) {
                    viewModel.currentPhase = .setup
                    viewModel.showFilePicker = true
                }

                QuickActionButton(
                    title: "Welcome Tour",
                    subtitle: "Replay the guided intro",
                    systemImage: "sparkles",
                    tint: ConsensusTheme.Colors.confidenceAmber
                ) {
                    viewModel.presentWelcomeTour()
                }

                QuickActionButton(
                    title: "Demo Project",
                    subtitle: "Explore without models",
                    systemImage: "play.rectangle",
                    tint: ConsensusTheme.Colors.confidenceGreen
                ) {
                    Task {
                        await viewModel.loadDemoProject()
                    }
                }

                QuickActionButton(
                    title: "Settings",
                    subtitle: "Adjust defaults",
                    systemImage: "gearshape",
                    tint: ConsensusTheme.Colors.diffSpeakerSolid
                ) {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
            }
        }
    }

    private var gettingStarted: some View {
        HelpSectionCard(title: "Getting Started", systemImage: "figure.walk") {
            VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.lg) {
                HelpStep(
                    number: 1,
                    title: "Import audio",
                    detail: "Choose an audio file from the setup screen. The app validates the file and creates a saved project immediately so your work does not disappear after export."
                )
                HelpStep(
                    number: 2,
                    title: "Run a standard transcript",
                    detail: "The default path uses WhisperKit for transcription and FluidAudio for speaker diarization. The current default model is Small so first launch stays lightweight."
                )
                HelpStep(
                    number: 3,
                    title: "Review quality before exporting",
                    detail: "Open Quality to inspect confidence, diarization quality, and flagged hotspots. Most audio should be fine after a standard pass."
                )
                HelpStep(
                    number: 4,
                    title: "Escalate to Deep Review when needed",
                    detail: "If the audio is messy or high stakes, run Deep Review. The app saves the second pass alongside the first and lets you compare them in context."
                )
            }
        }
    }

    private var deepReview: some View {
        HelpSectionCard(title: "Deep Review And Reconcile", systemImage: "rectangle.split.3x1") {
            VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.md) {
                HelpBullet(text: "Deep Review runs a second pass, currently using Parakeet v3 by default, and saves it as another pass in the same project.")
                HelpBullet(text: "The Reconcile workspace shows both transcripts in a unified diff view so you can compare them in context.")
                HelpBullet(text: "Disagreements are grouped into time-aligned blocks so punctuation-only differences stay visible in context instead of turning into confusing mini-snippets.")
                HelpBullet(text: "Use `Use A`, `Use B`, or edit the final text manually. Keyboard shortcuts: [1] for A, [2] for B, [Space] to play context audio, [Return] to jump to the next unresolved block.")
                HelpBullet(text: "If the source audio is available, `Play Context` plays five seconds before and after the current block.")
            }
        }
    }

    private var exportsAndProjects: some View {
        HelpSectionCard(title: "Projects And Exports", systemImage: "folder.badge.person.crop") {
            VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.md) {
                HelpBullet(text: "Every transcript is saved as a project inside Application Support. Exporting creates copies; it does not remove the in-app project.")
                HelpBullet(text: "You can reopen any saved project, rename speakers, rerun Deep Review, save a new consensus, or export again later.")
                HelpBullet(text: "Current export formats include text, Markdown, JSON, SRT, RTF, DOCX, and legal-style PDF.")
                HelpBullet(text: "The built-in demo project is safe to explore. It ships without source audio, so playback is unavailable there by design.")
            }
        }
    }

    private var troubleshooting: some View {
        HelpSectionCard(title: "Troubleshooting", systemImage: "wrench.and.screwdriver") {
            VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.md) {
                HelpFAQ(
                    question: "Why is the first run slower?",
                    answer: "The first time you use a model, macOS may need to download and compile it. After that, standard runs should be much faster."
                )
                HelpFAQ(
                    question: "Why can't I play audio in a saved project?",
                    answer: "If the source file moved or macOS revoked access, playback cannot reopen it. Re-import the audio or keep the original file in place."
                )
                HelpFAQ(
                    question: "Why are there unknown speakers?",
                    answer: "Unknown speakers usually mean the diarizer could not assign a segment confidently. Use Quality to spot those segments and Deep Review to gather a second opinion."
                )
                HelpFAQ(
                    question: "Why does Deep Review sometimes disagree only on punctuation?",
                    answer: "Different engines often segment sentences differently. The reconciliation view keeps both transcripts visible so you can decide whether the disagreement is meaningful or just formatting."
                )
            }
        }
    }

    private var privacyAndStorage: some View {
        HelpSectionCard(title: "Privacy And Storage", systemImage: "lock.shield") {
            VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.md) {
                HelpBullet(text: "Processing stays local on your Mac. The app does not upload transcript audio or text to a server.")
                HelpBullet(text: "Saved projects live in `~/Library/Application Support/Consensus/Projects`.")
                HelpBullet(text: "The app stores model preferences, speaker defaults, and whether you have already seen the welcome tour in your app preferences.")
            }
        }
    }
}

// MARK: - Help Section Card

private struct HelpSectionCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.lg) {
            Label(title, systemImage: systemImage)
                .font(ConsensusTheme.Fonts.heading)
                .foregroundStyle(ConsensusTheme.Colors.textPrimary)

            content
        }
        .consensusCard()
    }
}

// MARK: - Quick Action Button

private struct QuickActionButton: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.sm) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(tint)

                Text(title)
                    .font(.headline)
                    .foregroundStyle(ConsensusTheme.Colors.textPrimary)

                Text(subtitle)
                    .font(ConsensusTheme.Fonts.caption)
                    .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
            .padding(ConsensusTheme.Spacing.lg)
            .background {
                RoundedRectangle(cornerRadius: ConsensusTheme.Radius.xl)
                    .fill(tint.opacity(0.10))
                    .overlay {
                        RoundedRectangle(cornerRadius: ConsensusTheme.Radius.xl)
                            .stroke(tint.opacity(0.15), lineWidth: 1)
                    }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Help Step

private struct HelpStep: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: ConsensusTheme.Spacing.lg) {
            Text("\(number)")
                .font(ConsensusTheme.Fonts.mono(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(ConsensusTheme.Colors.accent, in: Circle())

            VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xs) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                Text(detail)
                    .font(ConsensusTheme.Fonts.subheadline)
                    .foregroundStyle(ConsensusTheme.Colors.textSecondary)
            }
        }
    }
}

// MARK: - Help Bullet

private struct HelpBullet: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: ConsensusTheme.Spacing.sm) {
            Circle()
                .fill(ConsensusTheme.Colors.accent)
                .frame(width: 6, height: 6)
                .padding(.top, 7)

            Text(text)
                .font(ConsensusTheme.Fonts.subheadline)
                .foregroundStyle(ConsensusTheme.Colors.textSecondary)
        }
    }
}

// MARK: - Help FAQ

private struct HelpFAQ: View {
    let question: String
    let answer: String
    @State private var isExpanded: Bool = true

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Text(answer)
                .font(ConsensusTheme.Fonts.subheadline)
                .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                .padding(.top, ConsensusTheme.Spacing.sm)
        } label: {
            Text(question)
                .font(.headline)
                .foregroundStyle(ConsensusTheme.Colors.textPrimary)
        }
        .padding(ConsensusTheme.Spacing.lg)
        .background(ConsensusTheme.Colors.surfacePrimary, in: RoundedRectangle(cornerRadius: ConsensusTheme.Radius.lg))
    }
}
