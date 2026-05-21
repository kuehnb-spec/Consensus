import SwiftUI

struct ContentView: View {
    var body: some View {
        RewrittenSurface()
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(TranscriptionViewModel.self) private var viewModel
    @EnvironmentObject private var settings: AppSettings
    @State private var projectToDelete: TranscriptionProjectSummary?
    @State private var showDeleteConfirmation = false
    @State private var projectToRestart: TranscriptionProjectSummary?
    @State private var showRestartConfirmation = false

    var body: some View {
        List {
            if let currentProject = viewModel.currentProject {
                currentProjectSection(currentProject)
            }

            workspaceSection
            toolsSection
            guideSection
            projectLibrarySection
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 340)
        .alert("Delete Project?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                projectToDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let project = projectToDelete {
                    Task {
                        await viewModel.deleteProject(id: project.id)
                    }
                    projectToDelete = nil
                }
            }
        } message: {
            if let project = projectToDelete {
                Text("Are you sure you want to delete \"\(project.name)\"? This cannot be undone.")
            }
        }
        .alert("Re-run From Scratch?", isPresented: $showRestartConfirmation) {
            Button("Cancel", role: .cancel) {
                projectToRestart = nil
            }
            Button("Discard & Re-run", role: .destructive) {
                if let project = projectToRestart {
                    Task {
                        if viewModel.currentProject?.id != project.id {
                            await viewModel.openProject(id: project.id)
                        }
                        await viewModel.restartCurrentProjectFromScratch()
                    }
                    projectToRestart = nil
                }
            }
        } message: {
            if let project = projectToRestart {
                Text("Discard all transcription passes on \"\(project.name)\" and return to the Transcribe step? The audio file and project settings are kept, but every pass (Standard, Deep Review, Consensus) will be removed. This cannot be undone.")
            }
        }
    }

    // MARK: - Helpers

    private func projectFileURL(for id: UUID) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let newPath = base.appendingPathComponent("Consensus/Projects/\(id.uuidString)/project.json")
        if FileManager.default.fileExists(atPath: newPath.path) { return newPath }
        let legacyPath = base.appendingPathComponent("BDK Transcribo/Projects/\(id.uuidString)/project.json")
        return FileManager.default.fileExists(atPath: legacyPath.path) ? legacyPath : newPath
    }

    private func revealInFinder(projectID: UUID) {
        let url = projectFileURL(for: projectID).deletingLastPathComponent()
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
    }

    // MARK: Current Project

    private func currentProjectSection(_ project: TranscriptionProject) -> some View {
        Section {
            VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xs) {
                Text(project.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                if let activePass = project.activePass {
                    Text("\(activePass.kind.displayName) \u{2022} \(activePass.modelName)")
                        .font(ConsensusTheme.Fonts.mono(.caption2))
                        .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                }
                Text("\(TimeFormatting.durationDisplay(project.audioDuration)) \u{2022} \(project.passes.count) pass\(project.passes.count == 1 ? "" : "es")")
                    .font(ConsensusTheme.Fonts.mono(.caption2))
                    .foregroundStyle(ConsensusTheme.Colors.textTertiary)
            }

            Button("Close Project") {
                viewModel.closeProject()
            }
            .buttonStyle(ConsensusGhostButtonStyle())
        } header: {
            Text("Current Project")
        }
    }

    // MARK: Workflow

    @ViewBuilder
    private var workspaceSection: some View {
        Section {
            // --- STANDARD TRANSCRIPTION ---

            WorkflowStepRow(
                step: 1,
                title: "Transcribe",
                systemImage: "waveform",
                isSelected: viewModel.currentPhase == .setup,
                isComplete: viewModel.hasResult,
                showPulse: viewModel.pipeline.isRunning
            ) {
                viewModel.currentPhase = .setup
            }

            WorkflowStepRow(
                step: 2,
                title: "Review & Label Speakers",
                systemImage: "person.text.rectangle",
                isSelected: viewModel.currentPhase == .review,
                isComplete: viewModel.hasSpeakerRenames,
                isDisabled: !viewModel.hasResult
            ) {
                viewModel.currentPhase = .review
            }

            WorkflowStepRow(
                step: 3,
                title: "Export",
                systemImage: "square.and.arrow.up",
                isSelected: viewModel.currentPhase == .export && !viewModel.currentPhase.isDeepReview,
                isDisabled: !viewModel.hasResult,
                badge: viewModel.hasResult && !viewModel.hasConsensusPass ? "standard" : nil
            ) {
                viewModel.currentPhase = .export
            }
        } header: {
            Text("Standard Transcription")
        }

        // --- DEEP REVIEW (only visible after first pass is complete) ---
        if viewModel.hasResult {
            Section {
                // Entry point / Step 1: Deep Transcription
                DeepReviewStepRow(
                    step: 1,
                    title: "Deep Transcription",
                    subtitle: "Run second engine + merge",
                    systemImage: "doc.on.doc",
                    isSelected: viewModel.currentPhase == .deepTranscription,
                    isComplete: viewModel.deepReviewCompletedSteps.contains("transcription"),
                    isActive: viewModel.currentPhase == .deepTranscription,
                    isDisabled: viewModel.pipeline.isRunning || viewModel.isCleanupRunning
                ) {
                    viewModel.currentPhase = .deepTranscription
                }

                // Step 2: Deep Diarization
                DeepReviewStepRow(
                    step: 2,
                    title: "Deep Diarization",
                    subtitle: "Multi-pass speaker refinement",
                    systemImage: "person.2.wave.2",
                    isSelected: viewModel.currentPhase == .deepDiarization,
                    isComplete: viewModel.deepReviewCompletedSteps.contains("diarization"),
                    isActive: viewModel.currentPhase == .deepDiarization,
                    isDisabled: !viewModel.deepReviewCompletedSteps.contains("transcription")
                ) {
                    viewModel.currentPhase = .deepDiarization
                }

                // Step 3: Confirm Speakers
                DeepReviewStepRow(
                    step: 3,
                    title: "Confirm Speakers",
                    subtitle: "Verify speaker names",
                    systemImage: "person.badge.check",
                    isSelected: viewModel.currentPhase == .deepSpeakerConfirm,
                    isComplete: viewModel.deepReviewCompletedSteps.contains("speakerConfirm"),
                    isActive: viewModel.currentPhase == .deepSpeakerConfirm,
                    isDisabled: !viewModel.deepReviewCompletedSteps.contains("diarization")
                ) {
                    viewModel.currentPhase = .deepSpeakerConfirm
                }

                // Step 4: Review & Compare
                DeepReviewStepRow(
                    step: 4,
                    title: "Review & Export",
                    subtitle: "Before/after comparison",
                    systemImage: "checkmark.seal",
                    isSelected: viewModel.currentPhase == .deepReviewCompare,
                    isComplete: viewModel.hasConsensusPass,
                    isActive: viewModel.currentPhase == .deepReviewCompare,
                    isDisabled: !viewModel.deepReviewCompletedSteps.contains("speakerConfirm")
                ) {
                    viewModel.currentPhase = .deepReviewCompare
                }
            } header: {
                HStack {
                    Text("Deep Review")
                    Spacer()
                    if viewModel.hasConsensusPass {
                        Text("verified")
                            .font(ConsensusTheme.Fonts.mono(size: 9, weight: .bold))
                            .foregroundStyle(ConsensusTheme.Colors.confidenceGreen)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(ConsensusTheme.Colors.confidenceGreen.opacity(0.12))
                            )
                    }
                }
            }
        }
    }

    // MARK: Tools

    private var toolsSection: some View {
        Section("Tools") {
            SidebarNavigationRow(
                title: "Summary",
                systemImage: "text.badge.star",
                isSelected: viewModel.currentPhase == .summary,
                isDisabled: !viewModel.hasResult
            ) {
                viewModel.currentPhase = .summary
            }

            SidebarNavigationRow(
                title: "Polish (AI Cleanup)",
                systemImage: "wand.and.stars",
                isSelected: viewModel.currentPhase == .polish,
                isDisabled: !viewModel.hasResult
            ) {
                viewModel.currentPhase = .polish
            }

            SidebarNavigationRow(
                title: "Compare Passes",
                systemImage: "rectangle.split.2x1",
                isSelected: viewModel.currentPhase == .comparePasses,
                isDisabled: (viewModel.currentProject?.passes.count ?? 0) < 2
            ) {
                viewModel.currentPhase = .comparePasses
            }

            SidebarNavigationRow(
                title: "Summary Pane",
                systemImage: viewModel.showSummarySidepane ? "sidebar.right" : "sidebar.right",
                isSelected: viewModel.showSummarySidepane,
                isDisabled: !viewModel.hasResult
            ) {
                withAnimation(.snappy(duration: 0.2)) {
                    viewModel.showSummarySidepane.toggle()
                }
            }

            Button {
                withAnimation(.snappy(duration: 0.3)) {
                    settings.isSimpleMode = true
                }
            } label: {
                HStack(spacing: ConsensusTheme.Spacing.sm) {
                    Image(systemName: "rectangle.on.rectangle.slash")
                        .font(.body)
                        .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                        .frame(width: 20)
                    Text("Simple Mode")
                        .font(.body)
                        .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                    Spacer()
                }
                .padding(.vertical, ConsensusTheme.Spacing.xs)
                .padding(.horizontal, ConsensusTheme.Spacing.sm)
            }
            .buttonStyle(.plain)
            .help("Switch to Simple Mode for a streamlined, light-themed interface")
        }
    }

    // MARK: Guide

    private var guideSection: some View {
        Section("Guide") {
            SidebarNavigationRow(
                title: "Help Center",
                systemImage: "questionmark.circle",
                isSelected: viewModel.currentPhase == .help
            ) {
                viewModel.openHelpCenter()
            }

            Button {
                viewModel.presentWelcomeTour()
            } label: {
                Label("Welcome Tour", systemImage: "sparkles")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, ConsensusTheme.Spacing.xs)
                    .padding(.horizontal, ConsensusTheme.Spacing.sm)
            }
            .buttonStyle(.plain)

            Button {
                Task {
                    await viewModel.loadDemoProject()
                }
            } label: {
                Label("Open Demo Project", systemImage: "play.rectangle")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, ConsensusTheme.Spacing.xs)
                    .padding(.horizontal, ConsensusTheme.Spacing.sm)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Project Library (Date-Grouped)

    private var projectLibrarySection: some View {
        let grouped = DateGroupedProjects(projects: viewModel.projects)

        return Group {
            if viewModel.projects.isEmpty {
                Section("Saved Projects") {
                    Text("No saved projects yet")
                        .font(ConsensusTheme.Fonts.caption)
                        .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                }
            } else {
                ForEach(grouped.groups) { group in
                    Section(group.label) {
                        ForEach(group.projects) { project in
                            Button {
                                Task {
                                    await viewModel.openProject(id: project.id)
                                }
                            } label: {
                                ProjectLibraryRow(
                                    project: project,
                                    isSelected: project.id == viewModel.currentProject?.id
                                )
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    Task {
                                        await viewModel.openProject(id: project.id)
                                    }
                                } label: {
                                    Label("Open", systemImage: "doc")
                                }

                                ShareLink(
                                    item: projectFileURL(for: project.id),
                                    subject: Text(project.name),
                                    message: Text("Consensus project: \(project.name)")
                                ) {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                }

                                Button {
                                    revealInFinder(projectID: project.id)
                                } label: {
                                    Label("Show in Finder", systemImage: "folder")
                                }

                                Divider()

                                Button {
                                    projectToRestart = project
                                    showRestartConfirmation = true
                                } label: {
                                    Label("Re-run From Scratch…", systemImage: "arrow.counterclockwise.circle")
                                }

                                Button(role: .destructive) {
                                    projectToDelete = project
                                    showDeleteConfirmation = true
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Global Status Bar

private struct GlobalStatusBar: View {
    @Environment(TranscriptionViewModel.self) private var viewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: ConsensusTheme.Spacing.md) {
                // Spinner
                ProgressView()
                    .controlSize(.small)

                // Status text
                Text(viewModel.globalStatusText)
                    .font(ConsensusTheme.Fonts.mono(.caption))
                    .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                    .lineLimit(1)

                Spacer()

                // Cancel button (if pipeline is running)
                if viewModel.pipeline.isRunning {
                    Button("Cancel") {
                        viewModel.cancelTranscription()
                    }
                    .font(.caption)
                    .buttonStyle(ConsensusGhostButtonStyle())
                }
            }
            .padding(.horizontal, ConsensusTheme.Spacing.lg)
            .padding(.vertical, ConsensusTheme.Spacing.sm)

            // Rainbow gradient progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Track
                    Rectangle()
                        .fill(ConsensusTheme.Colors.surfacePrimary.opacity(0.3))

                    // Filled portion with gradient
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.38, green: 0.40, blue: 0.95),  // Indigo
                                    Color(red: 0.30, green: 0.60, blue: 0.98),  // Blue
                                    Color(red: 0.20, green: 0.78, blue: 0.85),  // Cyan
                                    Color(red: 0.25, green: 0.85, blue: 0.55),  // Green
                                    Color(red: 0.90, green: 0.80, blue: 0.25),  // Yellow
                                    Color(red: 0.95, green: 0.55, blue: 0.25),  // Orange
                                    Color(red: 0.90, green: 0.30, blue: 0.40),  // Red-pink
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geometry.size.width * viewModel.globalProgress)
                        .animation(.easeInOut(duration: 0.3), value: viewModel.globalProgress)
                }
            }
            .frame(height: 3)
        }
        .background(ConsensusTheme.Colors.surfacePrimary.opacity(0.95))
        .overlay(alignment: .bottom) {
            Divider().overlay(ConsensusTheme.Colors.border)
        }
    }
}

// MARK: - Date Grouping

private struct DateGroupedProjects {
    struct Group: Identifiable {
        let id: String
        let label: String
        let projects: [TranscriptionProjectSummary]
    }

    let groups: [Group]

    init(projects: [TranscriptionProjectSummary]) {
        let calendar = Calendar.current
        let now = Date()

        var today: [TranscriptionProjectSummary] = []
        var yesterday: [TranscriptionProjectSummary] = []
        var lastWeek: [TranscriptionProjectSummary] = []
        var older: [TranscriptionProjectSummary] = []

        for project in projects {
            if calendar.isDateInToday(project.updatedAt) {
                today.append(project)
            } else if calendar.isDateInYesterday(project.updatedAt) {
                yesterday.append(project)
            } else if let weekAgo = calendar.date(byAdding: .day, value: -7, to: now),
                      project.updatedAt > weekAgo {
                lastWeek.append(project)
            } else {
                older.append(project)
            }
        }

        var result: [Group] = []
        if !today.isEmpty     { result.append(Group(id: "today", label: "Today", projects: today)) }
        if !yesterday.isEmpty { result.append(Group(id: "yesterday", label: "Yesterday", projects: yesterday)) }
        if !lastWeek.isEmpty  { result.append(Group(id: "lastweek", label: "Last 7 Days", projects: lastWeek)) }
        if !older.isEmpty     { result.append(Group(id: "older", label: "Older", projects: older)) }
        self.groups = result
    }
}

// MARK: - Workflow Step Row

private struct WorkflowStepRow: View {
    let step: Int
    let title: String
    let systemImage: String
    let isSelected: Bool
    var isComplete: Bool = false
    var isDisabled: Bool = false
    var showPulse: Bool = false
    var badge: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: ConsensusTheme.Spacing.sm) {
                // Step number / completion indicator
                ZStack {
                    if isComplete {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(ConsensusTheme.Colors.confidenceGreen)
                    } else {
                        Text("\(step)")
                            .font(ConsensusTheme.Fonts.mono(size: 11, weight: .bold))
                            .foregroundStyle(isSelected ? ConsensusTheme.Colors.accent : ConsensusTheme.Colors.textTertiary)
                            .frame(width: 20, height: 20)
                            .background(
                                Circle()
                                    .fill(isSelected ? ConsensusTheme.Colors.accentSubtle : ConsensusTheme.Colors.surfacePrimary)
                                    .overlay(
                                        Circle()
                                            .stroke(isSelected ? ConsensusTheme.Colors.accent.opacity(0.5) : ConsensusTheme.Colors.border, lineWidth: 1)
                                    )
                            )
                    }

                    if showPulse {
                        Circle()
                            .fill(ConsensusTheme.Colors.accent.opacity(0.3))
                            .frame(width: 24, height: 24)
                            .phaseAnimator([false, true]) { content, phase in
                                content
                                    .scaleEffect(phase ? 1.6 : 1.0)
                                    .opacity(phase ? 0 : 0.5)
                            } animation: { _ in
                                .easeInOut(duration: 1.2).repeatForever(autoreverses: false)
                            }
                    }
                }
                .frame(width: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.body)
                        .foregroundStyle(isSelected ? ConsensusTheme.Colors.textPrimary : ConsensusTheme.Colors.textSecondary)
                        .lineLimit(1)
                }

                Spacer()

                if let badge {
                    Text(badge)
                        .font(ConsensusTheme.Fonts.mono(size: 9, weight: .medium))
                        .foregroundStyle(badge == "recommended" ? ConsensusTheme.Colors.confidenceAmber : ConsensusTheme.Colors.textTertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(badge == "recommended"
                                    ? ConsensusTheme.Colors.confidenceAmber.opacity(0.12)
                                    : ConsensusTheme.Colors.surfacePrimary)
                        )
                }
            }
            .padding(.vertical, ConsensusTheme.Spacing.xs)
            .padding(.horizontal, ConsensusTheme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: ConsensusTheme.Radius.md)
                    .fill(isSelected ? ConsensusTheme.Colors.accentSubtle : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.35 : 1)
    }
}

