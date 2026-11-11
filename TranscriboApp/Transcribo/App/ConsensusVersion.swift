import Foundation

/// The one place the Consensus version lives. The CLI, its JSON provenance,
/// `--version`, `doctor` and the packaging scripts (which grep the
/// `app = "…"` line below) all read it from here.
public enum ConsensusVersion {
    public static let app = "2.1.1"
    /// CLI transcript JSON schema (10-consensus-spec.md, CLI.md).
    public static let transcriptSchema = "2.1"
    /// Vendored FluidAudio (TranscriboApp/Vendor/FluidAudio) that runs Parakeet.
    public static let fluidAudio = "0.17.1"
}
