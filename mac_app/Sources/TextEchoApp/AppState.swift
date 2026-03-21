import AppKit
import Foundation

final class AppState {
    private let config = AppConfig.shared
    private let logger = AppLogger.shared

    private let overlay = OverlayWindowController()
    private let inputMonitor = InputMonitor()
    private let recorder = AudioRecorder()
    private let textInjector = TextInjector()
    private let pythonServices = PythonServiceManager()
    private let pedalMonitor = StreamDeckPedalMonitor()

    private let transcriber: WhisperKitTranscriber

    private var settingsWindow: SettingsWindowController?
    private var logsWindow: LogsWindowController?

    private var isRecording = false
    private var isLLMMode = false
    private var isModelLoading = false

    static let modelLoadingNotification = Notification.Name("TextEchoModelLoading")

    init() {
        let model = AppConfig.shared.model
        transcriber = WhisperKitTranscriber(
            modelName: model.whisperModel,
            idleTimeout: model.whisperIdleTimeout
        )
    }

    func start() {
        logger.info("Starting TextEcho")

        // Clean stale LLM socket from previous sessions
        cleanStaleSocket(path: config.model.llmSocket)

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

        // Stream Deck Pedal — push-to-talk
        if config.model.pedalEnabled {
            startPedalMonitor()
        }

        // Pre-warm the WhisperKit model so first recording is fast
        Task(priority: .utility) { [weak self] in
            guard let self else { return }
            await MainActor.run {
                self.isModelLoading = true
                NotificationCenter.default.post(name: Self.modelLoadingNotification, object: true)
            }
            self.overlay.showLoadingModel()
            do {
                try await self.transcriber.preload()
                self.logger.info("WhisperKit model preloaded")
            } catch {
                self.logger.error("WhisperKit preload failed: \(error.localizedDescription)")
            }
            await MainActor.run {
                self.isModelLoading = false
                NotificationCenter.default.post(name: Self.modelLoadingNotification, object: false)
            }
            self.overlay.hide()
        }
    }

    func restartInputMonitor() {
        inputMonitor.stop()
        inputMonitor.start()
    }

    func stop() {
        logger.info("Stopping TextEcho")
        inputMonitor.stop()
        pedalMonitor.stop()
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
        guard !isModelLoading else {
            overlay.showLoadingModelBlocked()
            return
        }
        isRecording = true
        isLLMMode = (mode == .llm)

        logger.info("Recording started (mode: \(mode.rawValue))")
        overlay.showRecording(isLLM: isLLMMode)

        // Set configured input device (empty = system default)
        let deviceUID = config.model.inputDeviceUID
        if !deviceUID.isEmpty, let deviceID = AudioRecorder.deviceID(forUID: deviceUID) {
            recorder.setInputDevice(deviceID: deviceID)
        }

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

        let isLLM = self.isLLMMode
        recorder.stop { [weak self] audioData in
            guard let self else { return }
            guard let audioData else {
                self.overlay.showError("No audio captured")
                return
            }

            // Dispatch transcription off the main thread to avoid blocking CGEventTap
            Task(priority: .userInitiated) {
                await self.transcribe(audioData: audioData, isLLM: isLLM)
            }
        }
    }

    private func cancelRecording() {
        guard isRecording else { return }
        logger.info("Recording cancelled")
        isRecording = false
        recorder.stop { _ in }
        overlay.hide()
    }

    private func transcribe(audioData: Data, isLLM: Bool) async {
        do {
            let text = try await transcriber.transcribe(
                audioData: audioData,
                sampleRate: config.sampleRate
            )

            await MainActor.run {
                if text.isEmpty {
                    self.logger.info("No speech detected (empty transcription)")
                    self.overlay.hide()
                } else if isLLM {
                    self.handleLLM(text: text)
                } else {
                    self.logger.info("Transcription: \(text)")
                    self.overlay.showResult(text, isLLM: false)
                    self.textInjector.inject(text)
                }
            }
        } catch {
            await MainActor.run {
                self.logger.error("Transcription failed: \(error.localizedDescription)")
                self.overlay.showError(error.localizedDescription)
            }
        }
    }

    private func handleLLM(text: String) {
        guard config.llmEnabled, config.model.llmAvailable else {
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

    private func startPedalMonitor() {
        pedalMonitor.activePedal = PedalPosition(rawValue: config.model.pedalPosition) ?? .center

        // Left pedal: paste (Cmd+V)
        pedalMonitor.onPedalDownByPosition[PedalPosition.left.rawValue] = { [weak self] in
            self?.logger.info("Pedal action: paste")
            self?.textInjector.sendPaste()
        }

        // Center pedal: push-to-talk (hold to record, release to transcribe)
        pedalMonitor.onPedalDownByPosition[PedalPosition.center.rawValue] = { [weak self] in
            self?.beginRecording(mode: .standard)
        }
        pedalMonitor.onPedalUpByPosition[PedalPosition.center.rawValue] = { [weak self] in
            self?.endRecording(userInitiated: true)
        }

        // Right pedal: enter
        pedalMonitor.onPedalDownByPosition[PedalPosition.right.rawValue] = { [weak self] in
            self?.logger.info("Pedal action: enter")
            self?.textInjector.sendEnter()
        }

        pedalMonitor.onConnectionChanged = { [weak self] connected in
            self?.logger.info("Stream Deck Pedal \(connected ? "connected" : "disconnected")")
        }
        pedalMonitor.start()
    }

    private func cleanStaleSocket(path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        if !UnixSocket.ping(socketPath: path, command: "status") {
            try? FileManager.default.removeItem(atPath: path)
            logger.info("Removed stale socket at startup: \(path)")
        }
    }
}

enum RecordingMode: String {
    case standard
    case llm
}