// MARK: - Sidebar Navigation Row

private struct SidebarNavigationRow: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    var isDisabled: Bool = false
    var showPulse: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: ConsensusTheme.Spacing.sm) {
                ZStack {
                    Image(systemName: systemImage)
                        .font(.body)
                        .foregroundStyle(isSelected ? ConsensusTheme.Colors.accent : ConsensusTheme.Colors.textSecondary)

                    if showPulse {
                        Circle()
                            .fill(ConsensusTheme.Colors.accent.opacity(0.3))
                            .frame(width: 24, height: 24)
                            .phaseAnimator([false, true]) { content, phase in
                                content
                                    .scaleEffect(phase ? 1.6 : 1.0)
                                    .opacity(phase ? 0 : 0.5)
                            } animation: { _ in
                                .easeInOut(duration: 1.2).repeatForever(autoreverses: false)
                            }
                    }
                }
                .frame(width: 20)

                Text(title)
                    .font(.body)
                    .foregroundStyle(isSelected ? ConsensusTheme.Colors.textPrimary : ConsensusTheme.Colors.textSecondary)

                Spacer()
            }
            .padding(.vertical, ConsensusTheme.Spacing.xs)
            .padding(.horizontal, ConsensusTheme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: ConsensusTheme.Radius.md)
                    .fill(isSelected ? ConsensusTheme.Colors.accentSubtle : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.35 : 1)
    }
}

