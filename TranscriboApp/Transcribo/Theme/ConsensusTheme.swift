import SwiftUI

/// Centralized design system for Consensus.
/// All colors, fonts, spacing, and radii should come from here — no hardcoded values in views.
enum ConsensusTheme {

    // MARK: - Colors

    enum Colors {
        // Backgrounds
        static let background        = Color(red: 0.059, green: 0.078, blue: 0.098)   // #0F1419
        static let surfacePrimary    = Color(red: 0.102, green: 0.122, blue: 0.149)   // #1A1F26
        static let surfaceSecondary  = Color(red: 0.137, green: 0.165, blue: 0.200)   // #232A33
        static let surfaceElevated   = Color(red: 0.173, green: 0.200, blue: 0.239)   // #2C333D

        // Accent
        static let accent            = Color(red: 0.388, green: 0.400, blue: 0.945)   // #6366F1
        static let accentSubtle      = accent.opacity(0.15)
        static let accentMuted       = accent.opacity(0.08)

        // Text
        static let textPrimary       = Color.white.opacity(0.90)
        static let textSecondary     = Color.white.opacity(0.60)
        static let textTertiary      = Color.white.opacity(0.35)
        static let textMuted         = Color.white.opacity(0.20)

        // Borders
        static let border            = Color.white.opacity(0.08)
        static let borderSubtle      = Color.white.opacity(0.05)
        static let borderAccent      = accent.opacity(0.40)

        // Confidence tiers
        static let confidenceGreen   = Color(red: 0.204, green: 0.827, blue: 0.600)   // #34D399
        static let confidenceAmber   = Color(red: 0.984, green: 0.749, blue: 0.141)   // #FBBF24
        static let confidenceRed     = Color(red: 0.973, green: 0.443, blue: 0.443)   // #F87171

        /// Returns the appropriate confidence tier color for a 0.0–1.0 value.
        static func confidenceTier(_ value: Float) -> Color {
            switch value {
            case ..<0.60:  return confidenceRed
            case ..<0.80:  return confidenceAmber
            default:       return confidenceGreen
            }
        }

        // Reconciliation difference tints (backgrounds at 15%)
        static let diffAligned       = Color(red: 0.204, green: 0.827, blue: 0.600).opacity(0.15)   // green tint
        static let diffPunctuation   = Color(red: 0.984, green: 0.749, blue: 0.141).opacity(0.15)   // amber tint
        static let diffSpeaker       = Color(red: 0.000, green: 0.898, blue: 1.000).opacity(0.15)   // cyan tint
        static let diffText          = Color(red: 1.000, green: 0.584, blue: 0.000).opacity(0.15)   // orange tint
        static let diffTextSpeaker   = Color(red: 1.000, green: 0.400, blue: 0.600).opacity(0.15)   // pink tint
        static let diffMissing       = Color(red: 0.973, green: 0.443, blue: 0.443).opacity(0.15)   // red tint

        // Reconciliation difference solid colors (for text/icons)
        static let diffAlignedSolid     = Color(red: 0.204, green: 0.827, blue: 0.600)   // green
        static let diffPunctuationSolid = Color(red: 0.984, green: 0.749, blue: 0.141)   // amber
        static let diffSpeakerSolid     = Color(red: 0.000, green: 0.898, blue: 1.000)   // cyan
        static let diffTextSolid        = Color(red: 1.000, green: 0.584, blue: 0.000)   // orange
        static let diffTextSpeakerSolid = Color(red: 1.000, green: 0.400, blue: 0.600)   // pink
        static let diffMissingSolid     = Color(red: 0.973, green: 0.443, blue: 0.443)   // red

        // Speaker palette (for speaker badges — refined for dark backgrounds)
        static let speakerPalette: [Color] = [
            Color(red: 0.400, green: 0.565, blue: 1.000),   // periwinkle
            Color(red: 0.655, green: 0.400, blue: 1.000),   // lavender
            Color(red: 1.000, green: 0.584, blue: 0.298),   // tangerine
            Color(red: 0.298, green: 0.847, blue: 0.580),   // seafoam
            Color(red: 1.000, green: 0.400, blue: 0.400),   // coral
            Color(red: 0.298, green: 0.788, blue: 0.812),   // teal
            Color(red: 1.000, green: 0.478, blue: 0.678),   // rose
            accent,                                           // indigo
            Color(red: 0.706, green: 0.553, blue: 0.384),   // sienna
            Color(red: 0.400, green: 0.847, blue: 0.745),   // mint
            Color(red: 0.298, green: 0.878, blue: 0.949),   // cyan
            Color(red: 0.984, green: 0.749, blue: 0.286),   // gold
        ]

        // Status
        static let success           = confidenceGreen
        static let warning           = confidenceAmber
        static let danger            = confidenceRed
    }

    // MARK: - Fonts

    enum Fonts {
        /// Monospaced font for timestamps, confidence percentages, and technical metadata.
        static func mono(_ style: Font.TextStyle = .caption) -> Font {
            .system(style, design: .monospaced)
        }

        /// Monospaced font with explicit size.
        static func mono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight, design: .monospaced)
        }

        /// Body text.
        static let body = Font.body
        /// Secondary text.
        static let subheadline = Font.subheadline
        /// Small labels and metadata.
        static let caption = Font.caption
        /// Tiny labels.
        static let caption2 = Font.caption2

        /// Section headings.
        static let heading = Font.title3.bold()
        /// Page titles.
        static let title = Font.largeTitle.bold()
        /// Subtitle / description.
        static let subtitle = Font.subheadline
    }

    // MARK: - Spacing

    enum Spacing {
        static let xs:  CGFloat = 4
        static let sm:  CGFloat = 8
        static let md:  CGFloat = 12
        static let lg:  CGFloat = 16
        static let xl:  CGFloat = 24
        static let xxl: CGFloat = 32
    }

    // MARK: - Corner Radius

    enum Radius {
        static let sm:  CGFloat = 6
        static let md:  CGFloat = 8
        static let lg:  CGFloat = 12
        static let xl:  CGFloat = 16
    }
}
