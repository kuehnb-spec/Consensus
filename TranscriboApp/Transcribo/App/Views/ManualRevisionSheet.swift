import AppKit
import SwiftUI

/// Rewrite-native manual editor. Saves corrected text as the project's
/// `.manual` pass so every export format uses the human-revised transcript.
struct ManualRevisionSheet: View {
    @Bindable var viewModel: DeepReadViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var text: String = ""
    @State private var originalText: String = ""
    @State private var findText: String = ""
    @State private var replaceText: String = ""
    @State private var selectedMatchIndex: Int = 0
    @State private var caseSensitive: Bool = false
    @State private var statusMessage: String = ""

    private var hasEdits: Bool {
        text != originalText
    }

    private var matches: [Range<String.Index>] {
        Self.ranges(of: findText, in: text, caseSensitive: caseSensitive)
    }

    var body: some View {
        HStack(spacing: 0) {
            editorColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
                .overlay(ConsensusTheme.Colors.border)

            revisionTools
                .frame(width: 300)
                .frame(maxHeight: .infinity)
        }
        .frame(minWidth: 900, idealWidth: 1040, minHeight: 620, idealHeight: 740)
        .background(ConsensusTheme.Colors.background)
        .onAppear(perform: loadTranscript)
    }

    private var editorColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(ConsensusTheme.Spacing.lg)

            Divider()
                .overlay(ConsensusTheme.Colors.border)

            ManualTranscriptTextView(
                text: $text,
                findText: findText,
                selectedMatchIndex: selectedMatchIndex,
                caseSensitive: caseSensitive
            )
            .background(ConsensusTheme.Colors.surfacePrimary.opacity(0.7))

            Divider()
                .overlay(ConsensusTheme.Colors.border)

