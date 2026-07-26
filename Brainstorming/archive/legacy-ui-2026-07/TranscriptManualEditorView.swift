import SwiftUI
import AppKit

/// Manual transcript editor — opens as a sheet over the main window. The user can
/// edit the transcript as free-form text (with `[SPEAKER @ HH:MM:SS]` headers),
/// and click "Play Context" to hear the audio around the cursor so they can
/// verify each word against the recording.
///
/// Serves two purposes:
///   1. Final-output editing: fix errors the automated pipeline missed before
///      exporting to PDF / DOCX / etc.
///   2. Ground-truth creation: produce a hand-perfected transcript that the
///      benchmark harness can score pipeline output against.
struct TranscriptManualEditorView: View {
    @Environment(TranscriptionViewModel.self) private var viewModel
    @Environment(\.dismiss) private var dismiss

    @State private var text: String = ""
    @State private var playWindowSeconds: Double = 5
    @State private var isPlaying: Bool = false
    @State private var statusMessage: String = ""
    @State private var cursorOffset: Int = 0
    @State private var hasEdits: Bool = false

    /// Keeps the original segments around so we can recover word timings on save.
    @State private var originalSegments: [TranscriptionSegment] = []

    private let audioPlayer = AudioContextPlayer()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(ConsensusTheme.Colors.border)
            editorPane
            Divider().overlay(ConsensusTheme.Colors.border)
            bottomBar
        }
        .frame(minWidth: 780, idealWidth: 920, minHeight: 560, idealHeight: 720)
        .background(ConsensusTheme.Colors.surfacePrimary)
        .onAppear(perform: loadCurrentTranscript)
        .onDisappear {
            audioPlayer.stop()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: ConsensusTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xs) {
                Text("Edit Transcript")
                    .font(.title2.bold())
                    .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                Text("Position your cursor and click Play Context to hear the audio. Save to apply your edits to this pass.")
                    .font(.caption)
                    .foregroundStyle(ConsensusTheme.Colors.textSecondary)
            }

            Spacer()

            if hasEdits {
                Text("Unsaved edits")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(ConsensusTheme.Colors.confidenceAmber)
                    .padding(.horizontal, ConsensusTheme.Spacing.sm)
                    .padding(.vertical, 4)
                    .background {
                        Capsule().fill(ConsensusTheme.Colors.confidenceAmber.opacity(0.15))
                    }
            }
        }
        .padding(ConsensusTheme.Spacing.lg)
    }

    // MARK: - Editor

    private var editorPane: some View {
        TrackedTextEditor(text: $text, cursorOffset: $cursorOffset, hasEdits: $hasEdits)
            .padding(ConsensusTheme.Spacing.md)
            .background(ConsensusTheme.Colors.surfaceSecondary.opacity(0.3))
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: ConsensusTheme.Spacing.md) {
            // Play context controls
            Button {
                playContextAtCursor()
            } label: {
                HStack(spacing: ConsensusTheme.Spacing.xs) {
                    Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                    Text(isPlaying ? "Stop" : "Play Context")
                }
            }
            .buttonStyle(ConsensusPillButtonStyle())
            .help("Play \(Int(playWindowSeconds))s of audio before and after the cursor.")

            Picker("Context", selection: $playWindowSeconds) {
                Text("±2s").tag(2.0)
                Text("±5s").tag(5.0)
                Text("±10s").tag(10.0)
            }
            .pickerStyle(.segmented)
            .frame(width: 180)

            if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            Button("Cancel") {
                audioPlayer.stop()
                dismiss()
            }
            .buttonStyle(ConsensusSecondaryButtonStyle())
            .keyboardShortcut(.cancelAction)

            Button {
                saveEdits()
            } label: {
                Text("Save to Transcript")
            }
            .buttonStyle(ConsensusPrimaryButtonStyle())
            .keyboardShortcut("s", modifiers: [.command])
            .disabled(!hasEdits)
        }
        .padding(ConsensusTheme.Spacing.lg)
    }

    // MARK: - Actions

    private func loadCurrentTranscript() {
        guard let result = viewModel.result else {
            statusMessage = "No active transcript to edit."
            return
        }
        originalSegments = result.segments
        text = TranscriptManualEditorCodec.serialize(
            segments: result.segments,
            mapping: viewModel.speakerMapping
        )
        hasEdits = false
        cursorOffset = 0
    }

    private func playContextAtCursor() {
        if isPlaying {
            audioPlayer.stop()
            isPlaying = false
            statusMessage = ""
            return
        }

        guard let url = viewModel.currentAudioURL else {
            statusMessage = "Audio file not found — cannot play context."
            return
        }

        let cursorTime = TranscriptManualEditorCodec.timeForCursor(
            in: text,
            cursorOffset: cursorOffset,
            fallbackDuration: viewModel.audioDuration
        )

        let window = playWindowSeconds
        let start = max(0, cursorTime - window)
        let end = min(viewModel.audioDuration, cursorTime + window)

        statusMessage = "Playing \(formatTime(start)) → \(formatTime(end))"
        isPlaying = true
        audioPlayer.play(url: url, from: start, to: end) { [self] in
            Task { @MainActor in
                self.isPlaying = false
                if self.statusMessage.hasPrefix("Playing") {
                    self.statusMessage = ""
                }
            }
        }
    }

    private func saveEdits() {
        audioPlayer.stop()
        let turns = TranscriptManualEditorCodec.parse(text)
        guard !turns.isEmpty else {
            statusMessage = "No valid speaker turns found — cannot save. Every turn needs a `[SPEAKER @ 00:00:00]` header."
            return
        }

        let newSegments = TranscriptManualEditorCodec.rebuildSegments(
            from: turns,
            original: originalSegments,
            mapping: viewModel.speakerMapping,
            audioDuration: viewModel.audioDuration
        )

        viewModel.applyManualEdits(segments: newSegments)
        dismiss()
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - AppKit-backed editor with cursor tracking

/// A bridged NSTextView that tracks cursor position. SwiftUI's `TextEditor`
/// doesn't expose selection range, which we need for the "Play Context" button.
private struct TrackedTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var cursorOffset: Int
    @Binding var hasEdits: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, cursorOffset: $cursorOffset, hasEdits: $hasEdits)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = false
        scroll.borderType = .noBorder

        guard let textView = scroll.documentView as? NSTextView else {
            return scroll
        }

        textView.delegate = context.coordinator
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.string = text
        textView.backgroundColor = NSColor(Color(red: 0.10, green: 0.11, blue: 0.13))
        textView.textColor = NSColor(ConsensusTheme.Colors.textPrimary)
        textView.insertionPointColor = NSColor(ConsensusTheme.Colors.accent)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        // Only overwrite when the binding differs from the view — avoid
        // clobbering the user's in-progress edits.
        if textView.string != text {
            textView.string = text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        @Binding var cursorOffset: Int
        @Binding var hasEdits: Bool

        init(text: Binding<String>, cursorOffset: Binding<Int>, hasEdits: Binding<Bool>) {
            self._text = text
            self._cursorOffset = cursorOffset
            self._hasEdits = hasEdits
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
            hasEdits = true
            updateCursor(textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            updateCursor(textView)
        }

        private func updateCursor(_ textView: NSTextView) {
            let selection = textView.selectedRange()
            cursorOffset = selection.location
        }
    }
}
