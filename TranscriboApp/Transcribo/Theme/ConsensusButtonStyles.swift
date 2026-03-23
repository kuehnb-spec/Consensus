import SwiftUI

/// Primary action button — filled indigo with white text.
/// Use for the main action on each screen (Transcribe, Export, Save Consensus).
struct ConsensusPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, ConsensusTheme.Spacing.xl)
            .padding(.vertical, ConsensusTheme.Spacing.md)
            .background {
                RoundedRectangle(cornerRadius: ConsensusTheme.Radius.md)
                    .fill(ConsensusTheme.Colors.accent)
                    .opacity(configuration.isPressed ? 0.8 : 1)
            }
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Secondary action button — 1px indigo border with indigo text.
/// Use for alternative actions (Deep Review, Close Project).
struct ConsensusSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(ConsensusTheme.Colors.accent)
            .padding(.horizontal, ConsensusTheme.Spacing.lg)
            .padding(.vertical, ConsensusTheme.Spacing.sm)
            .background {
                RoundedRectangle(cornerRadius: ConsensusTheme.Radius.md)
                    .stroke(ConsensusTheme.Colors.borderAccent, lineWidth: 1)
            }
            .opacity(isEnabled ? 1 : 0.45)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Ghost button — plain text with hover highlight.
/// Use for tertiary actions, navigation, and non-destructive options.
struct ConsensusGhostButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(ConsensusTheme.Colors.textSecondary)
            .padding(.horizontal, ConsensusTheme.Spacing.md)
            .padding(.vertical, ConsensusTheme.Spacing.xs)
            .background {
                RoundedRectangle(cornerRadius: ConsensusTheme.Radius.sm)
                    .fill(configuration.isPressed ? ConsensusTheme.Colors.accentMuted : Color.clear)
            }
            .opacity(isEnabled ? 1 : 0.45)
    }
}

/// Small pill button — compact, rounded, for inline actions.
/// Use inside cards for "Use Left", "Use Middle", and similar.
struct ConsensusPillButtonStyle: ButtonStyle {
    var tint: Color = ConsensusTheme.Colors.accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, ConsensusTheme.Spacing.md)
            .padding(.vertical, ConsensusTheme.Spacing.xs)
            .background {
                Capsule()
                    .fill(tint.opacity(0.12))
                    .overlay {
                        Capsule()
                            .stroke(tint.opacity(0.25), lineWidth: 1)
                    }
            }
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

// MARK: - Convenience Extensions

extension ButtonStyle where Self == ConsensusPrimaryButtonStyle {
    static var consensusPrimary: ConsensusPrimaryButtonStyle { .init() }
}

extension ButtonStyle where Self == ConsensusSecondaryButtonStyle {
    static var consensusSecondary: ConsensusSecondaryButtonStyle { .init() }
}

extension ButtonStyle where Self == ConsensusGhostButtonStyle {
    static var consensusGhost: ConsensusGhostButtonStyle { .init() }
}
