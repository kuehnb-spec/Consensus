import SwiftUI

/// Persistent summary sidepane that can be toggled on any screen.
/// Shows the LLM-generated summary with action items, editable in-place.
/// Supports copy, standalone export, and integration with legal PDF cover page.
struct SummarySidepaneView: View {
    @Environment(TranscriptionViewModel.self) private var viewModel

    var body: some View {
        @Bindable var vm = viewModel

        VStack(spacing: 0) {
            // Header
            HStack {
                Label("Summary", systemImage: "text.badge.star")
                    .font(ConsensusTheme.Fonts.mono(size: 10, weight: .bold))
                    .foregroundStyle(ConsensusTheme.Colors.accent)
                    .tracking(0.5)

                Spacer()

                // Action buttons
                HStack(spacing: ConsensusTheme.Spacing.xs) {
                    if viewModel.summaryResult != nil {
                        Button {
                            if let text = viewModel.summaryResult {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(text, forType: .string)
                            }
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                        .help("Copy summary to clipboard")

                        Button {
                            exportSummaryAsText()
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                        .help("Export summary as standalone document")
                    }

                    Button {
                        viewModel.showSummarySidepane = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                }
            }
            .padding(.horizontal, ConsensusTheme.Spacing.md)
            .padding(.vertical, ConsensusTheme.Spacing.sm)
            .background(ConsensusTheme.Colors.surfaceSecondary)

            Divider().overlay(ConsensusTheme.Colors.border)

            // Content area
            if viewModel.isSummaryRunning {
                VStack(spacing: ConsensusTheme.Spacing.md) {
                    ProgressView()
                        .controlSize(.small)
                    Text(viewModel.summaryProgress)
                        .font(.system(size: 11))
                        .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let summaryText = viewModel.summaryResult, !summaryText.isEmpty {
                // Editable summary
                VStack(spacing: 0) {
                    ScrollView {
                        TextEditor(text: $vm.summaryResult ?? "")
                            .font(.system(size: 12))
                            .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                            .scrollContentBackground(.hidden)
                            .padding(ConsensusTheme.Spacing.sm)
                    }
                    .background(ConsensusTheme.Colors.background)

                    Divider().overlay(ConsensusTheme.Colors.borderSubtle)

                    // Bottom bar
                    HStack(spacing: ConsensusTheme.Spacing.sm) {
                        Button {
                            Task { await viewModel.persistSummary() }
                        } label: {
                            Label("Save", systemImage: "checkmark")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(ConsensusGhostButtonStyle())

                        Spacer()

                        Button {
                            Task { await viewModel.runSummary() }
                        } label: {
                            Label("Regenerate", systemImage: "arrow.clockwise")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(ConsensusGhostButtonStyle())
                        .disabled(!viewModel.hasResult)
                    }
                    .padding(.horizontal, ConsensusTheme.Spacing.md)
                    .padding(.vertical, ConsensusTheme.Spacing.xs)
                    .background(ConsensusTheme.Colors.surfacePrimary)
                }
            } else {
                // Empty state — generate button
                VStack(spacing: ConsensusTheme.Spacing.lg) {
                    Spacer()

                    Image(systemName: "text.badge.star")
                        .font(.system(size: 32))
                        .foregroundStyle(ConsensusTheme.Colors.textTertiary.opacity(0.4))

                    Text("No summary yet")
                        .font(.caption)
                        .foregroundStyle(ConsensusTheme.Colors.textTertiary)

                    Button {
                        Task { await viewModel.runSummary() }
                    } label: {
                        Label("Generate Summary", systemImage: "sparkles")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(ConsensusPrimaryButtonStyle())
                    .disabled(!viewModel.hasResult)

                    Spacer()
                }
            }
        }
        .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
        .background(ConsensusTheme.Colors.surfacePrimary)
        .overlay(alignment: .leading) {
            Divider().overlay(ConsensusTheme.Colors.border)
        }
        .onAppear {
            viewModel.loadPersistedSummary()
        }
    }

    // MARK: - Export

    private func exportSummaryAsText() {
        guard let text = viewModel.summaryResult else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(viewModel.currentProject?.audioFileName ?? "summary")_summary.txt"
        panel.allowedContentTypes = [.plainText]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Optional Binding Helper

private extension Binding where Value == String? {
    /// Unwrap an optional String binding with a default.
    static func ?? (lhs: Binding<String?>, rhs: String) -> Binding<String> {
        Binding<String>(
            get: { lhs.wrappedValue ?? rhs },
            set: { lhs.wrappedValue = $0 }
        )
    }
}
