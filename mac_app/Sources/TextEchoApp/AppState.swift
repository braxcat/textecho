import AppKit
import Foundation

final class AppState {
    private let config = AppConfig.shared
    private let logger = AppLogger.shared

    private let overlay = OverlayWindowController()
    private let inputMonitor = InputMonitor()
    private let recorder = AudioRecorder()
    private let transcription = TranscriptionClient()
    private let textInjector = TextInjector()
    private let pythonServices = PythonServiceManager()

    private var settingsWindow: SettingsWindowController?
    private var logsWindow: LogsWindowController?

    private var isRecording = false
    private var isLLMMode = false

    func start() {
        logger.info("Starting TextEcho")

        AccessibilityHelper.requestIfNeeded()
        MicrophoneHelper.requestIfNeeded()

        inputMonitor.onEvent = { [weak self] event in
            self?.handleInputEvent(event)
        }
        inputMonitor.start()

        recorder.onWaveform = { [weak self] levels in
            self?.overlay.updateWaveform(levels)
        }
        recorder.onAutoStop = { [weak self] in
            self?.endRecording(userInitiated: false)
        }

    }

    func restartInputMonitor() {
        inputMonitor.stop()
        inputMonitor.start()
    }

    func stop() {
        logger.info("Stopping TextEcho")
        inputMonitor.stop()
        recorder.stop()
        overlay.hide()
        pythonServices.stopAll()
    }

    private func handleInputEvent(_ event: InputEvent) {
        switch event {
        case .triggerDown:
            beginRecording(mode: .standard)
        case .triggerUp:
            endRecording(userInitiated: true)
        case .dictateDown:
            beginRecording(mode: .standard)
        case .dictateUp:
            endRecording(userInitiated: true)
        case .dictateLLMDown:
            beginRecording(mode: .llm)
        case .dictateLLMUp:
            endRecording(userInitiated: true)
        case .settingsHotkey:
            openSettings()
        case .escape:
            cancelRecording()
        case .register(let index):
            textInjector.captureClipboardToRegister(index)
        case .clearRegisters:
            textInjector.clearRegisters()
        }
    }

    func beginRecording(mode: RecordingMode) {
        guard !isRecording else { return }
        isRecording = true
        isLLMMode = (mode == .llm)

        logger.info("Recording started (mode: \(mode.rawValue))")
        overlay.showRecording(isLLM: isLLMMode)

        recorder.start(
            silenceDuration: config.silenceDuration,
            silenceThreshold: config.silenceThreshold,
            sampleRate: config.sampleRate
        )
    }

    func endRecording(userInitiated: Bool) {
        guard isRecording else { return }
        isRecording = false

        logger.info("Recording stopped (userInitiated=\(userInitiated))")
        overlay.showProcessing(isLLM: isLLMMode)

        recorder.stop { [weak self] audioData in
            guard let self else { return }
            guard let audioData else {
                self.overlay.showError("No audio captured")
                return
            }

            self.transcribe(audioData: audioData, isLLM: self.isLLMMode)
        }
    }

    private func cancelRecording() {
        guard isRecording else { return }
        logger.info("Recording cancelled")
        isRecording = false
        recorder.stop { _ in }
        overlay.hide()
    }

    private func transcribe(audioData: Data, isLLM: Bool) {
        let pythonPath = AppConfig.shared.model.pythonPath
        if !FileManager.default.isExecutableFile(atPath: pythonPath) {
            overlay.showError("Python not found at \(pythonPath). Update Python Path in Settings and relaunch.")
            return
        }
        pythonServices.ensureTranscriptionDaemon()
        let socketPath = AppConfig.shared.model.transcriptionSocket
        if !waitForTranscriptionSocket(socketPath: socketPath) {
            overlay.showError("Transcription daemon not running (socket missing). Check Python Path and Daemons Dir in Settings, then relaunch.")
            return
        }

        transcription.transcribeRaw(
            audioData: audioData,
            sampleRate: config.sampleRate
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let text):
                if isLLM {
                    self.handleLLM(text: text)
                } else {
                    self.overlay.showResult(text, isLLM: false)
                    self.textInjector.inject(text)
                }
            case .failure(let error):
                self.overlay.showError(error.localizedDescription)
            }
        }
    }

    private func waitForTranscriptionSocket(socketPath: String) -> Bool {
        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            if UnixSocket.ping(socketPath: socketPath, command: "status") {
                return true
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }

    private func handleLLM(text: String) {
        guard config.llmEnabled else {
            overlay.showResult(text, isLLM: false)
            textInjector.inject(text)
            return
        }

        pythonServices.ensureLLMDaemon()
        let context = textInjector.registersContext()
        LLMClient.shared.send(prompt: text, context: context) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let response):
                self.overlay.showResult(response, isLLM: true)
                self.textInjector.inject(response)
            case .failure(let error):
                self.overlay.showError(error.localizedDescription)
            }
        }
    }

    func openSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController()
        }
        settingsWindow?.show()
    }

    func openLogs() {
        if logsWindow == nil {
            logsWindow = LogsWindowController()
        }
        logsWindow?.show()
    }

    func toggleAutostart(enabled: Bool) {
        if enabled {
            LaunchdManager.shared.enable()
        } else {
            LaunchdManager.shared.disable()
        }
    }

    func quit() {
        stop()
        NSApplication.shared.terminate(nil)
    }
}

enum RecordingMode: String {
    case standard
    case llm
}
