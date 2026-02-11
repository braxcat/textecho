import AVFoundation
import Foundation
import os

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

    private let lock: UnsafeMutablePointer<os_unfair_lock_s>

    init() {
        lock = UnsafeMutablePointer<os_unfair_lock_s>.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock_s())
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    func start(silenceDuration: Double, silenceThreshold: Double, sampleRate: Double) {
        os_unfair_lock_lock(lock)
        guard !isRecording else {
            os_unfair_lock_unlock(lock)
            return
        }

        self.silenceDuration = silenceDuration
        self.silenceThreshold = silenceThreshold
        self.sampleRate = sampleRate

        bufferData = Data()
        lastSoundTime = Date()
        isRecording = true
        waveformLevels = Array(repeating: 0.0, count: waveformWindow)
        os_unfair_lock_unlock(lock)

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
            os_unfair_lock_lock(self.lock)
            self.bufferData.append(data)
            os_unfair_lock_unlock(self.lock)

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
        os_unfair_lock_lock(lock)
        guard isRecording else {
            os_unfair_lock_unlock(lock)
            completion(nil)
            return
        }
        isRecording = false
        let capturedData = bufferData
        os_unfair_lock_unlock(lock)

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        completion(capturedData)
    }

    func stop() {
        os_unfair_lock_lock(lock)
        guard isRecording else {
            os_unfair_lock_unlock(lock)
            return
        }
        isRecording = false
        os_unfair_lock_unlock(lock)

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func updateLevels(samples: UnsafeBufferPointer<Int16>) {
        let rms = computeRMS(samples: samples)
        os_unfair_lock_lock(lock)
        waveformLevels.removeFirst()
        waveformLevels.append(min(max(rms * 5.0, 0.0), 1.0))
        let levels = waveformLevels
        os_unfair_lock_unlock(lock)
        onWaveform?(levels)
    }

    private func checkSilence(samples: UnsafeBufferPointer<Int16>) {
        os_unfair_lock_lock(lock)
        guard isRecording else {
            os_unfair_lock_unlock(lock)
            return
        }
        os_unfair_lock_unlock(lock)

        let rms = computeRMS(samples: samples)
        if rms > silenceThreshold {
            os_unfair_lock_lock(lock)
            lastSoundTime = Date()
            os_unfair_lock_unlock(lock)
            return
        }

        os_unfair_lock_lock(lock)
        let elapsed = Date().timeIntervalSince(lastSoundTime)
        os_unfair_lock_unlock(lock)
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
