import SwiftUI

struct ContentView: View {
    @Environment(TranscriptionViewModel.self) private var viewModel

    var body: some View {
        @Bindable var vm = viewModel

        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                // Global floating status bar — always visible during processing
                if viewModel.isAnyProcessRunning {
                    GlobalStatusBar()
                }

                NavigationSplitView {
                    SidebarView()
                } detail: {
                    Group {
                        switch viewModel.currentPhase {
                        case .setup:
                            TranscriptionSetupView()
                        case .help:
                            HelpCenterView()
                        case .review:
                            TranscriptView()
                        case .quality:
                            QualityView()
                        case .reconcile:
                            ReconciliationView()
                        case .export:
                            ExportView()
                        case .summary:
                            SummaryView()
                        }
                    }
                }
            }

            // Floating process log
            if viewModel.processLog.isVisible {
                ProcessLogView(processLog: viewModel.processLog)
                    .padding(ConsensusTheme.Spacing.lg)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .navigationTitle(viewModel.currentProject?.name ?? "Consensus")
        .fileImporter(
            isPresented: $vm.showFilePicker,
            allowedContentTypes: [.audio, .mpeg4Audio, .mp3, .wav, .aiff],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    Task {
                        await viewModel.importAudio(url: url)
                    }
                }
            case .failure(let error):
                viewModel.errorMessage = error.localizedDescription
                viewModel.showError = true
            }
        }
        .alert("Error", isPresented: $vm.showError) {
            Button("OK") { viewModel.showError = false }
        } message: {
            Text(viewModel.errorMessage ?? "An unknown error occurred.")
        }
        .sheet(isPresented: $vm.showWelcomeTour, onDismiss: {
            viewModel.completeWelcomeTour()
        }) {
            WelcomeTourView()
                .environment(viewModel)
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(TranscriptionViewModel.self) private var viewModel

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

    private var workspaceSection: some View {
        Section {
            // Quick Transcribe — one-click fast mode
            Button {
                Task {
                    await viewModel.quickTranscribe()
                }
            } label: {
                HStack(spacing: ConsensusTheme.Spacing.sm) {
                    Image(systemName: "bolt.fill")
                        .font(.body)
                        .foregroundStyle(ConsensusTheme.Colors.confidenceAmber)
                        .frame(width: 20)
                    Text("Quick Transcribe")
                        .font(.body.weight(.medium))
                        .foregroundStyle(ConsensusTheme.Colors.confidenceAmber)
                    Spacer()
                }
                .padding(.vertical, ConsensusTheme.Spacing.xs)
                .padding(.horizontal, ConsensusTheme.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: ConsensusTheme.Radius.md)
                        .fill(ConsensusTheme.Colors.confidenceAmber.opacity(0.08))
                )
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.hasAudio || viewModel.pipeline.isRunning)
            .opacity(!viewModel.hasAudio ? 0.35 : 1)
            .help("Fast transcription with a small model, auto-exports to legal PDF")

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
                title: "Review & Rename Speakers",
                systemImage: "doc.text.magnifyingglass",
                isSelected: viewModel.currentPhase == .review,
                isComplete: viewModel.hasSpeakerRenames,
                isDisabled: !viewModel.hasResult
            ) {
                viewModel.currentPhase = .review
            }

            WorkflowStepRow(
                step: 3,
                title: "Deep Review",
                systemImage: "sparkles.rectangle.stack",
                isSelected: viewModel.currentPhase == .quality,
                isComplete: viewModel.hasMultiplePasses,
                isDisabled: !viewModel.hasResult,
                badge: "optional"
            ) {
                viewModel.currentPhase = .quality
            }

            WorkflowStepRow(
                step: 4,
                title: "Reconcile",
                systemImage: "rectangle.split.3x1",
                isSelected: viewModel.currentPhase == .reconcile,
                isComplete: viewModel.hasConsensusPass,
                isDisabled: !viewModel.canOpenReconciliation,
                badge: viewModel.canOpenReconciliation ? "recommended" : nil
            ) {
                viewModel.openReconciliation()
            }

            WorkflowStepRow(
                step: 5,
                title: "Export",
                systemImage: "square.and.arrow.up",
                isSelected: viewModel.currentPhase == .export,
                isDisabled: !viewModel.hasResult
            ) {
                viewModel.currentPhase = .export
            }
        } header: {
            Text("Workflow")
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

            Button {
                viewModel.toggleProcessLog()
            } label: {
                HStack(spacing: ConsensusTheme.Spacing.sm) {
                    Image(systemName: "terminal")
                        .font(.body)
                        .foregroundStyle(viewModel.processLog.isVisible ? ConsensusTheme.Colors.accent : ConsensusTheme.Colors.textSecondary)
                        .frame(width: 20)
                    Text("Process Log")
                        .font(.body)
                        .foregroundStyle(viewModel.processLog.isVisible ? ConsensusTheme.Colors.textPrimary : ConsensusTheme.Colors.textSecondary)
                    Spacer()
                    if !viewModel.processLog.entries.isEmpty {
                        Text("\(viewModel.processLog.entries.count)")
                            .font(ConsensusTheme.Fonts.mono(.caption2))
                            .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                    }
                }
                .padding(.vertical, ConsensusTheme.Spacing.xs)
                .padding(.horizontal, ConsensusTheme.Spacing.sm)
            }
            .buttonStyle(.plain)
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
            return ("checkmark.seal.fill", "Reconciled", ConsensusTheme.Colors.confidenceGreen)
        } else if project.hasMultiplePasses {
            return ("exclamationmark.triangle.fill", "Needs Review", ConsensusTheme.Colors.confidenceAmber)
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
