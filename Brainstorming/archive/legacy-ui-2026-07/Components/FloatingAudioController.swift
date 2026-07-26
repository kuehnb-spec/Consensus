import SwiftUI

/// A floating bar pinned to the bottom of the reconciliation workspace,
/// showing playback state and keyboard shortcut hints.
struct FloatingAudioController: View {
    let isPlaying: Bool
    let canPlay: Bool
    let currentTimestamp: String?
    let onPlayStop: () -> Void

    var body: some View {
        HStack(spacing: ConsensusTheme.Spacing.lg) {
            // Play/Stop button
            Button(action: onPlayStop) {
                HStack(spacing: ConsensusTheme.Spacing.sm) {
                    Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                        .font(.body.weight(.semibold))
                    Text(isPlaying ? "Stop Context" : "Play Context")
                        .font(.subheadline.weight(.medium))
                }
                .foregroundStyle(isPlaying ? ConsensusTheme.Colors.confidenceAmber : ConsensusTheme.Colors.accent)
            }
            .buttonStyle(.plain)
            .disabled(!canPlay)
            .opacity(canPlay ? 1.0 : 0.4)

            if let timestamp = currentTimestamp {
                Text(timestamp)
                    .font(ConsensusTheme.Fonts.mono(.caption))
                    .foregroundStyle(ConsensusTheme.Colors.textSecondary)
            }

            Spacer()

            // Keyboard shortcut hints
            HStack(spacing: ConsensusTheme.Spacing.md) {
                KeyboardHint(key: "Space", label: "Play")
                KeyboardHint(key: "1", label: "Use A")
                KeyboardHint(key: "2", label: "Use B")
                KeyboardHint(key: "Return", label: "Next")
            }
        }
        .padding(.horizontal, ConsensusTheme.Spacing.xl)
        .padding(.vertical, ConsensusTheme.Spacing.md)
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(ConsensusTheme.Colors.border)
                        .frame(height: 1)
                }
        }
    }
}

/// A small styled keyboard key + label, e.g. [Space] Play
private struct KeyboardHint: View {
    let key: String
    let label: String

    var body: some View {
        HStack(spacing: ConsensusTheme.Spacing.xs) {
            Text(key)
                .font(ConsensusTheme.Fonts.mono(size: 10, weight: .medium))
                .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                .padding(.horizontal, ConsensusTheme.Spacing.xs + 2)
                .padding(.vertical, 2)
                .background {
                    RoundedRectangle(cornerRadius: ConsensusTheme.Radius.sm)
                        .fill(ConsensusTheme.Colors.surfaceSecondary)
                        .overlay {
                            RoundedRectangle(cornerRadius: ConsensusTheme.Radius.sm)
                                .stroke(ConsensusTheme.Colors.border, lineWidth: 1)
                        }
                }
            Text(label)
                .font(.caption2)
                .foregroundStyle(ConsensusTheme.Colors.textTertiary)
        }
    }
}
