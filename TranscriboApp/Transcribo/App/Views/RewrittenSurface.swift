import SwiftUI

extension Notification.Name {
    static let consensusOpenAudioFile = Notification.Name("ConsensusOpenAudioFile")
}

/// Root wrapper for the app UI. Owns the per-launch `DeepReadViewModel` and
/// the stores it depends on, then routes to `DeepReadRootView`.
///
/// The VM is built lazily (on first appearance) so the legacy path pays no
/// cost when the flag is off. If either store fails to initialise, a simple
/// error card is shown instead of the root view.
struct RewrittenSurface: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var viewModel: DeepReadViewModel?
    @State private var setupError: String?

    var body: some View {
        Group {
            if let viewModel {
                DeepReadRootView(viewModel: viewModel)
            } else if let setupError {
                setupErrorCard(setupError)
            } else {
                Color.clear
                    .task { setup() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .consensusOpenAudioFile)) { _ in
            viewModel?.showFilePicker = true
        }
    }

    private func setup() {
        guard viewModel == nil, setupError == nil else { return }
        do {
            let library = try ProjectLibrary()
            let voice = try VoiceLibraryStore()
            try voice.reload()
            let vm = DeepReadViewModel(library: library, voiceStore: voice)
            vm.mode = ModeState(rawValue: settings.rewrittenDefaultModeRaw) ?? .deepRead
            viewModel = vm
        } catch {
            setupError = error.localizedDescription
        }
    }

    @ViewBuilder
    private func setupErrorCard(_ message: String) -> some View {
        VStack(spacing: ConsensusTheme.Spacing.md) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(ConsensusTheme.Colors.warning)
            Text("Could not open the rewritten surface")
                .font(ConsensusType.displayHeading)
                .foregroundStyle(ConsensusTheme.Colors.textPrimary)
            Text(message)
                .font(ConsensusType.displayCaption)
                .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Retry") { setup() }
                .buttonStyle(.bordered)
                .tint(ConsensusTheme.Colors.accent)
        }
        .padding(ConsensusTheme.Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ConsensusTheme.Colors.background)
    }
}
