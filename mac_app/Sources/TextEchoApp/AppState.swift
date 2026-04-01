import AppKit
import Foundation

@MainActor
final class AppState {
    private let config = AppConfig.shared
    private let logger = AppLogger.shared

    private let overlay = OverlayWindowController()
    private let inputMonitor = InputMonitor()
    private let recorder = AudioRecorder()
    private let textInjector = TextInjector()
    private let pythonServices = PythonServiceManager()
    private let pedalMonitor = StreamDeckPedalMonitor()
    private let trackpadMonitor = TrackpadMonitor()

    private var transcriber: (any Transcriber)?
    private var loadedEngine: String = ""
    private var loadedModel: String = ""

    private var settingsWindow: SettingsWindowController?
    private var logsWindow: LogsWindowController?

    private var isRecording = false
    private var isLLMMode = false
    private var isModelLoading = false
    private var hasPreloaded = false

    nonisolated static let modelLoadingNotification = Notification.Name("TextEchoModelLoading")
    nonisolated static let recordingStateNotification = Notification.Name("TextEchoRecordingState")

    init() {
        let model = AppConfig.shared.model
        if model.firstLaunch {
            // Skip transcriber — setup wizard will call finalizeFirstLaunchSetup() on close.
            transcriber = nil
        } else if model.transcriptionEngine == "whisper" {
            transcriber = WhisperKitTranscriber(
                modelName: model.whisperModel,
                idleTimeout: model.whisperIdleTimeout
            )
            loadedEngine = "whisper"
            loadedModel = model.whisperModel
        } else {
            transcriber = ParakeetTranscriber(
                modelName: model.parakeetModel,
                idleTimeout: model.whisperIdleTimeout
            )
            loadedEngine = "parakeet"
            loadedModel = model.parakeetModel
        }
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

        // Show alert if Accessibility permission is missing or stale after an app update
        NotificationCenter.default.addObserver(forName: .textechoAccessibilityFailed, object: nil, queue: .main) { [weak self] _ in
            self?.showAccessibilityAlert()
        }

        // Don't start the event tap during the first-launch wizard — hotkeys would fire
        // mid-setup. restartInputMonitor() is called from the wizard's onClose callback.
        if !config.model.firstLaunch {
            inputMonitor.start()
        }

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

        // Magic Trackpad — force click / right-click trigger
        if config.model.trackpadEnabled {
            startTrackpadMonitor()
        }

        // Pre-warm only on non-first-launch when model is already downloaded.
        // On first launch the setup wizard handles loading inline.
        if config.model.firstLaunch {
            logger.info("First launch — setup wizard will handle model loading")
        } else if isCurrentModelCached() {
            startPreloadTask()
        } else {
            logger.info("WhisperKit model not downloaded yet, skipping auto-preload")
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
        trackpadMonitor.stop()
        recorder.stop()
        overlay.hide()
        pythonServices.stopAll()
    }

    /// Called by the setup wizard's onClose callback on first launch.
    /// Creates the transcriber for the engine/model the user chose, then preloads it.
    func finalizeFirstLaunchSetup() {
        guard transcriber == nil else { return }
        let model = config.model
        let engine = model.transcriptionEngine
        if engine == "whisper" {
            transcriber = WhisperKitTranscriber(modelName: model.whisperModel, idleTimeout: model.whisperIdleTimeout)
            loadedEngine = "whisper"
            loadedModel = model.whisperModel
        } else {
            transcriber = ParakeetTranscriber(modelName: model.parakeetModel, idleTimeout: model.whisperIdleTimeout)
            loadedEngine = "parakeet"
            loadedModel = model.parakeetModel
        }
        if isCurrentModelCached() {
            startPreloadTask()
        }
    }

    /// Hot-swaps the transcriber when the engine or model changes in Settings.
    /// No-op if the engine and model already match the current transcriber.
    func reloadTranscriber() {
        let model = config.model
        let engine = model.transcriptionEngine
        let modelName = engine == "whisper" ? model.whisperModel : model.parakeetModel
        guard engine != loadedEngine || modelName != loadedModel else { return }

        let old = transcriber
        if let old {
            Task { await old.unload() }
        }

        transcriber = nil
        hasPreloaded = false
        loadedEngine = engine
        loadedModel = modelName

        if engine == "whisper" {
            transcriber = WhisperKitTranscriber(modelName: model.whisperModel, idleTimeout: model.whisperIdleTimeout)
        } else {
            transcriber = ParakeetTranscriber(modelName: model.parakeetModel, idleTimeout: model.whisperIdleTimeout)
        }

        if isCurrentModelCached() {
            startPreloadTask()
        }
    }

    private func startPreloadTask() {
        guard !hasPreloaded, let transcriber else { return }
        hasPreloaded = true
        isModelLoading = true
        NotificationCenter.default.post(name: Self.modelLoadingNotification, object: true)
        overlay.showLoadingModel()
        Task.detached(priority: .utility) { [weak self, transcriber] in
            do {
                try await transcriber.preload()
                await MainActor.run {
                    self?.logger.info("Model preloaded")
                }
            } catch {
                await MainActor.run {
                    self?.logger.error("Model preload failed: \(error.localizedDescription)")
                }
            }
            await MainActor.run {
                self?.isModelLoading = false
                NotificationCenter.default.post(name: AppState.modelLoadingNotification, object: false)
                self?.overlay.hide()
            }
        }
    }

    private func handleInputEvent(_ event: InputEvent) {
        switch event {
        case .triggerDown:
            guard config.model.mouseEnabled else { return }
            if config.model.mouseMode == 0 {
                isRecording ? endRecording(userInitiated: true) : beginRecording(mode: .standard)
            } else {
                beginRecording(mode: .standard)
            }
        case .triggerUp:
            guard config.model.mouseEnabled, config.model.mouseMode == 1 else { return }
            endRecording(userInitiated: true)
        case .dictateDown:
            guard config.model.keyboardEnabled else { return }
            if config.model.keyboardMode == 0 {
                isRecording ? endRecording(userInitiated: true) : beginRecording(mode: .standard)
            } else {
                beginRecording(mode: .standard)
            }
        case .dictateUp:
            guard config.model.keyboardEnabled, config.model.keyboardMode == 1 else { return }
            endRecording(userInitiated: true)
        case .dictateLLMDown:
            guard config.model.keyboardEnabled else { return }
            if config.model.keyboardMode == 0 {
                isRecording ? endRecording(userInitiated: true) : beginRecording(mode: .llm)
            } else {
                beginRecording(mode: .llm)
            }
        case .dictateLLMUp:
            guard config.model.keyboardEnabled, config.model.keyboardMode == 1 else { return }
            endRecording(userInitiated: true)
        case .capsLockChanged(let isOn):
            guard config.model.capsLockEnabled else { return }
            if isOn { beginRecording(mode: .standard) } else { endRecording(userInitiated: true) }
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
        NotificationCenter.default.post(name: Self.recordingStateNotification, object: true)
        isLLMMode = (mode == .llm)

        logger.info("Recording started (mode: \(mode.rawValue))")
        overlay.showRecording(isLLM: isLLMMode)

        // Set configured input device (empty = system default)
        let deviceUID = config.model.inputDeviceUID
        if !deviceUID.isEmpty, let deviceID = AudioRecorder.deviceID(forUID: deviceUID) {
            recorder.setInputDevice(deviceID: deviceID)
        }

        recorder.start(
            silenceDuration: config.model.silenceEnabled ? config.silenceDuration : 3600.0,
            silenceThreshold: config.silenceThreshold,
            sampleRate: config.sampleRate
        )
    }

    func endRecording(userInitiated: Bool) {
        guard isRecording else { return }
        isRecording = false
        NotificationCenter.default.post(name: Self.recordingStateNotification, object: false)

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
        NotificationCenter.default.post(name: Self.recordingStateNotification, object: false)
        recorder.stop { _ in }
        overlay.hide()
    }

    private func transcribe(audioData: Data, isLLM: Bool) async {
        guard let transcriber else {
            await MainActor.run { self.overlay.showError("No transcription model loaded") }
            return
        }
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
                    if !text.isEmpty && !isLLM {
                        TranscriptionHistory.shared.add(text: text)
                    }
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
                TranscriptionHistory.shared.add(text: response, isLLM: true)
            case .failure(let error):
                self.overlay.showError(error.localizedDescription)
            }
        }
    }