// MARK: - Project Library Row

private struct ProjectLibraryRow: View {
    let project: TranscriptionProjectSummary
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xs) {
            HStack(alignment: .top) {
                Text(project.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                    .lineLimit(1)

                Spacer()

                Text(project.updatedAt, style: .relative)
                    .font(ConsensusTheme.Fonts.mono(.caption2))
                    .foregroundStyle(ConsensusTheme.Colors.textTertiary)
            }

            HStack(spacing: ConsensusTheme.Spacing.sm) {
                StatusBadge(project: project)

                if let confidence = project.averageWordConfidence {
                    ConfidencePill(value: confidence)
                }
            }
        }
        .padding(.vertical, ConsensusTheme.Spacing.xs)
        .padding(.horizontal, ConsensusTheme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: ConsensusTheme.Radius.md)
                .fill(isSelected ? ConsensusTheme.Colors.accentSubtle : Color.clear)
        )
    }
}

// MARK: - Status Badge

private struct StatusBadge: View {
    let project: TranscriptionProjectSummary

    private var config: (icon: String, label: String, color: Color) {
        if project.hasConsensus {
            return ("checkmark.seal.fill", "Verified", ConsensusTheme.Colors.confidenceGreen)
        } else if project.hasMultiplePasses {
            return ("exclamationmark.triangle.fill", "Deep Review Available", ConsensusTheme.Colors.confidenceAmber)
        } else if project.hasTranscript {
            return ("checkmark.circle", "\(project.passCount) pass\(project.passCount == 1 ? "" : "es")", ConsensusTheme.Colors.textSecondary)
        } else {
            return ("square.and.pencil", "Draft", ConsensusTheme.Colors.textTertiary)
        }
    }

