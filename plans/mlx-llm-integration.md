# TextEcho: Native LLM via MLX Swift

## Summary

Replace the Python llm_daemon.py with native Swift LLM inference via Apple's MLX framework. When the user holds Ctrl+Shift+D (or a configurable hotkey), their speech is transcribed, then processed by a local LLM before pasting. Use cases: grammar cleanup, rephrasing, answering questions, summarizing.

**Stack:** mlx-swift-lm (Apple's official Swift package for MLX LLM inference)

## Why MLX Swift

- **Pure Swift** — no Python dependency, no Unix socket, no daemon process
- **20-30% faster** than llama.cpp on Apple Silicon (uses unified memory + GPU natively)
- **Apple-maintained** — ml-explore/mlx-swift-lm, WWDC25 featured
- **SwiftPM** — same pattern as FluidAudio (add dependency, create actor)
- **HuggingFace integration** — download models directly from mlx-community

## Recommended Models for M4 Max 36GB

| Model | Size (Q4) | Tokens/s | Best for |
|---|---|---|---|
| **Qwen 3.5 9B** | 6.6GB | ~48 tok/s | Default — best overall reasoning |
| **Qwen 2.5 Coder 7B** | ~5GB | ~55 tok/s | Code-specific tasks |
| **Llama 3.3 8B** | ~5GB | ~50 tok/s | All-around balance |
| **Qwen 3.5 4B** | ~3GB | ~70 tok/s | Faster, lighter, good for grammar |

Users with smaller Macs (8-16GB) can use 4B models. 36GB+ can run 9B comfortably.

## Architecture

### New: `LLMProcessor` (actor)

```
TextEcho.app
├── Transcriber (Parakeet/Whisper) → raw text
├── LLMProcessor (MLX Swift) → refined text  [NEW]
│   ├── ModelContainer (thread-safe model access)
│   ├── System prompts (grammar, rephrase, answer, custom)
│   └── Model download/load/unload lifecycle
└── TextInjector → paste result
```

### Flow

1. User holds Ctrl+Shift+D → records audio
2. Parakeet transcribes → raw text
3. LLMProcessor receives raw text + system prompt + register context
4. MLX generates refined text (streaming to overlay)
5. Result pasted into active app

### System Prompts (Built-in)

| Mode | Prompt | Use case |
|---|---|---|
| **Grammar** | "Fix grammar and punctuation. Keep meaning. Output only the corrected text." | Clean up dictated text |
| **Rephrase** | "Rephrase professionally. Keep meaning. Output only the rephrased text." | Make text more polished |
| **Answer** | "Answer the following question concisely." | Ask a question, get answer pasted |
| **Custom** | User-defined in Settings | Anything |

## Implementation

### Phase 1: Core MLX LLM integration

**Package.swift** — Add mlx-swift-lm dependency:
```swift
.package(url: "https://github.com/ml-explore/mlx-swift-lm.git", from: "2.29.0"),
```

Target dependency: `"MLXLLM"`

**New file: `MLXLLMProcessor.swift`** — Actor wrapping ModelContainer:
```swift
import MLXLLM
import MLXLMCommon

actor MLXLLMProcessor {
    private var modelContainer: ModelContainer?
    private var isLoaded = false

    func loadModel(id: String) async throws {
        let config = ModelConfiguration.init(id: id)
        modelContainer = try await LLMModelFactory.shared.loadContainer(configuration: config)
        isLoaded = true
    }

    func generate(prompt: String, systemPrompt: String, context: String = "") async throws -> String {
        guard let container = modelContainer else { throw LLMError.modelNotLoaded }
        let fullPrompt = buildPrompt(system: systemPrompt, context: context, user: prompt)
        let input = UserInput(prompt: fullPrompt)
        let parameters = GenerateParameters(temperature: 0.7)
        var result = ""
        let _ = try await container.perform { context in
            let input = try await context.processor.prepare(input: input)
            return try MLXLMCommon.generate(
                input: input, parameters: parameters, context: context
            ) { tokens in
                let text = context.tokenizer.decode(tokens: tokens)
                result = text
                return .more
            }
        }
        return result
    }

    func unload() {
        modelContainer = nil
        isLoaded = false
    }
}
```

### Phase 2: Config + UI

**AppConfig additions:**
```swift
var llmEngine: String        // "mlx" or "none"
var llmModelID: String       // HuggingFace model ID (e.g. "mlx-community/Qwen3.5-9B-4bit")
var llmSystemPrompt: String  // Default system prompt
var llmMode: String          // "grammar", "rephrase", "answer", "custom"
```

**Settings UI:**
- LLM section with enable toggle
- Model picker (curated list of recommended models)
- System prompt mode picker (Grammar / Rephrase / Answer / Custom)
- Custom prompt text field

### Phase 3: Wire into AppState

- Replace `PythonServiceManager` + `LLMClient` + Unix socket with `MLXLLMProcessor`
- `handleLLM(text:)` calls `MLXLLMProcessor.generate()` instead of socket IPC
- Streaming output to overlay (show tokens as they generate)
- Register context passed as additional context to the LLM

### Phase 4: Remove Python LLM code

- Remove `llm_daemon.py`
- Remove `PythonServiceManager.swift` (or keep for future use)
- Remove `LLMClient.swift` Unix socket client
- Remove `UnixSocket.swift` (if only used by LLM)
- Remove `--with-llm` build flag (no longer needed)
- Clean up config fields: remove `pythonPath`, `daemonScriptsDir`, `llmSocket`, `llmModelPath`

## Files

| File | Action | What |
|---|---|---|
| `Package.swift` | Edit | Add mlx-swift-lm dependency |
| `MLXLLMProcessor.swift` | **New** | MLX Swift LLM actor |
| `AppConfig.swift` | Edit | Add LLM config fields, remove Python fields |
| `AppState.swift` | Edit | Replace Python LLM with MLX |
| `SettingsWindow.swift` | Edit | LLM settings UI |
| `llm_daemon.py` | Delete | No longer needed |
| `PythonServiceManager.swift` | Delete | No longer needed |
| `LLMClient.swift` | Delete | No longer needed |

## Model Download

MLX Swift handles model downloads from HuggingFace automatically via `LLMModelFactory.shared.loadContainer()`. Models cache at `~/.cache/huggingface/`. No custom download logic needed.

## Verification

1. Build with `./build_native_app.sh --clean`
2. Launch, go to Settings, enable LLM, select Qwen 3.5 9B
3. Hold Ctrl+Shift+D, speak a question, release
4. Verify: Parakeet transcribes → MLX processes → result pasted
5. Test grammar mode: dictate sloppy text, verify cleanup
6. Test with registers: save context with Cmd+Opt+1, then Ctrl+Shift+D uses it
