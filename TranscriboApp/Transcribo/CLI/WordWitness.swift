import Foundation

// `consensus transcribe --witness ID`: a second, independent ASR engine
// transcribes the same audio, and every place its words disagree with the
// primary's becomes a dispute in the JSON. Measured on the Proving Ground
// (2026-10-29): with Parakeet as witness, 59% of VibeVoice's word errors fall
// inside a dispute at a ~6% flag rate; Nemotron 3.5 reaches 65% but needs
// 18 GB of GPU. The witness never edits the transcript: disputes are where a
// human (or a later tie-breaker) should look, nothing more.
//
// Adding a witness (e.g. `nemotron35`) means one more `WitnessEngine` case and
// one `WordWitnessProvider`; the alignment step and the `disputes[]` schema
// are shared and do not change.

extension ConsensusCLI {

    /// One word as the witness heard it, with the witness's own timing.
    struct WitnessWord: Sendable, Encodable {
        let word: String
        let start: Double
        let end: Double
    }

    protocol WordWitnessProvider: Sendable {
        var descriptor: EngineDescriptor { get }
        func words(for audioURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [WitnessWord]
    }

    enum WitnessEngine: String, CaseIterable, Sendable {
        case parakeet
        // case nemotron35  — future: MLX sidecar, untimed words hung on the
        // primary's clock (Scripts/proving-ground/align_untimed_words.py).

        func makeProvider(config: ConsensusConfig) -> WordWitnessProvider {
            switch self {
            case .parakeet:
                // fable/fluidaudio-0.17 trial: the vendored copy is 0.17.1, so
                // in process is the default; the external CLI only on request.
                if ProcessInfo.processInfo.environment["CONSENSUS_WITNESS_EXTERNAL"] == "1",
                   let cli = config.paths.fluidAudioCLI { return ParakeetCLIWitness(binary: cli) }
                return ParakeetWitness()
            }
        }
    }

    /// Parakeet TDT v3 through the vendored FluidAudio, in process (CoreML/ANE).
    struct ParakeetWitness: WordWitnessProvider {
        let variant: FluidAsrModelVariant = .parakeetV3

        var descriptor: EngineDescriptor {
            EngineDescriptor(
                role: .witness,
                id: WitnessEngine.parakeet.rawValue,
                name: "Parakeet TDT",
                model: "parakeet-tdt-0.6b-v3 (CoreML)",
                version: "FluidAudio \(ConsensusVersion.fluidAudio)"
            )
        }

        func words(for audioURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [WitnessWord] {
            let service = FluidAsrTranscriptionService()
            let segments = try await service.transcribe(audioURL: audioURL, variant: variant, progressCallback: progress)
            return segments.flatMap { segment -> [WitnessWord] in
                if let words = segment.words, !words.isEmpty {
                    return words.map { WitnessWord(word: $0.word, start: Double($0.start), end: Double($0.end)) }
                }
                // No token timings: keep the words, spread over the segment.
                let tokens = segment.text.split(whereSeparator: \.isWhitespace).map(String.init)
                let step = (segment.end - segment.start) / Double(max(1, tokens.count))
                return tokens.enumerated().map { i, token in
                    WitnessWord(word: token, start: segment.start + Double(i) * step,
                                end: segment.start + Double(i + 1) * step)
                }
            }
        }
    }

    /// Parakeet TDT v3 through an external `fluidaudiocli` (>= 0.17), the
    /// build the Proving Ground measured. Used in preference to the vendored
    /// 0.12.2, which on 2026-11-11 dropped ~11% of a 10-minute clip's words
    /// in long runs and took 160 s against 5 s; retire this path once the
    /// vendored FluidAudio is upgraded to 0.17.1.
    struct ParakeetCLIWitness: WordWitnessProvider {
        let binary: URL

        var descriptor: EngineDescriptor {
            EngineDescriptor(
                role: .witness,
                id: WitnessEngine.parakeet.rawValue,
                name: "Parakeet TDT",
                model: "parakeet-tdt-0.6b-v3 (CoreML)",
                version: "fluidaudiocli (external; version not reported)"
            )
        }

