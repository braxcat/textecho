import AVFoundation
import Foundation

final class AudioRecorder {
    var onWaveform: (([Double]) -> Void)?
    var onAutoStop: (() -> Void)?

    private let engine = AVAudioEngine()
    private var bufferData = Data()
    private var lastSoundTime = Date()
    private var isRecording = false
    private var silenceDuration: Double = 2.5
    private var silenceThreshold: Double = 0.015
    private var sampleRate: Double = 16000

    private let waveformWindow = 40
    private var waveformLevels: [Double] = []

    func start(silenceDuration: Double, silenceThreshold: Double, sampleRate: Double) {
        guard !isRecording else { return }

        self.silenceDuration = silenceDuration
        self.silenceThreshold = silenceThreshold
        self.sampleRate = sampleRate

        bufferData = Data()
        lastSoundTime = Date()
        isRecording = true
        waveformLevels = Array(repeating: 0.0, count: waveformWindow)

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard let desiredFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                               sampleRate: sampleRate,
                                               channels: 1,
                                               interleaved: true) else {
            AppLogger.shared.error("Failed to create desired audio format")
            return
        }
        let converter = AVAudioConverter(from: format, to: desiredFormat)

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            guard let converter else { return }

            let pcmBuffer = AVAudioPCMBuffer(pcmFormat: desiredFormat, frameCapacity: AVAudioFrameCount(sampleRate / 10))
            var error: NSError?
            converter.convert(to: pcmBuffer!, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            if let error {
                AppLogger.shared.error("Audio conversion error: \(error)")
                return
            }

            guard let channelData = pcmBuffer?.int16ChannelData else { return }
            let frameLength = Int(pcmBuffer?.frameLength ?? 0)
            let samples = UnsafeBufferPointer(start: channelData[0], count: frameLength)

            let data = Data(bytes: samples.baseAddress!, count: frameLength * MemoryLayout<Int16>.size)
            self.bufferData.append(data)

            self.updateLevels(samples: samples)
            self.checkSilence(samples: samples)
        }

        do {
            try engine.start()
        } catch {
            AppLogger.shared.error("Failed to start audio engine: \(error)")
        }
    }

    func stop(completion: @escaping (Data?) -> Void) {
        guard isRecording else { completion(nil); return }
        isRecording = false

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        completion(bufferData)
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func updateLevels(samples: UnsafeBufferPointer<Int16>) {
        let rms = computeRMS(samples: samples)
        waveformLevels.removeFirst()
        waveformLevels.append(min(max(rms * 5.0, 0.0), 1.0))
        onWaveform?(waveformLevels)
    }

    private func checkSilence(samples: UnsafeBufferPointer<Int16>) {
        guard isRecording else { return }
        let rms = computeRMS(samples: samples)
        if rms > silenceThreshold {
            lastSoundTime = Date()
            return
        }

        let elapsed = Date().timeIntervalSince(lastSoundTime)
        if elapsed >= silenceDuration {
            onAutoStop?()
        }
    }

    private func computeRMS(samples: UnsafeBufferPointer<Int16>) -> Double {
        let count = Double(samples.count)
        if count == 0 { return 0 }
        var sum: Double = 0
        for s in samples {
            let v = Double(s) / 32768.0
            sum += v * v
        }
        return sqrt(sum / count)
    }
}