            bottomBar
                .padding(ConsensusTheme.Spacing.lg)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: ConsensusTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xs) {
                Text("Manual revision")
                    .font(ConsensusType.display(size: 22, weight: .semibold))
                    .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                Text("Edit speaker turns directly. Keep headers like [SPEAKER @ 00:00] so timings and exports stay structured.")
                    .font(ConsensusType.displayCaption)
                    .foregroundStyle(ConsensusTheme.Colors.textSecondary)
            }

            Spacer()

            if hasEdits {
                Text("Unsaved edits")
                    .font(ConsensusType.displayCaption.weight(.medium))
                    .foregroundStyle(ConsensusTheme.Colors.confidenceAmber)
                    .padding(.horizontal, ConsensusTheme.Spacing.sm)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(ConsensusTheme.Colors.confidenceAmber.opacity(0.14))
                    )
            }
        }
    }

    private var revisionTools: some View {
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.lg) {
            Text("Find & replace")
                .font(ConsensusType.displaySubheading)
                .foregroundStyle(ConsensusTheme.Colors.textPrimary)

            VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.sm) {
                Text("Find")
                    .font(ConsensusType.displayEyebrow)
                    .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                    .tracking(0.8)
                TextField("Text to find", text: $findText)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: findText) { _, _ in selectedMatchIndex = 0 }

                HStack {
                    Text(matchSummary)
                        .font(ConsensusType.monoMetric)
                        .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                    Spacer()
                    Toggle("Aa", isOn: $caseSensitive)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .tint(ConsensusTheme.Colors.accent)
                        .help("Match case")
                }
            }

            VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.sm) {
                Text("Replace")
                    .font(ConsensusType.displayEyebrow)
                    .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                    .tracking(0.8)
                TextField("Replacement text", text: $replaceText)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: ConsensusTheme.Spacing.sm) {
                Button {
                    selectedMatchIndex = max(0, selectedMatchIndex - 1)
                } label: {
                    Label("Previous", systemImage: "chevron.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(matches.isEmpty || selectedMatchIndex == 0)
                .help("Previous match")

                Button {
                    selectedMatchIndex = min(matches.count - 1, selectedMatchIndex + 1)
                } label: {
                    Label("Find Next", systemImage: "chevron.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(matches.isEmpty || selectedMatchIndex >= matches.count - 1)
                .help("Next match")
            }

            Button {
                replaceCurrent()
            } label: {
                Label("Replace", systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(matches.isEmpty)

            Button {
                replaceAll()
            } label: {
                Label("Replace All", systemImage: "arrow.triangle.2.circlepath.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(ConsensusTheme.Colors.accent)
            .disabled(matches.isEmpty)

            Divider()
                .overlay(ConsensusTheme.Colors.border)

            VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.sm) {
                Text("Format")
                    .font(ConsensusType.displayEyebrow)
                    .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                    .tracking(0.8)
                Text("[SPEAKER @ 00:00]\nCorrected dialogue text...")
                    .font(ConsensusType.monoLog)
                    .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                    .padding(ConsensusTheme.Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: ConsensusTheme.Radius.md, style: .continuous)
                            .fill(ConsensusTheme.Colors.surfaceSecondary.opacity(0.56))
                            .overlay(
                                RoundedRectangle(cornerRadius: ConsensusTheme.Radius.md, style: .continuous)
                                    .stroke(ConsensusTheme.Colors.borderSubtle, lineWidth: 1)
                            )
                    )
            }

            Spacer()
        }
        .padding(ConsensusTheme.Spacing.lg)
        .background(ConsensusTheme.Colors.surfacePrimary.opacity(0.42))
    }

    private var bottomBar: some View {
        HStack(spacing: ConsensusTheme.Spacing.md) {
            if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(ConsensusType.displayCaption)
                    .foregroundStyle(ConsensusTheme.Colors.textSecondary)
            }

            Spacer()

            Button("Reset") {
                text = originalText
                statusMessage = "Reverted local edits"
            }
            .buttonStyle(.bordered)
            .disabled(!hasEdits)

            Button("Cancel") {
                dismiss()
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(.cancelAction)

            Button {
                if viewModel.applyManualRevision(text: text) {
                    dismiss()
                }
            } label: {
                Label("Save Revision", systemImage: "checkmark")
                    .padding(.horizontal, ConsensusTheme.Spacing.xs)
            }
            .buttonStyle(.borderedProminent)
            .tint(ConsensusTheme.Colors.accent)
            .keyboardShortcut("s", modifiers: [.command])
            .disabled(!hasEdits)
        }
    }

    private var matchSummary: String {
        guard !findText.isEmpty else { return "No search" }
        guard !matches.isEmpty else { return "0 matches" }
        return "\(selectedMatchIndex + 1) of \(matches.count)"
    }

    private func loadTranscript() {
        let loaded = viewModel.manualRevisionText() ?? ""
        text = loaded
        originalText = loaded
        statusMessage = loaded.isEmpty ? "No active transcript loaded" : ""
    }

    private func replaceCurrent() {
        let currentMatches = matches
        guard !currentMatches.isEmpty else { return }
        let index = min(selectedMatchIndex, currentMatches.count - 1)
        text.replaceSubrange(currentMatches[index], with: replaceText)
        selectedMatchIndex = min(index, max(0, matches.count - 1))
        statusMessage = "Replaced 1 match"
    }

    private func replaceAll() {
        let currentMatches = matches
        guard !currentMatches.isEmpty else { return }
        for range in currentMatches.reversed() {
            text.replaceSubrange(range, with: replaceText)
        }
        selectedMatchIndex = 0
        statusMessage = "Replaced \(currentMatches.count) matches"
    }

    private static func ranges(
        of query: String,
        in text: String,
        caseSensitive: Bool
    ) -> [Range<String.Index>] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var ranges: [Range<String.Index>] = []
        var searchStart = text.startIndex
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]

        while searchStart < text.endIndex,
              let range = text.range(of: trimmed, options: options, range: searchStart..<text.endIndex) {
            ranges.append(range)
            searchStart = range.upperBound
        }
        return ranges
    }
}

private struct ManualTranscriptTextView: NSViewRepresentable {
    @Binding var text: String
    var findText: String
    var selectedMatchIndex: Int
    var caseSensitive: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 18, height: 18)
        textView.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        textView.textColor = NSColor(ConsensusTheme.Colors.textPrimary)
        textView.insertionPointColor = NSColor(ConsensusTheme.Colors.accent)
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor(ConsensusTheme.Colors.accent).withAlphaComponent(0.35),
            .foregroundColor: NSColor.white,
        ]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.autoresizingMask = [.width]

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        context.coordinator.isProgrammaticUpdate = true
        if textView.string != text {
            textView.string = text
        }
        context.coordinator.isProgrammaticUpdate = false
        context.coordinator.updateSearchHighlight(in: textView)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ManualTranscriptTextView
        var isProgrammaticUpdate = false

        init(parent: ManualTranscriptTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isProgrammaticUpdate,
                  let textView = notification.object as? NSTextView
            else { return }
            parent.text = textView.string
        }

        func updateSearchHighlight(in textView: NSTextView) {
            guard let layoutManager = textView.layoutManager,
                  let textStorage = textView.textStorage
            else { return }

            let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: fullRange)

            let ranges = Self.nsRanges(
                of: parent.findText,
                in: textView.string,
                caseSensitive: parent.caseSensitive
            )
            guard !ranges.isEmpty else { return }

            let ambientHighlight = NSColor(ConsensusTheme.Colors.accent).withAlphaComponent(0.16)
            let activeHighlight = NSColor(ConsensusTheme.Colors.confidenceAmber).withAlphaComponent(0.42)
            for range in ranges {
                layoutManager.addTemporaryAttribute(.backgroundColor, value: ambientHighlight, forCharacterRange: range)
            }

            let activeIndex = min(parent.selectedMatchIndex, ranges.count - 1)
            let activeRange = ranges[activeIndex]
            layoutManager.addTemporaryAttribute(.backgroundColor, value: activeHighlight, forCharacterRange: activeRange)

            if NSMaxRange(activeRange) <= textStorage.length {
                textView.setSelectedRange(activeRange)
                textView.scrollRangeToVisible(activeRange)
            }
        }

        private static func nsRanges(
            of query: String,
            in text: String,
            caseSensitive: Bool
        ) -> [NSRange] {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }

            let options: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
            let nsText = text as NSString
            var ranges: [NSRange] = []
            var searchRange = NSRange(location: 0, length: nsText.length)

            while searchRange.length > 0 {
                let found = nsText.range(of: trimmed, options: options, range: searchRange)
                guard found.location != NSNotFound else { break }
                ranges.append(found)
                let nextLocation = found.location + found.length
                guard nextLocation < nsText.length else { break }
                searchRange = NSRange(location: nextLocation, length: nsText.length - nextLocation)
            }

            return ranges
        }
    }
}
