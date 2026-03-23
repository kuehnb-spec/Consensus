import Foundation

/// Local LLM models for transcript cleanup and summarization.
/// Tiered by RAM requirements — the app auto-selects the best model
/// that fits comfortably in the user's available memory.
///
/// Uses Llama and Qwen 3 models which are fully supported by the
/// current mlx-swift-lm version (Qwen 3.5 requires a newer release).
enum CleanupModel: String, CaseIterable, Identifiable, Sendable {
    case llama3_2_3B  = "llama3.2-3b"
    case qwen3_8B     = "qwen3-8b"
    case qwen3_4B     = "qwen3-4b"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .llama3_2_3B:  return "Llama 3.2 3B"
        case .qwen3_4B:     return "Qwen 3 4B"
        case .qwen3_8B:     return "Qwen 3 8B"
        }
    }

    var description: String {
        switch self {
        case .llama3_2_3B:  return "Fast, light cleanup"
        case .qwen3_4B:     return "Balanced quality and speed"
        case .qwen3_8B:     return "Highest quality"
        }
    }

    /// HuggingFace model ID for mlx-swift-lm
    var modelID: String {
        switch self {
        case .llama3_2_3B:  return "mlx-community/Llama-3.2-3B-Instruct-4bit"
        case .qwen3_4B:     return "mlx-community/Qwen3-4B-4bit"
        case .qwen3_8B:     return "mlx-community/Qwen3-8B-4bit"
        }
    }

    /// Approximate download size
    var approximateSize: String {
        switch self {
        case .llama3_2_3B:  return "~1.8 GB"
        case .qwen3_4B:     return "~2.5 GB"
        case .qwen3_8B:     return "~4.5 GB"
        }
    }

    /// Minimum system RAM needed (model + headroom for context + other models)
    var minimumRAMGB: Int {
        switch self {
        case .llama3_2_3B:  return 8
        case .qwen3_4B:     return 8
        case .qwen3_8B:     return 16
        }
    }

    /// Returns the best model that fits in the system's available RAM.
    static func recommended() -> CleanupModel {
        let systemRAMGB = systemMemoryGB()

        // Work backwards from largest to smallest
        for model in [CleanupModel.qwen3_8B, .qwen3_4B, .llama3_2_3B] {
            if systemRAMGB >= model.minimumRAMGB {
                return model
            }
        }

        return .llama3_2_3B
    }

    /// Returns all models that can run on this system.
    static func available() -> [CleanupModel] {
        let systemRAMGB = systemMemoryGB()
        return allCases.filter { $0.minimumRAMGB <= systemRAMGB }
    }

    private static func systemMemoryGB() -> Int {
        Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
    }
}
