import SwiftUI

/// Typography catalog for the rewritten UI. Pairs the three bundled families
/// with the role they play:
///
/// - **Inter** – display and UI text
/// - **Source Serif 4** – transcript body
/// - **JetBrains Mono** – timestamps, percentages, metadata
///
/// Fonts are registered at app launch by `FontRegistration.registerBundledFonts()`.
/// This enum is the single source of truth for font sizes and weights in the
/// new UI — views should not call `Font.custom` directly.
///
/// Lives alongside (not inside) `ConsensusTheme` so the legacy theme stays
/// untouched during the rewrite. The old UI continues to use the system font
/// via `ConsensusTheme.Fonts`.
enum ConsensusType {
    /// CoreText family names — as embedded in each font's `name` table.
    /// These are what `Font.custom` resolves against.
    enum Family {
        static let display = "Inter"
        static let serif   = "Source Serif 4"
        static let mono    = "JetBrains Mono"
    }

    // MARK: Display / UI (Inter)

    /// Page titles — "Transcripts", "Project Library".
    static let displayTitle = Font.custom(Family.display, size: 28, relativeTo: .largeTitle)
        .weight(.semibold)

    /// Section headings within a view.
    static let displayHeading = Font.custom(Family.display, size: 18, relativeTo: .title3)
        .weight(.semibold)

    /// Subheadings and prominent labels.
    static let displaySubheading = Font.custom(Family.display, size: 14, relativeTo: .headline)
        .weight(.medium)

    /// Body copy used in the UI chrome (dialogs, cards, buttons).
    static let displayBody = Font.custom(Family.display, size: 13, relativeTo: .body)

    /// Small labels and secondary metadata.
    static let displayCaption = Font.custom(Family.display, size: 11, relativeTo: .caption)

    /// Tiny uppercase labels — the "SUMMARY" header above the summary pane.
    static let displayEyebrow = Font.custom(Family.display, size: 10, relativeTo: .caption2)
        .weight(.semibold)

    // MARK: Transcript (Source Serif)

    /// Default transcript body. Serif for long-form readability.
    static let transcriptBody = Font.custom(Family.serif, size: 15, relativeTo: .body)

    /// Transcript body at a larger comfortable reading size — matches the
    /// Studio "Reader" sub-mode described in the rewrite plan.
    static let transcriptReader = Font.custom(Family.serif, size: 17, relativeTo: .body)

    /// Speaker names in the transcript header rows.
    static let transcriptSpeaker = Font.custom(Family.serif, size: 14, relativeTo: .headline)
        .weight(.bold)

    // MARK: Monospace (JetBrains Mono)

    /// Timestamps: `00:00:02`, `12:34.5`.
    static let monoTimestamp = Font.custom(Family.mono, size: 11, relativeTo: .caption)

    /// Confidence percentages and numeric metadata.
    static let monoMetric = Font.custom(Family.mono, size: 12, relativeTo: .footnote)

    /// Process log and diagnostic panels.
    static let monoLog = Font.custom(Family.mono, size: 11, relativeTo: .footnote)

    // MARK: Free-form helpers
    //
    // When a view needs a size/weight that doesn't fit the catalog above,
    // use these helpers. They keep the family reference centralised so a
    // future family swap is a single-file edit.

    static func display(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.custom(Family.display, size: size).weight(weight)
    }

    static func serif(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.custom(Family.serif, size: size).weight(weight)
    }

    static func mono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.custom(Family.mono, size: size).weight(weight)
    }
}
