import Foundation
import WhisperKit

/// Native WhisperKit transcriber — runs Whisper on Apple Neural Engine via Core ML.
/// Actor isolation prevents data races on the WhisperKit instance and model state.
actor WhisperKitTranscriber: Transcriber {

    // MARK: - Configuration

    private var modelName: String
    private let idleTimeout: TimeInterval
    private var whisperKit: WhisperKit?
    private var idleTask: Task<Void, Never>?
    private var _isModelLoaded = false

    /// Notification posted with download progress (0.0–1.0) as the object.
    static let downloadProgressNotification = Notification.Name("WhisperKitDownloadProgress")
    /// Notification posted when download completes.
    static let downloadCompleteNotification = Notification.Name("WhisperKitDownloadComplete")

    // MARK: - Known models

    struct ModelInfo {
        let name: String
        let displayName: String
        let size: String
        let description: String
    }

    /// Model names must match exact directory names in argmaxinc/whisperkit-coreml HF repo.
    /// WhisperKit uses these as glob patterns — underscore before "turbo" is critical.
    static let availableModelList: [ModelInfo] = [
        ModelInfo(name: "openai_whisper-large-v3_turbo", displayName: "Large V3 Turbo", size: "~1.6 GB", description: "Fast, near-best quality (Recommended)"),
        ModelInfo(name: "openai_whisper-large-v3", displayName: "Large V3", size: "~3 GB", description: "Highest quality, slower"),
        ModelInfo(name: "openai_whisper-base.en", displayName: "Base (English)", size: "~140 MB", description: "Very fast, good enough for clear speech"),
    ]

    /// Migrates old short model names to full HF repo directory names.
    nonisolated static func migrateModelName(_ name: String) -> String {
        switch name {
        case "large-v3-turbo": return "openai_whisper-large-v3_turbo"
        case "large-v3": return "openai_whisper-large-v3"
        case "base.en": return "openai_whisper-base.en"
        case "base": return "openai_whisper-base"
        default: return name
        }
    }

    // MARK: - Hallucination filter

    private static let hallucinationPhrases: Set<String> = [
        "you're going to be",
        "you're going to",
        "you're",
        "thank you",
        "thanks for watching",
        "thank you for watching",
        "please subscribe",
        "like and subscribe",
        "the end",
        "bye",
        "goodbye",
        "subtitles by",
        "translated by",
        "amara.org",
        "www.mooji.org",
        "moffatts",
        "i'm going to",
    ]

    private static let silenceRMSThreshold: Float = 0.005

    // MARK: - Init

    init(modelName: String = "openai_whisper-large-v3_turbo", idleTimeout: Int = 3600) {
        self.modelName = Self.migrateModelName(modelName)
        self.idleTimeout = TimeInterval(max(60, min(idleTimeout, 86400)))
    }

    // MARK: - Transcriber protocol

    var isModelLoaded: Bool {
        _isModelLoaded
    }

    func preload() async throws {
        if whisperKit != nil { return }
        try await initWhisperKit()
    }

    func transcribe(audioData: Data, sampleRate: Double) async throws -> String {
        // Validate audio data length (Int16 = 2 bytes per sample)
        guard audioData.count >= 2, audioData.count % 2 == 0 else {
            AppLogger.shared.warn("Invalid audio data length: \(audioData.count)")
            return ""
        }

        // Convert Int16 PCM → Float array
        let floatSamples = convertPCMToFloat(audioData)

        // RMS silence check
        let rms = computeRMS(floatSamples)
        if rms < Self.silenceRMSThreshold {
            AppLogger.shared.info("Skipping transcription: audio too quiet (RMS=\(String(format: "%.6f", rms)))")
            return ""
        }

        // Resample to 16kHz if needed
        let samples: [Float]
        if abs(sampleRate - 16000.0) > 1.0 {
            samples = resample(floatSamples, from: sampleRate, to: 16000.0)
        } else {
            samples = floatSamples
        }

        // Lazy init WhisperKit
        if whisperKit == nil {
            try await initWhisperKit()
        }

        guard let kit = whisperKit else {
            throw TranscriberError.modelNotLoaded
        }

        // Transcribe — WhisperKit runs on Neural Engine, typically fast.
        // The single-array overload returns [TranscriptionResult].
        let results: [TranscriptionResult] = try await kit.transcribe(audioArray: samples)

        let text = results
            .compactMap { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Hallucination filter
        if isHallucination(text) {
            AppLogger.shared.info("Filtered hallucination: \"\(text)\"")
            return ""
        }

        resetIdleTimer()
        return text
    }

    // MARK: - Model management

    func switchModel(_ newModelName: String) async throws {
        // Validate model name: only allow safe characters
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._/"))
        guard newModelName.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw TranscriberError.invalidModelName
        }

        idleTask?.cancel()
        whisperKit = nil
        _isModelLoaded = false
        modelName = Self.migrateModelName(newModelName)
        try await initWhisperKit()
    }

    func unloadModel() {
        idleTask?.cancel()
        whisperKit = nil
        _isModelLoaded = false
        AppLogger.shared.info("WhisperKit model unloaded (idle)")
    }

    /// WhisperKit downloads models via HuggingFace Hub to ~/Documents/huggingface/models/...
    /// The repo structure is: models/argmaxinc/whisperkit-coreml/<variant>/
    nonisolated static func modelCacheDirectories() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var dirs: [URL] = []
        // Primary: HuggingFace Hub default download location
        let hfDir = home
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("huggingface", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
        dirs.append(hfDir)
        // Fallback: old cache location (in case WhisperKit changes behavior)
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        dirs.append(caches.appendingPathComponent("com.argmaxinc.WhisperKit", isDirectory: true))
        return dirs
    }

    /// Checks if a directory name matches a model name.
    /// Handles both full names (openai_whisper-large-v3_turbo) and legacy short names (large-v3-turbo).
    private nonisolated static func matchesModel(_ dirName: String, _ modelName: String) -> Bool {
        // Direct match (full HF directory name)
        if dirName == modelName { return true }
        // Prefix match (handles size suffixes like _954MB)
        if dirName.hasPrefix(modelName) { return true }
        // Legacy short name support: prepend openai_whisper- prefix
        let migrated = migrateModelName(modelName)
        if dirName == migrated { return true }
        if dirName.hasPrefix(migrated) { return true }
        // Also try with openai_whisper- prefix directly
        if dirName == "openai_whisper-\(modelName)" { return true }
        if dirName.hasPrefix("openai_whisper-\(modelName)") { return true }
        return false
    }

    nonisolated static func isModelCached(_ modelName: String) -> Bool {
        for cacheDir in modelCacheDirectories() {
            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: cacheDir.path) else { continue }
            for entry in contents {
                if matchesModel(entry, modelName) {
                    let fullPath = cacheDir.appendingPathComponent(entry, isDirectory: true)
                    // Verify it has actual model files inside (not just an empty dir)
                    if let files = try? FileManager.default.contentsOfDirectory(atPath: fullPath.path),
                       files.contains(where: { $0.hasSuffix(".mlmodelc") || $0.hasSuffix(".mlpackage") }) {
                        return true
                    }
                }
            }
        }
        return false
    }

    nonisolated static func cachedModels() -> [String] {
        var found: Set<String> = []
        for cacheDir in modelCacheDirectories() {
            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: cacheDir.path) else { continue }
            for entry in contents where entry.hasPrefix("openai_whisper-") {
                let entryPath = cacheDir.appendingPathComponent(entry, isDirectory: true)
                // Verify it has model files
                guard let files = try? FileManager.default.contentsOfDirectory(atPath: entryPath.path),
                      files.contains(where: { $0.hasSuffix(".mlmodelc") || $0.hasSuffix(".mlpackage") }) else { continue }
                // Map back to our short model names
                for model in availableModelList {
                    if matchesModel(entry, model.name) {
                        found.insert(model.name)
                    }
                }
            }
        }
        return Array(found)
    }

    nonisolated static func deleteModel(_ modelName: String) throws {
        for cacheDir in modelCacheDirectories() {
            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: cacheDir.path) else { continue }
            for entry in contents where matchesModel(entry, modelName) {
                let modelDir = cacheDir.appendingPathComponent(entry, isDirectory: true)
                try FileManager.default.removeItem(at: modelDir)
            }
        }
    }

    // MARK: - Private helpers

    private func initWhisperKit() async throws {
        AppLogger.shared.info("Initializing WhisperKit with model: \(modelName)")

        do {
            // WhisperKit resolves model names against argmaxinc/whisperkit-coreml repo.
            // Use verbose=true during init so download/load issues appear in console.
            let config = WhisperKitConfig(
                model: modelName,
                verbose: true,
                prewarm: true,
                load: true,
                download: true
            )
            let kit = try await WhisperKit(config)
            self.whisperKit = kit
            self._isModelLoaded = true

            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.downloadCompleteNotification, object: nil)
            }

            AppLogger.shared.info("WhisperKit model loaded: \(modelName)")
            resetIdleTimer()
        } catch {
            AppLogger.shared.error("WhisperKit init failed for model '\(modelName)': \(error)")
            throw error
        }
    }

    private func resetIdleTimer() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(self?.idleTimeout ?? 3600) * 1_000_000_000)
                await self?.unloadModel()
            } catch {
                // Task cancelled — that's fine
            }
        }
    }

    private func convertPCMToFloat(_ data: Data) -> [Float] {
        let sampleCount = data.count / 2
        return data.withUnsafeBytes { buffer -> [Float] in
            let int16Buffer = buffer.bindMemory(to: Int16.self)
            var floats = [Float](repeating: 0, count: sampleCount)
            for i in 0..<sampleCount {
                floats[i] = Float(int16Buffer[i]) / 32768.0
            }
            return floats
        }
    }

    private func computeRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0.0 }
        var sumSquares: Float = 0.0
        for s in samples {
            sumSquares += s * s
        }
        return sqrtf(sumSquares / Float(samples.count))
    }

    private func resample(_ samples: [Float], from sourceSR: Double, to targetSR: Double) -> [Float] {
        let ratio = targetSR / sourceSR
        let newLength = Int(Double(samples.count) * ratio)
        guard newLength > 0 else { return [] }
        var result = [Float](repeating: 0, count: newLength)
        for i in 0..<newLength {
            let srcIndex = Double(i) / ratio
            let low = Int(srcIndex)
            let high = min(low + 1, samples.count - 1)
            let frac = Float(srcIndex - Double(low))
            result[i] = samples[low] * (1.0 - frac) + samples[high] * frac
        }
        return result
    }

    private func isHallucination(_ text: String) -> Bool {
        if text.isEmpty { return true }

        let cleaned = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?,"))
            .lowercased()

        if Self.hallucinationPhrases.contains(cleaned) {
            return true
        }

        // Detect repeated segments: "Hello. Hello. Hello."
        let segments = cleaned
            .components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        if segments.count >= 2 {
            let unique = Set(segments)
            if unique.count == 1 { return true }

            if segments.count >= 3 {
                var counts: [String: Int] = [:]
                for seg in segments { counts[seg, default: 0] += 1 }
                let maxCount = counts.values.max() ?? 0
                if Double(maxCount) / Double(segments.count) >= 0.7 {
                    return true
                }
            }
        }

        return false
    }
}

// MARK: - Errors

enum TranscriberError: LocalizedError {
    case modelNotLoaded
    case timeout
    case invalidModelName

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Transcription model not loaded. Try again in a moment."
        case .timeout:
            return "Transcription timed out (30s). The model may be overloaded."
        case .invalidModelName:
            return "Invalid model name. Only alphanumeric characters, hyphens, dots, and slashes are allowed."
        }
    }
}
