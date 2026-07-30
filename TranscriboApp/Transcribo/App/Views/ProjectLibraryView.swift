import SwiftUI

/// Full list of saved projects, with sort controls and per-row actions.
/// Phase 5 ships this as a sheet presentation reachable via ⌘L; promoting
/// to a proper separate Window (with its own entry in the Dock and Window
/// menu) is a small follow-up that needs app-level VM plumbing.
///
/// Backing data comes from `DeepReadViewModel.library.index`, refreshed
/// via `refreshRecentProjects()` on appear.
struct ProjectLibraryView: View {
    @Bindable var viewModel: DeepReadViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var sort: Sort = .mostRecent
    @State private var query: String = ""

    enum Sort: String, CaseIterable, Identifiable {
        case mostRecent
        case name
        case duration

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .mostRecent: return "Most recent"
            case .name:       return "Name"
            case .duration:   return "Duration"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, ConsensusTheme.Spacing.lg)
                .padding(.vertical, ConsensusTheme.Spacing.md)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(ConsensusTheme.Colors.borderSubtle).frame(height: 1)
                }

            if filteredEntries.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: ConsensusTheme.Spacing.xs) {
                        ForEach(filteredEntries) { entry in
                            row(entry: entry)
                        }
                    }
                    .padding(ConsensusTheme.Spacing.lg)
                }
            }
        }
        .frame(width: 680, height: 560)
        .background(ConsensusTheme.Colors.background)
        .task {
            await viewModel.refreshRecentProjects()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: ConsensusTheme.Spacing.sm) {
            HStack(spacing: ConsensusTheme.Spacing.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Project Library")
                        .font(ConsensusType.display(size: 20, weight: .semibold))
                        .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                    Text("\(viewModel.library.index.count) project\(viewModel.library.index.count == 1 ? "" : "s")")
                        .font(ConsensusType.displayCaption)
                        .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                }

                Spacer()

                Picker("Sort", selection: $sort) {
                    ForEach(Sort.allCases) { s in
                        Text(s.displayName).tag(s)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 160)

                Button("Done") { dismiss() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
            }

            // Search bar
            HStack(spacing: ConsensusTheme.Spacing.sm) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                TextField("Search by name or speaker", text: $query)
                    .textFieldStyle(.plain)
                    .font(ConsensusType.displayBody)
            }
            .padding(.horizontal, ConsensusTheme.Spacing.sm)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: ConsensusTheme.Radius.sm, style: .continuous)
                    .fill(ConsensusTheme.Colors.surfaceSecondary.opacity(0.6))
                    .overlay(
                        RoundedRectangle(cornerRadius: ConsensusTheme.Radius.sm, style: .continuous)
                            .stroke(ConsensusTheme.Colors.borderSubtle, lineWidth: 1)
                    )
            )
        }
    }

    // MARK: - Row

    private func row(entry: ProjectLibrary.ProjectIndexEntry) -> some View {
        HStack(spacing: ConsensusTheme.Spacing.md) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(ConsensusTheme.Colors.accent)

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title)
                    .font(ConsensusType.displayBody.weight(.semibold))
                    .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: ConsensusTheme.Spacing.sm) {
                    Text(Self.duration(entry.durationSeconds))
                        .font(ConsensusType.monoMetric)
                    Text("·")
                        .foregroundStyle(ConsensusTheme.Colors.textMuted)
                    Text(Self.relative(entry.updatedAt))
                        .font(ConsensusType.displayCaption)
                    if !entry.speakerNames.isEmpty {
                        Text("·")
                            .foregroundStyle(ConsensusTheme.Colors.textMuted)
                        Text(entry.speakerNames.prefix(4).joined(separator: ", "))
                            .font(ConsensusType.displayCaption)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .foregroundStyle(ConsensusTheme.Colors.textSecondary)
            }

            Spacer(minLength: ConsensusTheme.Spacing.md)

            HStack(spacing: ConsensusTheme.Spacing.xs) {
                Button {
                    revealInFinder(entry: entry)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.plain)
                .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                .help("Show in Finder")

                Button {
                    confirmDelete(entry: entry)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                .help("Delete project (irreversible)")

                Button {
                    open(entry: entry)
                } label: {
                    Label("Open", systemImage: "arrow.right")
                        .labelStyle(.titleOnly)
                }
                .buttonStyle(.borderedProminent)
                .tint(ConsensusTheme.Colors.accent)
            }
        }
        .padding(.horizontal, ConsensusTheme.Spacing.md)
        .padding(.vertical, ConsensusTheme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: ConsensusTheme.Radius.md, style: .continuous)
                .fill(ConsensusTheme.Colors.surfaceSecondary.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: ConsensusTheme.Radius.md, style: .continuous)
                        .stroke(ConsensusTheme.Colors.borderSubtle, lineWidth: 1)
                )
        )
        .contextMenu {
            Button("Open") { open(entry: entry) }
            Button("Show in Finder") { revealInFinder(entry: entry) }
            Divider()
            Button("Delete…", role: .destructive) { confirmDelete(entry: entry) }
        }
    }

    private var emptyState: some View {
        let isSearching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !viewModel.library.index.isEmpty

        return VStack(spacing: ConsensusTheme.Spacing.md) {
            Image(systemName: isSearching ? "magnifyingglass" : "tray")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(ConsensusTheme.Colors.textTertiary)
            Text(isSearching ? "No matches" : "No projects yet")
                .font(ConsensusType.displaySubheading)
                .foregroundStyle(ConsensusTheme.Colors.textPrimary)
            Text(isSearching
                 ? "No projects match \"\(query)\". Try a different title or speaker name."
                 : "Drop audio on the main window to create your first project.")
                .font(ConsensusType.displayCaption)
                .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            if isSearching {
                Button("Clear search") { query = "" }
                    .buttonStyle(.bordered)
                    .padding(.top, ConsensusTheme.Spacing.xs)
            }
        }
    }

    // MARK: - Actions

    private func open(entry: ProjectLibrary.ProjectIndexEntry) {
        Task {
            await viewModel.openProject(entry.id)
            dismiss()
        }
    }

    private func revealInFinder(entry: ProjectLibrary.ProjectIndexEntry) {
        let paths = ProjectPaths(projectID: entry.id, within: viewModel.library.root)
        NSWorkspace.shared.activateFileViewerSelecting([paths.root])
    }

    private func confirmDelete(entry: ProjectLibrary.ProjectIndexEntry) {
        let alert = NSAlert()
        alert.messageText = "Delete \(entry.title)?"
        alert.informativeText = "This will remove the project directory and all of its passes, summaries, and exports. This action can't be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            do {
                try viewModel.library.delete(entry.id)
                Task { await viewModel.refreshRecentProjects() }
            } catch {
                let err = NSAlert(error: error)
                err.runModal()
            }
        }
    }

    // MARK: - Filtering / sorting

    private var filteredEntries: [ProjectLibrary.ProjectIndexEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matches = viewModel.library.index.filter { entry in
            if q.isEmpty { return true }
            if entry.title.lowercased().contains(q) { return true }
            return entry.speakerNames.contains { $0.lowercased().contains(q) }
        }
        switch sort {
        case .mostRecent:
            return matches.sorted { $0.updatedAt > $1.updatedAt }
        case .name:
            return matches.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .duration:
            return matches.sorted { $0.durationSeconds > $1.durationSeconds }
        }
    }

    // MARK: - Formatters

    private static func duration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    private static func relative(_ date: Date) -> String {
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .short
        return fmt.localizedString(for: date, relativeTo: Date())
    }
}