    var body: some View {
        let cfg = config
        Label(cfg.label, systemImage: cfg.icon)
            .font(ConsensusTheme.Fonts.mono(.caption2))
            .foregroundStyle(cfg.color)
    }
}

// MARK: - Confidence Pill

private struct ConfidencePill: View {
    let value: Float

    private var tierColor: Color {
        ConsensusTheme.Colors.confidenceTier(value)
    }

    var body: some View {
        Text("\(Int((Double(value) * 100).rounded()))%")
            .font(ConsensusTheme.Fonts.mono(size: 10, weight: .semibold))
            .foregroundStyle(tierColor)
            .padding(.horizontal, ConsensusTheme.Spacing.sm)
            .padding(.vertical, 2)
            .background {
                Capsule()
                    .fill(tierColor.opacity(0.15))
                    .overlay {
                        Capsule()
                            .stroke(tierColor.opacity(0.30), lineWidth: 1)
                    }
            }
    }
}

// MARK: - Deep Review Step Row

private struct DeepReviewStepRow: View {
    let step: Int
    let title: String
    let subtitle: String
    let systemImage: String
    let isSelected: Bool
    var isComplete: Bool = false
    var isActive: Bool = false
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: ConsensusTheme.Spacing.sm) {
                // Step indicator
                ZStack {
                    if isComplete {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(ConsensusTheme.Colors.confidenceGreen)
                    } else if isActive {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Text("\(step)")
                            .font(ConsensusTheme.Fonts.mono(size: 10, weight: .bold))
                            .foregroundStyle(isSelected ? ConsensusTheme.Colors.accent : ConsensusTheme.Colors.textTertiary)
                            .frame(width: 18, height: 18)
                            .background(
                                Circle()
                                    .fill(isSelected ? ConsensusTheme.Colors.accentSubtle : ConsensusTheme.Colors.surfacePrimary)
                                    .overlay(
                                        Circle().stroke(
                                            isSelected ? ConsensusTheme.Colors.accent.opacity(0.5) : ConsensusTheme.Colors.border,
                                            lineWidth: 1
                                        )
                                    )
                            )
                    }
                }
                .frame(width: 18)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.subheadline)
                        .foregroundStyle(isSelected ? ConsensusTheme.Colors.textPrimary : ConsensusTheme.Colors.textSecondary)
                        .lineLimit(1)

                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                        .lineLimit(1)
                }

                Spacer()
            }
            .padding(.vertical, ConsensusTheme.Spacing.xs)
            .padding(.horizontal, ConsensusTheme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: ConsensusTheme.Radius.sm)
                    .fill(isSelected ? ConsensusTheme.Colors.accentSubtle : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.35 : 1)
    }
}
