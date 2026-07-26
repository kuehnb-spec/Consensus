import SwiftUI

struct SegmentRow: View {
    let segment: TranscriptionSegment
    let displayName: String
    let speakerColor: Color
    let showSpeakerHeader: Bool
    var searchHighlight: String? = nil
    var isPlaying: Bool = false
    var isSelected: Bool = false
    var onTap: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xs) {
            if showSpeakerHeader {
                HStack(spacing: ConsensusTheme.Spacing.sm) {
                    SpeakerBadge(name: displayName, color: speakerColor)

                    Text(TimeFormatting.timestamp(segment.start))
                        .font(ConsensusTheme.Fonts.mono(.caption))
                        .foregroundStyle(ConsensusTheme.Colors.textTertiary)

                    if isPlaying {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.caption2)
                            .foregroundStyle(ConsensusTheme.Colors.accent)
                    }
                }
                .padding(.top, ConsensusTheme.Spacing.sm)
            }

            // Text with optional search highlighting
            if let highlight = searchHighlight, !highlight.isEmpty {
                highlightedText(segment.text, highlight: highlight)
                    .font(ConsensusTheme.Fonts.body)
                    .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(segment.text)
                    .font(ConsensusTheme.Fonts.body)
                    .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 1)
        .padding(.horizontal, ConsensusTheme.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: ConsensusTheme.Radius.sm)
                .fill(isPlaying ? ConsensusTheme.Colors.accent.opacity(0.08) : (isSelected ? ConsensusTheme.Colors.accentMuted : Color.clear))
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: ConsensusTheme.Radius.sm)
                            .stroke(ConsensusTheme.Colors.accent.opacity(0.3), lineWidth: 1)
                    }
                }
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onTap?()
        }
        .help("Click to play this segment")
    }

    /// Build text with search term highlighted.
    private func highlightedText(_ text: String, highlight: String) -> Text {
        let ranges = findRanges(in: text, of: highlight)
        guard !ranges.isEmpty else {
            return Text(text)
        }

        var result = Text("")
        var currentIndex = text.startIndex

        for range in ranges {
            if currentIndex < range.lowerBound {
                result = result + Text(text[currentIndex..<range.lowerBound])
            }
            result = result + Text(text[range])
                .foregroundColor(ConsensusTheme.Colors.accent)
                .bold()
            currentIndex = range.upperBound
        }

        if currentIndex < text.endIndex {
            result = result + Text(text[currentIndex...])
        }

        return result
    }

    private func findRanges(in text: String, of searchTerm: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var searchRange = text.startIndex..<text.endIndex

        while let range = text.range(of: searchTerm, options: .caseInsensitive, range: searchRange) {
            ranges.append(range)
            searchRange = range.upperBound..<text.endIndex
        }

        return ranges
    }
}