        func words(for audioURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [WitnessWord] {
            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent("consensus-witness-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: out) }
            let process = Process()
            process.executableURL = binary
            process.arguments = ["transcribe", audioURL.path, "--word-timestamps", "--output-json", out.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            progress(0.05)
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0, let data = try? Data(contentsOf: out) else {
                throw WitnessError.alignerFailed("fluidaudiocli exited \(process.terminationStatus)")
            }
            struct Raw: Decodable {
                struct Word: Decodable { let word: String; let startTime: Double; let endTime: Double }
                let wordTimings: [Word]?
            }
            let raw = try JSONDecoder().decode(Raw.self, from: data)
            progress(1.0)
            return (raw.wordTimings ?? []).map { WitnessWord(word: $0.word, start: $0.startTime, end: $0.endTime) }
        }
    }

    struct Dispute: Sendable, Decodable {
        let segment: Int
        let wordStart: Int
        let wordEnd: Int
        let primary: String
        let witness: String
        let witnessID: String
        let kind: String
        let witnessStart: Double?
        let witnessEnd: Double?

        enum CodingKeys: String, CodingKey {
            case segment, primary, witness, kind
            case wordStart = "word_start"
            case wordEnd = "word_end"
            case witnessID = "witness_id"
            case witnessStart = "witness_start"
            case witnessEnd = "witness_end"
        }

        var json: [String: Any] {
            [
                "segment": segment,
                "word_start": wordStart,
                "word_end": wordEnd,
                "primary": primary,
                "witness": witness,
                "witness_id": witnessID,
                "kind": kind,
                "witness_start": witnessStart ?? NSNull(),
                "witness_end": witnessEnd ?? NSNull(),
            ]
        }
    }

    struct WitnessReport: Sendable {
        let descriptor: EngineDescriptor
        let disputes: [Dispute]
        let normalization: String
        let primaryTokens: Int
        let witnessTokens: Int
        let disputedTokens: Int
        let seconds: Double
    }

    enum WitnessError: LocalizedError {
        case alignerMissing
        case alignerFailed(String)

        var errorDescription: String? {
            switch self {
            case .alignerMissing:
                return "word-witness aligner not found — run `consensus doctor`"
            case .alignerFailed(let detail):
                return "word-witness alignment failed: \(detail)"
            }
        }
    }

    /// Runs the witness engine, then the alignment step (the Proving Ground's
    /// normaliser and edit-distance alignment, shipped as witness_align.py and
    /// run with the Consensus Python), and returns the disputes.
    static func runWitness(
        _ engine: WitnessEngine,
        audioURL: URL,
        pass: TranscriptPass,
        config: ConsensusConfig,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> WitnessReport {
        let started = Date()
        guard let python = config.paths.python, let aligner = config.paths.witnessAligner else {
            throw WitnessError.alignerMissing
        }
        let provider = engine.makeProvider(config: config)
        let witnessWords = try await provider.words(for: audioURL, progress: progress)

        let primary: [[String]] = pass.segments.map { segment in
            if let words = segment.words, !words.isEmpty { return words.map(\.word) }
            return segment.text.split(whereSeparator: \.isWhitespace).map(String.init)
        }
        struct Request: Encodable {
            let witness_id: String
            let primary: [[String]]
            let witness: [WitnessWord]
        }
        let input = try JSONEncoder().encode(Request(witness_id: engine.rawValue, primary: primary, witness: witnessWords))
        let output = try runPython(python, script: aligner, stdin: input)

        struct Response: Decodable {
            struct Stats: Decodable {
                let normalization: String
                let primary_tokens: Int
                let witness_tokens: Int
                let disputed_tokens: Int
            }
            let disputes: [Dispute]
            let stats: Stats
        }
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: output)
        } catch {
            throw WitnessError.alignerFailed("unreadable aligner output (\(error.localizedDescription))")
        }
        return WitnessReport(
            descriptor: provider.descriptor,
            disputes: response.disputes,
            normalization: response.stats.normalization,
            primaryTokens: response.stats.primary_tokens,
            witnessTokens: response.stats.witness_tokens,
            disputedTokens: response.stats.disputed_tokens,
            seconds: Date().timeIntervalSince(started)
        )
    }

    /// stdin → script → stdout. stderr is kept only for the error message;
    /// the aligner never writes transcript text there.
    private static func runPython(_ python: URL, script: URL, stdin: Data) throws -> Data {
        let process = Process()
        process.executableURL = python
        process.arguments = ["-I", script.path]
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()

        // Read both streams concurrently so a large reply can't deadlock.
        let collected = OutputBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            collected.out = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            collected.err = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        inPipe.fileHandleForWriting.write(stdin)
        try? inPipe.fileHandleForWriting.close()
        group.wait()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let tail = String(decoding: collected.err.suffix(400), as: UTF8.self)
            throw WitnessError.alignerFailed("exit \(process.terminationStatus): \(tail)")
        }
        return collected.out
    }

    private final class OutputBox: @unchecked Sendable {
        var out = Data()
        var err = Data()
    }
}