    func openSettings(onOpenSetupWizard: @escaping () -> Void = {}) {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(
                onUninstall: { [weak self] in
                    guard let self else { return }
                    UninstallManager.shared.requestUninstall(appState: self)
                },
                onOpenLogs: { [weak self] in
                    self?.openLogs()
                },
                onOpenSetupWizard: onOpenSetupWizard
            )
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

    private func startTrackpadMonitor() {
        trackpadMonitor.gesture = TrackpadGesture(rawValue: config.model.trackpadGesture) ?? .forceClick

        if config.model.trackpadMode == 0 {
            // Toggle mode
            trackpadMonitor.onTriggerDown = { [weak self] in
                if self?.isRecording == true {
                    self?.endRecording(userInitiated: true)
                } else {
                    self?.beginRecording(mode: .standard)
                }
            }
            trackpadMonitor.onTriggerUp = nil
        } else {
            // Hold mode (default)
            trackpadMonitor.onTriggerDown = { [weak self] in
                self?.beginRecording(mode: .standard)
            }
            trackpadMonitor.onTriggerUp = { [weak self] in
                self?.endRecording(userInitiated: true)
            }
        }

        trackpadMonitor.onConnectionChanged = { [weak self] connected in
            self?.logger.info("Magic Trackpad \(connected ? "connected" : "disconnected")")
        }
        trackpadMonitor.start()
    }

    private func isCurrentModelCached() -> Bool {
        if config.model.transcriptionEngine == "whisper" {
            return WhisperKitTranscriber.isModelCached(config.model.whisperModel)
        } else {
            return ParakeetTranscriber.isModelCached(config.model.parakeetModel)
        }
    }

    private func cleanStaleSocket(path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        if !UnixSocket.ping(socketPath: path, command: "status") {
            try? FileManager.default.removeItem(atPath: path)
            logger.info("Removed stale socket at startup: \(path)")
        }
    }

    private func showAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = "TextEcho needs Accessibility access to detect hotkeys.\n\nAfter updating the app, you may need to remove and re-add TextEcho in:\nSystem Settings → Privacy & Security → Accessibility\n\n1. Remove TextEcho from the list\n2. Click '+' and add TextEcho from /Applications\n3. Restart TextEcho"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Dismiss")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

enum RecordingMode: String {
    case standard
    case llm
}
