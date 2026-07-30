import Foundation

/// The three user-facing modes for the rewritten UI. All three share the same
/// nine-stage pipeline; the mode only governs how many stages are interactive
/// versus automatic, and how much of the control surface is exposed.
///
/// See `Brainstorming/2026-04-21 - Consensus Rewrite Plan.md` for the source
/// of truth on mode behaviour.
enum ModeState: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    /// Drop-and-get-out. Zero configuration; pipeline tier is picked
    /// automatically from audio length; summary/todos off by default.
    case quickTake

    /// The central flow. Exposes Speed (Quick / Deep) and Include (Summary,
    /// To-dos) toggles on a compact setup card; everything else runs
    /// automatically with the interactive uncertainty review at the end.
    case deepRead

    /// Every knob. Explicit tier picker, engine controls, domain hint,
    /// advanced summary options, voice library manager, pipeline inspector,
    /// and the manual editor on demand.
    case studio

    var id: String { rawValue }

    /// The default mode for a new install. Deep Read is the shared core flow
    /// that Quick Take trims from and Studio extends — starting there gives
    /// a new user the representative experience.
    static let `default`: ModeState = .deepRead

    var displayName: String {
        switch self {
        case .quickTake: return "Quick Take"
        case .deepRead:  return "Deep Read"
        case .studio:    return "Studio"
        }
    }

    /// One-line pitch, used on the mode picker in the new UI.
    var tagline: String {
        switch self {
        case .quickTake: return "Drop audio. Get a clean transcript."
        case .deepRead:  return "Deep accuracy with a guided review."
        case .studio:    return "Every knob, exposed."
        }
    }

    /// SF Symbol name suitable for the mode picker.
    var iconSystemName: String {
        switch self {
        case .quickTake: return "bolt.fill"
        case .deepRead:  return "book.closed.fill"
        case .studio:    return "slider.horizontal.3"
        }
    }
}
