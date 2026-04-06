import AVFoundation
import Foundation
import FluidAudio

/// Parakeet TDT transcriber — runs NVIDIA Parakeet on Apple Neural Engine via Core ML.
/// Uses FluidAudio SDK for model management and inference.
/// Actor isolation prevents data races on the AsrManager instance and model state.
actor ParakeetTranscriber: Transcriber, @preconcurrency StreamingTranscriber {

    // MARK: - Configuration

    private var modelVersion: AsrModelVersion
    private let idleTimeout: TimeInterval
    private var asrManager: AsrManager?
    private var idleTask: Task<Void, Never>?
    private var _isModelLoaded = false

    // MARK: - Streaming state

    private var streamingEngine: (any StreamingAsrEngine)?
    private var _isStreamingModelLoaded = false
    private var partialCallback: (@Sendable (String) -> Void)?

    /// Notification posted when download completes.
    static let downloadCompleteNotification = Notification.Name("ParakeetDownloadComplete")

    // MARK: - Known models

    struct ModelInfo {
        let version: AsrModelVersion
        let name: String
        let displayName: String
        let description: String
    }

    static let availableModelList: [ModelInfo] = [
        ModelInfo(version: .v2, name: "parakeet-tdt-v2", displayName: "Parakeet V2 (English, Recommended)", description: "Best choice if you only need English."),
        ModelInfo(version: .v3, name: "parakeet-tdt-v3", displayName: "Parakeet V3 (25 langs)", description: "Coverage for 25 European languages."),
    ]

    /// Maps config string to AsrModelVersion.
    nonisolated static func modelVersion(from name: String) -> AsrModelVersion {
        switch name {
        case "parakeet-tdt-v2": return .v2
        case "parakeet-tdt-v3": return .v3
        default: return .v2
        }
    }

    /// Maps AsrModelVersion to config string.
    nonisolated static func modelName(from version: AsrModelVersion) -> String {
        switch version {
        case .v2: return "parakeet-tdt-v2"
        case .v3: return "parakeet-tdt-v3"
        case .tdtCtc110m: return "parakeet-tdt-ctc-110m"
        @unknown default: return "parakeet-tdt-v2"
        }
    }

    // MARK: - Init

    init(modelVersion: AsrModelVersion = .v3, idleTimeout: Int = 0) {
        self.modelVersion = modelVersion
        self.idleTimeout = idleTimeout == 0 ? 0 : TimeInterval(max(60, min(idleTimeout, 86400)))
    }

    init(modelName: String, idleTimeout: Int) {
        self.modelVersion = Self.modelVersion(from: modelName)
        self.idleTimeout = idleTimeout == 0 ? 0 : TimeInterval(max(60, min(idleTimeout, 86400)))
    }

    // MARK: - Transcriber protocol

    var isModelLoaded: Bool {
        _isModelLoaded
    }

    func preload() async throws {
        if asrManager != nil { return }
        try await initParakeet()
    }

    func transcribe(audioData: Data, sampleRate: Double) async throws -> String {
        // Validate audio data length (Int16 = 2 bytes per sample)
        guard audioData.count >= 2, audioData.count % 2 == 0 else {
            AppLogger.shared.warn("Invalid audio data length: \(audioData.count)")
            return ""
        }

        // Convert Int16 PCM → Float array
        let floatSamples = convertPCMToFloat(audioData)

        // Resample to 16kHz if needed (FluidAudio expects 16kHz)
        let samples: [Float]
        if abs(sampleRate - 16000.0) > 1.0 {
            samples = resample(floatSamples, from: sampleRate, to: 16000.0)
        } else {
            samples = floatSamples
        }

        // Lazy init
        if asrManager == nil {
            try await initParakeet()
        }

        guard let asr = asrManager else {
            throw TranscriberError.modelNotLoaded
        }

        // Transcribe — FluidAudio runs on Neural Engine via Core ML
        let result = try await asr.transcribe(samples, source: .microphone)

        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

        if text.isEmpty {
            return ""
        }

        AppLogger.shared.info("Parakeet transcription (confidence=\(String(format: "%.2f", result.confidence)), rtfx=\(String(format: "%.1f", result.rtfx))): \(text)")

        resetIdleTimer()
        return text
    }

    // MARK: - Model management

    func switchModel(_ newModelName: String) async throws {
        idleTask?.cancel()
        await asrManager?.cleanup()
        asrManager = nil
        _isModelLoaded = false
        modelVersion = Self.modelVersion(from: newModelName)
        try await initParakeet()
    }

    func unload() async {
        idleTask?.cancel()
        await asrManager?.cleanup()
        asrManager = nil
        _isModelLoaded = false
        AppLogger.shared.info("Parakeet model unloaded")
    }

    // MARK: - StreamingTranscriber protocol

    var isStreamingModelLoaded: Bool {
        _isStreamingModelLoaded
    }

    func preloadStreamingModel() async throws {
        guard streamingEngine == nil else { return }
        AppLogger.shared.info("Parakeet: loading EOU streaming model")
        do {
            // Create the concrete EOU manager directly so we can call
            // loadModelsFromHuggingFace() (not on the StreamingAsrEngine protocol).
            let eouEngine = StreamingEouAsrManager()
            try await eouEngine.loadModelsFromHuggingFace()
            // Register the stored partial callback if one was set before load
            if let cb = partialCallback {
                await eouEngine.setPartialTranscriptCallback(cb)
            }
            self.streamingEngine = eouEngine
            self._isStreamingModelLoaded = true
            AppLogger.shared.info("Parakeet: EOU streaming model loaded")
        } catch {
            AppLogger.shared.error("Parakeet: streaming model load failed: \(error)")
            throw error
        }
    }

    func unloadStreamingModel() async {
        streamingEngine = nil
        _isStreamingModelLoaded = false
        AppLogger.shared.info("Parakeet: streaming model unloaded")
    }

    func beginStreaming() async throws {
        guard let engine = streamingEngine else {
            throw TranscriberError.modelNotLoaded
        }
        try await engine.reset()
        AppLogger.shared.info("Parakeet: streaming session started")
    }

    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer) async throws {
        guard let engine = streamingEngine else { return }
        try await engine.appendAudio(buffer)
        try await engine.processBufferedAudio()
    }

    func endStreaming() async throws -> String {
        guard let engine = streamingEngine else {
            throw TranscriberError.modelNotLoaded
        }
        let text = try await engine.finish()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        AppLogger.shared.info("Parakeet streaming final: \(trimmed)")
        resetIdleTimer()
        return trimmed
    }

    func setPartialCallback(_ callback: @escaping @Sendable (String) -> Void) {
        partialCallback = callback
        // If engine already loaded, register immediately
        if let engine = streamingEngine {
            Task {
                await engine.setPartialTranscriptCallback(callback)
            }
        }
    }

    /// Checks if Parakeet models are cached locally.
    nonisolated static func isModelCached(_ modelName: String) -> Bool {
        let version = modelVersion(from: modelName)
        let cacheDir = modelCacheDirectory(for: version)
        return FileManager.default.fileExists(atPath: cacheDir.path)
    }

    /// Returns the cache directory for a given model version.
    nonisolated static func modelCacheDirectory(for version: AsrModelVersion) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return appSupport
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    /// Checks if the EOU streaming model is already downloaded.
    /// The streaming model lives in the same FluidAudio models directory.
    nonisolated static func isStreamingModelCached() -> Bool {
        let modelsDir = modelCacheDirectory(for: .v2)  // same base dir
        // The EOU model folder contains "eou" or "parakeet-eou" in the name.
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: modelsDir.path) else {
            return false
        }
        return contents.contains { $0.lowercased().contains("eou") }
    }

    // MARK: - Private helpers

    private func initParakeet() async throws {
        let versionName = Self.modelName(from: modelVersion)
        AppLogger.shared.info("Initializing Parakeet with model: \(versionName)")

        do {
            let models = try await AsrModels.downloadAndLoad(version: modelVersion)
            let asr = AsrManager()
            try await asr.initialize(models: models)
            self.asrManager = asr
            self._isModelLoaded = true

            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.downloadCompleteNotification, object: nil)
            }

            AppLogger.shared.info("Parakeet model loaded: \(versionName)")
            resetIdleTimer()
        } catch {
            AppLogger.shared.error("Parakeet init failed for model '\(versionName)': \(error)")
            throw error
        }
    }

    private func resetIdleTimer() {
        idleTask?.cancel()
        guard idleTimeout > 0 else { return }
        idleTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(self?.idleTimeout ?? 3600) * 1_000_000_000)
                await self?.unload()
            } catch {
                // Task cancelled — fine
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
}
