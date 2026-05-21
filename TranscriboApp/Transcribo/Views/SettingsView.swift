import SwiftUI

struct SettingsView: View {
    @StateObject private var settings = AppSettings()

    /// Presented when the user first flips `enableForcedAlignment` on.
    /// Explains the one-time model download and lets them cancel.
    @State private var showForcedAlignmentFirstRunConfirm: Bool = false

    /// Pending state for the toggle while the confirmation dialog is open.
    /// If the user cancels, we revert without triggering the download.
    @State private var pendingForcedAlignmentValue: Bool = false

    var body: some View {
        Form {
            Section("Transcription Defaults") {
                Picker("Preferred Model", selection: $settings.preferredModel) {
                    ForEach(WhisperModel.allCases) { model in
                        Text("\(model.displayName) (\(model.approximateSize))")
                            .tag(model.rawValue)
                    }
                }

                Stepper("Default Min Speakers: \(settings.defaultMinSpeakers)",
                        value: $settings.defaultMinSpeakers, in: 0...20)

                Stepper("Default Max Speakers: \(settings.defaultMaxSpeakers)",
                        value: $settings.defaultMaxSpeakers, in: 0...20)
            }

            Section("Deep Review") {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Patch-centered review")
                    Text("Consensus now treats the VibeVoice transcript as canonical, uses a second ASR as a heatmap, and applies only audio-verified word patches. The older full-transcript reconciliation path is archived for reference and is no longer an app mode.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Toggle(isOn: forcedAlignmentToggleBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Rebuild word timings from audio")
                        Text("Experimental timing rebuild for patched transcripts. Useful for subtitle timing and speaker-boundary debugging; off by default while the patch editor is being calibrated.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if settings.enableForcedAlignment {
                    Text("Uses Qwen3-ForcedAligner (local, ~500 MB, Apple Silicon only). Cached in ~/Library/Caches/qwen3-speech/.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Diagnostics") {
                Toggle(isOn: $settings.diagnosticModeEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Diagnostic Mode")
                            .font(.body)
                        Text("Log every speaker-smoother reassignment, patch-review decision, and forced-alignment word move. Use \"Save Report\" in the Process Log to capture a full audit. Useful for investigating unexpected transcript output; leave off for normal use.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if settings.diagnosticModeEnabled {
                    Text("Diagnostic reports are saved to ~/Documents/Consensus Diagnostics/ on demand.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("About") {
                LabeledContent("App", value: "Consensus")
                LabeledContent("Version", value: "1.0.0")
                LabeledContent("Engine", value: "VibeVoice + Patch Review")
                Text("All processing happens locally on your Mac. No data leaves your machine.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 440)
        .confirmationDialog(
            "Enable forced alignment?",
            isPresented: $showForcedAlignmentFirstRunConfirm,
            titleVisibility: .visible
        ) {
            Button("Enable and Download") {
                settings.enableForcedAlignment = true
                settings.hasSeenForcedAlignmentWarning = true
            }
            Button("Cancel", role: .cancel) {
                // Revert the pending toggle without triggering the download.
                pendingForcedAlignmentValue = false
            }
        } message: {
            Text("""
            The first time you use this, Consensus will download about 500 MB of model weights for Qwen3-ForcedAligner (Apache 2.0, Apple Silicon only) and cache them in ~/Library/Caches/qwen3-speech/.

            Later runs load the cached model in under 2 seconds. All processing stays on your Mac.
            """)
        }
    }

    /// Binding that intercepts the toggle transition so we can show the
    /// first-run confirmation dialog before flipping the underlying setting.
    private var forcedAlignmentToggleBinding: Binding<Bool> {
        Binding<Bool>(
            get: { settings.enableForcedAlignment },
            set: { newValue in
                if newValue && !settings.hasSeenForcedAlignmentWarning {
                    // First enable: show the confirmation dialog. Actual flip
                    // happens in the dialog's confirm button.
                    pendingForcedAlignmentValue = true
                    showForcedAlignmentFirstRunConfirm = true
                } else {
                    // Either disabling, or re-enabling after first warning was
                    // acknowledged. Flip immediately.
                    settings.enableForcedAlignment = newValue
                }
            }
        )
    }
}
