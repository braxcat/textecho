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
