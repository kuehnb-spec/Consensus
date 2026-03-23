import SwiftUI

/// Glassmorphism card modifier — replaces GroupBox throughout the app.
/// Uses `.ultraThinMaterial` background with 1px border and rounded corners.
struct ConsensusCard: ViewModifier {
    var label: String?
    var labelIcon: String?
    var padding: CGFloat = ConsensusTheme.Spacing.lg

    func body(content: Content) -> some View {
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.lg) {
            if let label {
                HStack(spacing: ConsensusTheme.Spacing.sm) {
                    if let icon = labelIcon {
                        Image(systemName: icon)
                            .foregroundStyle(ConsensusTheme.Colors.accent)
                    }
                    Text(label)
                        .font(ConsensusTheme.Fonts.heading)
                        .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                }
            }
            content
        }
        .padding(padding)
        .background {
            RoundedRectangle(cornerRadius: ConsensusTheme.Radius.lg)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: ConsensusTheme.Radius.lg)
                        .stroke(ConsensusTheme.Colors.border, lineWidth: 1)
                }
        }
    }
}

/// Elevated surface card — for content that sits above the background
/// without the frosted glass effect. Uses solid surface color.
struct ConsensusSurfaceCard: ViewModifier {
    var level: SurfaceLevel = .primary
    var padding: CGFloat = ConsensusTheme.Spacing.lg

    enum SurfaceLevel {
        case primary, secondary, elevated

        var color: Color {
            switch self {
            case .primary:   return ConsensusTheme.Colors.surfacePrimary
            case .secondary: return ConsensusTheme.Colors.surfaceSecondary
            case .elevated:  return ConsensusTheme.Colors.surfaceElevated
            }
        }
    }

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background {
                RoundedRectangle(cornerRadius: ConsensusTheme.Radius.lg)
                    .fill(level.color)
                    .overlay {
                        RoundedRectangle(cornerRadius: ConsensusTheme.Radius.lg)
                            .stroke(ConsensusTheme.Colors.border, lineWidth: 1)
                    }
            }
    }
}

// MARK: - View Extensions

extension View {
    /// Wraps content in a glassmorphism card with optional label.
    func consensusCard(label: String? = nil, icon: String? = nil) -> some View {
        modifier(ConsensusCard(label: label, labelIcon: icon))
    }

    /// Wraps content in a glassmorphism card with compact padding.
    func consensusCardCompact(label: String? = nil, icon: String? = nil) -> some View {
        modifier(ConsensusCard(label: label, labelIcon: icon, padding: ConsensusTheme.Spacing.md))
    }

    /// Wraps content in a solid surface card.
    func surfaceCard(level: ConsensusSurfaceCard.SurfaceLevel = .primary) -> some View {
        modifier(ConsensusSurfaceCard(level: level))
    }
}
