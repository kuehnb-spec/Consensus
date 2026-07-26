import ConsensusCore
import Foundation

/// Thin launcher. All CLI logic lives in ConsensusCore so it can reach the
/// pipeline's internal API, and so this target never links an AppKit
/// lifecycle — the binary is safe to run from launchd with no GUI session.
@main
struct ConsensusCommandLineLauncher {
    static func main() async {
        exit(await ConsensusCLI.main())
    }
}
