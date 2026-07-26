import SwiftUI

/// Landing page when no project is open.
/// Two clear options: open a prior project or start a new transcription.
struct ProjectDashboardView: View {
    @Environment(TranscriptionViewModel.self) private var viewModel
    @EnvironmentObject private var settings: AppSettings
    @State private var showingProjectLibrary = false

    var body: some View {
        if showingProjectLibrary {
            projectLibraryView
        } else {
            landingView
        }
    }

    // MARK: - Landing View (Two Options)

    private var landingView: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: ConsensusTheme.Spacing.xxl) {
                // App identity
                VStack(spacing: ConsensusTheme.Spacing.md) {
                    Image(systemName: "waveform.circle")
                        .font(.system(size: 56, weight: .light))
                        .foregroundStyle(ConsensusTheme.Colors.accent)

                    Text("Consensus")
                        .font(.largeTitle.bold())
                        .foregroundStyle(ConsensusTheme.Colors.textPrimary)

                    Text("Privacy-first transcription with speaker identification")
                        .font(.subheadline)
                        .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                }

                // Two action cards
                HStack(spacing: ConsensusTheme.Spacing.xl) {
                    // Open Prior Project
                    ActionCard(
                        icon: "folder",
                        title: "Open Prior Project",
                        subtitle: viewModel.projects.isEmpty
                            ? "No saved projects yet"
                            : "\(viewModel.projects.count) project\(viewModel.projects.count == 1 ? "" : "s") saved",
                        accentColor: ConsensusTheme.Colors.accent,
                        isDisabled: viewModel.projects.isEmpty
                    ) {
                        withAnimation(.snappy(duration: 0.3)) {
                            showingProjectLibrary = true
                        }
                    }

                    // Start New Transcription
                    ActionCard(
                        icon: "waveform.badge.plus",
                        title: "New Transcription",
                        subtitle: "Drop an audio file to begin",
                        accentColor: ConsensusTheme.Colors.confidenceGreen,
                        isDisabled: false
                    ) {
                        viewModel.hasEnteredWorkflow = true
                        viewModel.currentPhase = .setup
                    }
                }
                .frame(maxWidth: 600)
            }

            Spacer()

            // Bottom bar with mode toggle
            HStack {
                Button {
                    withAnimation(.snappy(duration: 0.3)) {
                        settings.isSimpleMode = true
                    }
                } label: {
                    HStack(spacing: ConsensusTheme.Spacing.xs) {
                        Image(systemName: "rectangle.on.rectangle.slash")
                            .font(.caption)
                        Text("Simple Mode")
                            .font(.caption)
                    }
                    .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    viewModel.openHelpCenter()
                } label: {
                    HStack(spacing: ConsensusTheme.Spacing.xs) {
                        Image(systemName: "questionmark.circle")
                            .font(.caption)
                        Text("Help")
                            .font(.caption)
                    }
                    .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, ConsensusTheme.Spacing.xl)
            .padding(.vertical, ConsensusTheme.Spacing.md)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ConsensusTheme.Colors.background)
    }

    // MARK: - Project Library View

    private var projectLibraryView: some View {
        VStack(spacing: 0) {
            // Header with back button
            HStack {
                Button {
                    withAnimation(.snappy(duration: 0.3)) {
                        showingProjectLibrary = false
                    }
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(ConsensusSecondaryButtonStyle())

                VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xs) {
                    Text("Saved Projects")
                        .font(.title2.bold())
                        .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                    Text("\(viewModel.projects.count) project\(viewModel.projects.count == 1 ? "" : "s")")
                        .font(.subheadline)
                        .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                }

                Spacer()

                Button {
                    viewModel.currentPhase = .setup
                } label: {
                    Label("New Transcription", systemImage: "plus.circle")
                }
                .buttonStyle(ConsensusPrimaryButtonStyle())
            }
            .padding(.horizontal, ConsensusTheme.Spacing.xl)
            .padding(.vertical, ConsensusTheme.Spacing.lg)

            Divider().overlay(ConsensusTheme.Colors.border)

            // Project cards
            ScrollView {
                LazyVStack(spacing: ConsensusTheme.Spacing.md) {
                    ForEach(viewModel.projects) { project in
                        ProjectCard(
                            project: project,
                            isSelected: false,
                            onOpen: {
                                Task { await viewModel.openProject(id: project.id) }
                            },
                            onDelete: {
                                Task { await viewModel.deleteProject(id: project.id) }
                            }
                        )
                    }
                }
                .padding(ConsensusTheme.Spacing.xl)
            }
        }
    }
}

