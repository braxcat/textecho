import AVFoundation
import Foundation

/// Protocol for swappable transcription backends.
/// WhisperKitTranscriber is the primary implementation; the protocol allows
/// future backends (e.g. server-side, or fallback to Python daemon) without
/// changing the call sites in AppState.
protocol Transcriber: Sendable {
    func transcribe(audioData: Data, sampleRate: Double) async throws -> String
    func preload() async throws
    func unload() async
    var isModelLoaded: Bool { get async }
}

/// Protocol for transcription backends that support real-time streaming.
/// Only implemented by ParakeetTranscriber (via FluidAudio StreamingEouAsrManager).
/// WhisperKitTranscriber does not conform — it retains the batch-only flow.
protocol StreamingTranscriber: Transcriber {
    /// Resets streaming engine state ready for a new utterance.
    func beginStreaming() async throws
    /// Called for each raw AVAudioPCMBuffer from the tap during recording.
    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer) async throws
    /// Finalises the utterance and returns the complete transcript.
    func endStreaming() async throws -> String
    /// Registers a callback that fires whenever a new partial transcript is available.
    func setPartialCallback(_ callback: @escaping @Sendable (String) -> Void)
    /// Whether the dedicated EOU streaming model is loaded in memory.
    var isStreamingModelLoaded: Bool { get async }
    /// Downloads and loads the EOU streaming model (~300 MB, one-time).
    func preloadStreamingModel() async throws
    /// Releases the streaming model from memory.
    func unloadStreamingModel() async
}

