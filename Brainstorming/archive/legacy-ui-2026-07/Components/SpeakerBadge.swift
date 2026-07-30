import SwiftUI

struct SpeakerBadge: View {
    let name: String
    let color: Color

    var body: some View {
        Text(name)
            .font(ConsensusTheme.Fonts.mono(.caption2).bold())
            .foregroundStyle(.white)
            .padding(.horizontal, ConsensusTheme.Spacing.sm)
            .padding(.vertical, 3)
            .background(color, in: Capsule())
    }

    /// A palette of distinct speaker colors, tuned for dark backgrounds.
    static let palette: [Color] = ConsensusTheme.Colors.speakerPalette

    /// Get a consistent color for a speaker index.
    static func color(for index: Int) -> Color {
        palette[index % palette.count]
    }

    /// Get a consistent color for a speaker ID from a list of known speakers.
    static func color(for speakerID: String, in speakers: [String]) -> Color {
        let index = speakers.firstIndex(of: speakerID) ?? 0
        return color(for: index)
    }
}
