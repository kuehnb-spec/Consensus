import Foundation

// Typed provenance for `provenance.engines[]` in the CLI's transcript JSON.
// Replaces the 2.0 Mirror-reflection dump, which emitted the Swift property
// names ("primaryEngine", "diarizer", "language") as engine names and stamped
// the app version on every one of them.

extension ConsensusCLI {

    struct EngineDescriptor: Sendable {
        enum Role: String, Sendable {
            /// Wrote the transcript's words.
            case asr
            /// Assigned the speaker labels.
            case diarization
            /// Produced the word times (`"interpolation"` when nothing measured them).
            case alignment
            /// Independent second engine whose disagreements become `disputes[]`.
            case witness
        }

        let role: Role
        /// Stable short id; set for witnesses (`"parakeet"`), which disputes cite.
        var id: String? = nil
        let name: String
        let model: String?
        /// The engine's own runtime/package version, or nil when unknown.
        let version: String?

        var json: [String: Any] {
            var payload: [String: Any] = [
                "role": role.rawValue,
                "name": name,
                "model": model ?? NSNull(),
                "version": version ?? NSNull(),
            ]
            if let id { payload["id"] = id }
            return payload
        }
    }

    /// The engines the VibeVoice standard pass really used: one model does ASR
    /// and diarization jointly, and nothing measures word times.
    static func vibeVoiceEngines(config: ConsensusConfig) -> [EngineDescriptor] {
        let model = config.paths.model.map { "VibeVoice-ASR 4-bit MLX (\($0.lastPathComponent))" }
            ?? "VibeVoice-ASR 4-bit MLX"
        let runtime = mlxAudioVersion(python: config.paths.python).map { "mlx-audio \($0)" }
        return [
            EngineDescriptor(role: .asr, name: "VibeVoice-ASR", model: model, version: runtime),
            EngineDescriptor(role: .diarization, name: "VibeVoice-ASR (joint, in-model)", model: model, version: runtime),
            EngineDescriptor(role: .alignment, name: "interpolation", model: nil,
                             version: "consensus \(ConsensusVersion.app)"),
        ]
    }

    /// Reads the installed mlx-audio version from the sidecar venv's
    /// `site-packages/mlx_audio-<version>.dist-info` directory name. No Python
    /// launch, so it costs nothing on the transcribe path.
    static func mlxAudioVersion(python: URL?) -> String? {
        guard let python else { return nil }
        let venv = python.deletingLastPathComponent().deletingLastPathComponent()
        let lib = venv.appendingPathComponent("lib")
        let fm = FileManager.default
        guard let pythons = try? fm.contentsOfDirectory(atPath: lib.path) else { return nil }
        for dir in pythons where dir.hasPrefix("python") {
            let site = lib.appendingPathComponent(dir).appendingPathComponent("site-packages")
            guard let entries = try? fm.contentsOfDirectory(atPath: site.path) else { continue }
            for entry in entries where entry.hasPrefix("mlx_audio-") && entry.hasSuffix(".dist-info") {
                return String(entry.dropFirst("mlx_audio-".count).dropLast(".dist-info".count))
            }
        }
        return nil
    }
}
