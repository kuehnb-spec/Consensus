import ConsensusCore

/// The GUI executable is only a launcher: the SwiftUI scene and everything it
/// touches live in ConsensusCore, so the headless `consensus` CLI can share the
/// same core without ever starting an AppKit lifecycle.
@main
struct ConsensusAppLauncher {
    static func main() {
        ConsensusCore.ConsensusApp.main()
    }
}
