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
        let description: String
    }

    /// Model names must match exact directory names in argmaxinc/whisperkit-coreml HF repo.
    /// WhisperKit uses these as glob patterns — underscore before "turbo" is critical.
    static let availableModelList: [ModelInfo] = [
        ModelInfo(name: "openai_whisper-large-v3_turbo", displayName: "Large V3 Turbo", description: "Fast, near-best quality (Recommended)"),
        ModelInfo(name: "openai_whisper-large-v3", displayName: "Large V3", description: "Highest quality, slower"),
        ModelInfo(name: "openai_whisper-large-v3-v20240930", displayName: "Large V3 (Compressed)", description: "Compressed variant of Large V3 — similar quality, lower memory use. Better suited for M1 and older hardware."),
        ModelInfo(name: "openai_whisper-base.en", displayName: "Base (English)", description: "Very fast, good enough for clear speech"),
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

    init(modelName: String = "openai_whisper-large-v3_turbo", idleTimeout: Int = 0) {
        self.modelName = Self.migrateModelName(modelName)
        self.idleTimeout = idleTimeout == 0 ? 0 : TimeInterval(max(60, min(idleTimeout, 86400)))
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

    func unload() {
        idleTask?.cancel()
        whisperKit = nil
        _isModelLoaded = false
        AppLogger.shared.info("WhisperKit model unloaded")
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
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return dirs }
        dirs.append(caches.appendingPathComponent("com.argmaxinc.WhisperKit", isDirectory: true))
        return dirs
    }

    /// Checks if a directory name matches a model name.
    /// Handles both full names (openai_whisper-large-v3_turbo) and legacy short names (large-v3-turbo).
    private nonisolated static func matchesModel(_ dirName: String, _ modelName: String) -> Bool {
        // Direct match (full HF directory name)
        if dirName == modelName { return true }
        // Prefix match only for size suffixes like _954MB (suffix must be _<digit>...)
        // This prevents openai_whisper-large-v3_turbo from matching openai_whisper-large-v3
        if dirName.hasPrefix(modelName) {
            let suffix = dirName.dropFirst(modelName.count)
            if suffix.isEmpty || (suffix.hasPrefix("_") && suffix.dropFirst().first?.isNumber == true) {
                return true
            }
        }
        // Legacy short name support: prepend openai_whisper- prefix
        let migrated = migrateModelName(modelName)
        if dirName == migrated { return true }
        if migrated != modelName && dirName.hasPrefix(migrated) {
            let suffix = dirName.dropFirst(migrated.count)
            if suffix.isEmpty || (suffix.hasPrefix("_") && suffix.dropFirst().first?.isNumber == true) {
                return true
            }
        }
        // Also try with openai_whisper- prefix directly
        let prefixed = "openai_whisper-\(modelName)"
        if dirName == prefixed { return true }
        if dirName.hasPrefix(prefixed) {
            let suffix = dirName.dropFirst(prefixed.count)
            if suffix.isEmpty || (suffix.hasPrefix("_") && suffix.dropFirst().first?.isNumber == true) {
                return true
            }
        }
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

    /// Deep file validation: checks .mlmodelc dirs are present, non-empty, and no incomplete markers.
    /// More thorough than isModelCached — verifies the model files are intact and complete.
    nonisolated static func validateModelFiles(_ modelName: String) -> Bool {
        for cacheDir in modelCacheDirectories() {
            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: cacheDir.path) else { continue }
            for entry in contents where matchesModel(entry, modelName) {
                let modelDir = cacheDir.appendingPathComponent(entry)
                guard let files = try? FileManager.default.contentsOfDirectory(atPath: modelDir.path) else { continue }

                // Need AudioEncoder and MelSpectrogram at minimum
                let mlmodelcDirs = files.filter { $0.hasSuffix(".mlmodelc") }
                guard mlmodelcDirs.count >= 2 else { continue }

                // Each .mlmodelc dir must be non-empty (incomplete downloads leave empty dirs)
                var allNonEmpty = true
                for dir in mlmodelcDirs {
                    let innerPath = modelDir.appendingPathComponent(dir).path
                    let innerFiles = (try? FileManager.default.contentsOfDirectory(atPath: innerPath)) ?? []
                    if innerFiles.isEmpty {
                        allNonEmpty = false
                        break
                    }
                }
                guard allNonEmpty else { continue }

                // No partial download markers
                if files.contains(where: { $0.hasSuffix(".incomplete") || $0 == ".download_in_progress" }) {
                    continue
                }

                return true
            }
        }
        return false
    }

    /// Async wrapper for file validation — runs off main thread.
    nonisolated static func validateModel(_ modelName: String) async -> Bool {
        await Task.detached(priority: .utility) {
            Self.validateModelFiles(modelName)
        }.value
    }

    /// Returns the current device's Apple Silicon chip generation name (e.g. "M3").
    /// Used to show device-specific recommendation labels in the UI.
    nonisolated static func currentChipName() -> String {
        let device = WhisperKit.deviceName()
        if device.hasPrefix("Mac16") { return "M4" }
        if device.hasPrefix("Mac15") { return "M3" }
        if device.hasPrefix("Mac14") { return "M2" }
        if device.hasPrefix("Mac13") || device.hasPrefix("MacBookPro17") ||
           device.hasPrefix("MacBookPro18") || device.hasPrefix("MacBookAir10") ||
           device.hasPrefix("Macmini9") || device.hasPrefix("iMac21") { return "M1" }
        return "Apple Silicon"
    }

    /// Fetches the full list of available models from the WhisperKit HuggingFace repo (requires internet).
    nonisolated static func fetchAllAvailableModels() async throws -> [String] {
        try await WhisperKit.fetchAvailableModels()
    }

    /// Returns WhisperKit's device-specific model recommendations (local, no network).
    /// `.defaultModel` is WhisperKit's top pick for this device.
    /// `.supportedModels` is everything WhisperKit considers compatible.
    nonisolated static func deviceRecommendedModels() -> (defaultModel: String, supportedModels: [String]) {
        let support = WhisperKit.recommendedModels()
        return (defaultModel: support.default, supportedModels: support.supported)
    }

    nonisolated static func deleteModel(_ modelName: String) throws {
        guard !modelName.contains("..") && !modelName.contains("/") else {
            throw NSError(domain: "TextEcho", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid model name"])
        }
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
        guard idleTimeout > 0 else { return }  // 0 = never unload
        idleTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(self?.idleTimeout ?? 3600) * 1_000_000_000)
                await self?.unload()
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
