import SwiftUI

struct SegmentRow: View {
    let segment: TranscriptionSegment
    let displayName: String
    let speakerColor: Color
    let showSpeakerHeader: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xs) {
            if showSpeakerHeader {
                HStack(spacing: ConsensusTheme.Spacing.sm) {
                    SpeakerBadge(name: displayName, color: speakerColor)

                    Text(TimeFormatting.timestamp(segment.start))
                        .font(ConsensusTheme.Fonts.mono(.caption))
                        .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                }
                .padding(.top, ConsensusTheme.Spacing.sm)
            }

            Text(segment.text)
                .font(ConsensusTheme.Fonts.body)
                .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