// MARK: - Action Card

private struct ActionCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let accentColor: Color
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: ConsensusTheme.Spacing.lg) {
                Image(systemName: icon)
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(accentColor)

                VStack(spacing: ConsensusTheme.Spacing.xs) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(ConsensusTheme.Colors.textPrimary)

                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, ConsensusTheme.Spacing.xxl)
            .padding(.horizontal, ConsensusTheme.Spacing.xl)
            .background {
                RoundedRectangle(cornerRadius: ConsensusTheme.Radius.xl)
                    .fill(ConsensusTheme.Colors.surfacePrimary)
                    .overlay {
                        RoundedRectangle(cornerRadius: ConsensusTheme.Radius.xl)
                            .stroke(accentColor.opacity(0.2), lineWidth: 1)
                    }
            }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.4 : 1)
    }
}

// MARK: - Project Card

private struct ProjectCard: View {
    let project: TranscriptionProjectSummary
    let isSelected: Bool
    let onOpen: () -> Void
    let onDelete: () -> Void

    @State private var showDeleteConfirmation = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.md) {
                // Top row: name + badges
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xs) {
                        Text(project.name)
                            .font(.headline)
                            .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                            .lineLimit(1)

                        HStack(spacing: ConsensusTheme.Spacing.sm) {
                            Text(project.updatedAt, style: .date)
                                .font(.caption)
                                .foregroundStyle(ConsensusTheme.Colors.textTertiary)

                            Text(TimeFormatting.durationDisplay(project.audioDuration))
                                .font(ConsensusTheme.Fonts.mono(.caption))
                                .foregroundStyle(ConsensusTheme.Colors.textTertiary)

                            Text("\(project.passCount) pass\(project.passCount == 1 ? "" : "es")")
                                .font(.caption)
                                .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                        }
                    }

                    Spacer()

                    Text(project.qualityTier)
                        .font(ConsensusTheme.Fonts.mono(size: 9, weight: .bold))
                        .foregroundStyle(project.hasConsensus ? ConsensusTheme.Colors.confidenceGreen : ConsensusTheme.Colors.textTertiary)
                        .padding(.horizontal, ConsensusTheme.Spacing.sm)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(
                                (project.hasConsensus ? ConsensusTheme.Colors.confidenceGreen : ConsensusTheme.Colors.textTertiary).opacity(0.1)
                            )
                        )
                }

                // Speakers
                if !project.speakerNames.isEmpty {
                    HStack(spacing: ConsensusTheme.Spacing.sm) {
                        Image(systemName: "person.2")
                            .font(.caption2)
                            .foregroundStyle(ConsensusTheme.Colors.textTertiary)

                        Text(project.speakerNames.joined(separator: ", "))
                            .font(.subheadline)
                            .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                            .lineLimit(1)
                    }
                }

                // Summary
                if let summary = project.projectSummary, !summary.isEmpty {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                        .lineLimit(2)
                        .italic()
                }

                // Confidence
                if let confidence = project.averageWordConfidence {
                    HStack(spacing: ConsensusTheme.Spacing.sm) {
                        ProgressView(value: Double(confidence))
                            .tint(ConsensusTheme.Colors.confidenceTier(confidence))
                            .frame(maxWidth: 100)

                        Text("\(Int(confidence * 100))% confidence")
                            .font(ConsensusTheme.Fonts.mono(.caption2))
                            .foregroundStyle(ConsensusTheme.Colors.confidenceTier(confidence))
                    }
                }
            }
            .padding(ConsensusTheme.Spacing.lg)
            .background {
                RoundedRectangle(cornerRadius: ConsensusTheme.Radius.lg)
                    .fill(isSelected ? ConsensusTheme.Colors.accentSubtle : ConsensusTheme.Colors.surfacePrimary)
                    .overlay {
                        RoundedRectangle(cornerRadius: ConsensusTheme.Radius.lg)
                            .stroke(
                                isSelected ? ConsensusTheme.Colors.accent.opacity(0.4) : ConsensusTheme.Colors.border,
                                lineWidth: 1
                            )
                    }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(action: onOpen) {
                Label("Open", systemImage: "doc")
            }
            Divider()
            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .alert("Delete Project?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive, action: onDelete)
        } message: {
            Text("Are you sure you want to delete \"\(project.name)\"? This cannot be undone.")
        }
    }
}
