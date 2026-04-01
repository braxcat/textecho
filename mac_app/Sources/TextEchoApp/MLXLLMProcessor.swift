import Foundation
import MLXLLM
import MLXLMCommon

/// LLM processing modes — determines the system prompt used.
enum LLMMode: String, CaseIterable, Codable {
    case grammar = "grammar"
    case rephrase = "rephrase"
    case answer = "answer"
    case custom = "custom"

    var displayName: String {
        switch self {
        case .grammar: return "Grammar Fix"
        case .rephrase: return "Rephrase"
        case .answer: return "Answer"
        case .custom: return "Custom"
        }
    }

    var systemPrompt: String {
        switch self {
        case .grammar:
            return "Fix grammar, spelling, and punctuation in the following text. Keep the original meaning. Output only the corrected text, nothing else."
        case .rephrase:
            return "Rephrase the following text to be clear and professional. Keep the original meaning. Output only the rephrased text, nothing else."
        case .answer:
            return "Answer the following question concisely and accurately. Output only the answer, nothing else."
        case .custom:
            return "" // User provides their own
        }
    }
}

/// Known LLM models that work well on Apple Silicon via MLX.
struct LLMModelInfo {
    let id: String          // HuggingFace model ID
    let displayName: String
    let description: String
    let sizeGB: Double      // Approximate download size
}

/// Curated list of recommended models — all from mlx-community with 4-bit quantization.
let recommendedLLMModels: [LLMModelInfo] = [
    LLMModelInfo(id: "mlx-community/Qwen3.5-9B-4bit", displayName: "Qwen 3.5 9B",
                 description: "Best overall — strong reasoning, 25 languages (Recommended for 36GB+ Macs)",
                 sizeGB: 6.6),
    LLMModelInfo(id: "mlx-community/gemma-3-12b-it-4bit", displayName: "Gemma 3 12B",
                 description: "Google's best small model — multilingual, strong instruction following",
                 sizeGB: 8.0),
    LLMModelInfo(id: "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit", displayName: "Qwen 2.5 Coder 7B",
                 description: "Best for code — generation, review, debugging",
                 sizeGB: 5.0),
    LLMModelInfo(id: "mlx-community/Llama-3.3-8B-Instruct-4bit", displayName: "Llama 3.3 8B",
                 description: "Well-rounded — good balance of speed and quality",
                 sizeGB: 5.0),
    LLMModelInfo(id: "mlx-community/Qwen3.5-4B-4bit", displayName: "Qwen 3.5 4B",
                 description: "Fast and light — good for grammar fixes (8GB+ Macs)",
                 sizeGB: 3.0),
    LLMModelInfo(id: "mlx-community/gemma-3-4b-it-4bit", displayName: "Gemma 3 4B",
                 description: "Google's lightweight model — fast, good for grammar (8GB+ Macs)",
                 sizeGB: 3.0),
]

/// Native LLM processor using Apple's MLX framework.
/// Runs on GPU via unified memory — separate from Parakeet (Neural Engine).
actor MLXLLMProcessor {

    private var modelContainer: ModelContainer?
    private var currentModelID: String?
    private var _isLoaded = false

    var isLoaded: Bool { _isLoaded }

    /// Validates a model ID is from a trusted source.
    private static func isModelIDTrusted(_ id: String) -> Bool {
        let trustedPrefixes = ["mlx-community/"]
        return trustedPrefixes.contains(where: { id.hasPrefix($0) })
    }

    /// Load a model from HuggingFace (downloads on first use, cached after).
    func loadModel(id: String) async throws {
        if currentModelID == id && _isLoaded { return }

        if !Self.isModelIDTrusted(id) {
            AppLogger.shared.warn("LLM model ID '\(id)' is not from a trusted source (mlx-community/). Proceeding with caution.")
        }

        AppLogger.shared.info("Loading LLM model: \(id)")
        let config = ModelConfiguration(id: id)
        modelContainer = try await LLMModelFactory.shared.loadContainer(configuration: config)
        currentModelID = id
        _isLoaded = true
        AppLogger.shared.info("LLM model loaded: \(id)")
    }

    /// Generate a response from the LLM.
    /// - Parameters:
    ///   - prompt: The user's transcribed text
    ///   - systemPrompt: Instructions for the LLM (grammar fix, rephrase, answer, etc.)
    ///   - context: Additional context from registers (Cmd+Opt+1-9)
    ///   - onToken: Optional callback for streaming tokens to the UI
    func generate(
        prompt: String,
        systemPrompt: String,
        context: String = "",
        onToken: ((String) -> Void)? = nil
    ) async throws -> String {
        guard let container = modelContainer else {
            throw LLMError.modelNotLoaded
        }

        let fullPrompt = buildPrompt(system: systemPrompt, context: context, user: prompt)
        let input = UserInput(prompt: fullPrompt)
        let parameters = GenerateParameters(temperature: 0.7, maxTokens: 2048)

        var fullResponse = ""

        let _ = try await container.perform { [input, parameters] context in
            let prepared = try await context.processor.prepare(input: input)
            return try MLXLMCommon.generate(
                input: prepared,
                parameters: parameters,
                context: context
            ) { tokens in
                let decoded = context.tokenizer.decode(tokens: tokens)
                fullResponse = decoded
                onToken?(decoded)
                return .more
            }
        }

        let trimmed = fullResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        AppLogger.shared.info("LLM response (\(trimmed.count) chars)")
        return trimmed
    }

    /// Unload the model to free GPU memory.
    func unload() {
        modelContainer = nil
        currentModelID = nil
        _isLoaded = false
        AppLogger.shared.info("LLM model unloaded")
    }

    // MARK: - Private

    private func buildPrompt(system: String, context: String, user: String) -> String {
        var parts: [String] = []

        if !system.isEmpty {
            parts.append("System: \(system)")
        }

        if !context.isEmpty {
            parts.append("Context:\n\(context)")
        }

        parts.append("User: \(user)")

        return parts.joined(separator: "\n\n")
    }
}

// MARK: - Errors

enum LLMError: LocalizedError {
    case modelNotLoaded
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "LLM model not loaded. Enable LLM in Settings and select a model."
        case .generationFailed(let detail):
            return "LLM generation failed: \(detail)"
        }
    }
}
