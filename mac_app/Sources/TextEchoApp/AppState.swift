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
    private let llmProcessor = MLXLLMProcessor()
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
    private var isStreaming = false
    private var isAwaitingLLMConfirm = false
    private var isAwaitingLLMSend = false   // waiting for Enter to send to LLM
    private var pendingLLMText = ""         // transcribed text waiting to be sent
    private var pendingLLMResponse = ""
    private var llmModeOverride: LLMMode?
    private var llmGenerationTask: Task<Void, Never>?

    nonisolated static let modelLoadingNotification = Notification.Name("TextEchoModelLoading")
    nonisolated static let recordingStateNotification = Notification.Name("TextEchoRecordingState")
    nonisolated static let llmModelReadyNotification = Notification.Name("TextEchoLLMModelReady")

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

        // Stream Deck Pedal — push-to-talk (only in Direct HID mode)
        if config.model.pedalEnabled && config.model.pedalInputMode == 0 {
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

        // Auto-load LLM model if enabled
        if config.model.llmAvailable {
            loadLLMModel()
        }

        // Listen for Settings telling us a new LLM model was downloaded
        NotificationCenter.default.addObserver(forName: Self.llmModelReadyNotification, object: nil, queue: .main) { [weak self] _ in
            self?.loadLLMModel()
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
    }

    /// Called by the setup wizard's onClose callback on first launch.
    /// Mirrors the start() initialization path so behavior is identical to a restart.
    func finalizeFirstLaunchSetup() {
        let model = AppConfig.shared.model
        let engine = model.transcriptionEngine
        logger.info("finalizeFirstLaunchSetup: transcriber=\(transcriber == nil ? "nil" : "set"), engine=\(engine), streaming=\(model.streamingEnabled), llmAvailable=\(model.llmAvailable), llmEngine=\(model.llmEngine)")

        // Create transcriber if not already set.
        // The .textechoConfigChanged notification may have already triggered
        // reloadTranscriber() before this method runs — that's fine, skip creation.
        if transcriber == nil {
            if engine == "whisper" {
                transcriber = WhisperKitTranscriber(modelName: model.whisperModel, idleTimeout: model.whisperIdleTimeout)
                loadedEngine = "whisper"
                loadedModel = model.whisperModel
            } else {
                transcriber = ParakeetTranscriber(modelName: model.parakeetModel, idleTimeout: model.whisperIdleTimeout)
                loadedEngine = "parakeet"
                loadedModel = model.parakeetModel
            }
            startPreloadTask()
        }

        // Load LLM — reloadTranscriber() doesn't handle this
        if model.llmAvailable {
            logger.info("finalizeFirstLaunchSetup: loading LLM model \(model.llmModelID)")
            loadLLMModel()
        }

        // Start pedal/trackpad monitors if configured during wizard
        if model.pedalEnabled && model.pedalInputMode == 0 {
            startPedalMonitor()
        }
        if model.trackpadEnabled {
            startTrackpadMonitor()
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

            // If streaming is enabled and the transcriber supports it, preload the
            // streaming model in the background after the main model is ready.
            let streamingEnabled = await MainActor.run { AppConfig.shared.model.streamingEnabled }
            if streamingEnabled, let streamingTranscriber = transcriber as? (any StreamingTranscriber) {
                do {
                    try await streamingTranscriber.preloadStreamingModel()
                    await MainActor.run {
                        AppLogger.shared.info("Streaming model preloaded")
                    }
                } catch {
                    await MainActor.run {
                        AppLogger.shared.error("Streaming model preload failed: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    private func loadLLMModel() {
        let modelID = config.model.llmModelID
        logger.info("Loading LLM model: \(modelID)")
        Task.detached(priority: .utility) { [weak self] in
            guard let processor = self?.llmProcessor else { return }
            do {
                try await processor.loadModel(id: modelID)
                AppLogger.shared.info("LLM model loaded and ready: \(modelID)")
            } catch {
                AppLogger.shared.error("LLM model load failed: \(error.localizedDescription)")
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
            // LLM mode can be triggered by keyboard (Ctrl+Shift+D) or mouse (Shift+Middle-click)
            // The input source already validated enablement, so just start recording
            beginRecording(mode: .llm)
        case .dictateLLMUp:
            endRecording(userInitiated: true)
        case .capsLockChanged(let isOn):
            guard config.model.capsLockEnabled else { return }
            if isOn { beginRecording(mode: .standard) } else { endRecording(userInitiated: true) }
        case .settingsHotkey:
            openSettings()
        case .escape:
            if isAwaitingLLMConfirm {
                discardLLMPaste()
            } else if isAwaitingLLMSend {
                cancelLLMSend()
            } else if llmGenerationTask != nil {
                cancelLLMGeneration()
            } else {
                cancelRecording()
            }
        case .confirmPaste:
            if isAwaitingLLMSend {
                sendToLLM()
            } else {
                confirmLLMPaste()
            }
        case .selectLLMMode(let mode):
            guard isRecording && isLLMMode else { return }
            llmModeOverride = mode
            overlay.showRecordingLLMMode(mode: mode.displayName, hint: "Ctrl+Shift+M to cycle")
        case .cycleLLMMode:
            cycleLLMMode()
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
        isStreaming = false
        NotificationCenter.default.post(name: Self.recordingStateNotification, object: true)
        isLLMMode = (mode == .llm)
        llmModeOverride = nil
        inputMonitor.shouldCaptureLLMMode = isLLMMode

        logger.info("Recording started (mode: \(mode.rawValue))")
        if isLLMMode {
            let currentMode = LLMMode(rawValue: config.model.llmMode) ?? .grammar
            overlay.showRecordingLLMMode(mode: currentMode.displayName, hint: "Ctrl+Shift+M to cycle")
        } else {
            overlay.showRecording(isLLM: false)
        }

        // Set configured input device (empty = system default)
        let deviceUID = config.model.inputDeviceUID
        if !deviceUID.isEmpty, let deviceID = AudioRecorder.deviceID(forUID: deviceUID) {
            recorder.setInputDevice(deviceID: deviceID)
        }

        // Activate streaming if enabled, Parakeet is the engine, and the streaming model is loaded.
        // LLM mode always uses the batch path (streaming result would be discarded anyway).
        let streamingEnabled = config.model.streamingEnabled
        if streamingEnabled,
           let streamingTranscriber = transcriber as? (any StreamingTranscriber) {
            Task(priority: .userInitiated) { [weak self] in
                guard await streamingTranscriber.isStreamingModelLoaded else {
                    await MainActor.run { self?.logger.info("Streaming model not loaded — falling back to batch transcription") }
                    return
                }
                guard await MainActor.run(body: { self?.isRecording == true }) else { return }

                do {
                    try await streamingTranscriber.beginStreaming()
                } catch {
                    await MainActor.run { self?.logger.error("beginStreaming failed: \(error.localizedDescription)") }
                    return
                }
                guard await MainActor.run(body: { self?.isRecording == true }) else {
                    _ = try? await streamingTranscriber.endStreaming()
                    return
                }

                // Register partial callback — fires on the FluidAudio internal thread.
                // Dispatch to MainActor for overlay updates.
                streamingTranscriber.setPartialCallback { [weak self] partial in
                    guard !partial.isEmpty else { return }
                    Task { @MainActor [weak self] in
                        self?.overlay.showStreamingPartial(partial)
                    }
                }

                // Forward raw AVAudioPCMBuffer taps to the streaming engine.
                let st = streamingTranscriber
                await MainActor.run { [weak self] in
                    self?.recorder.onAudioBuffer = { buffer in
                        Task(priority: .userInitiated) {
                            try? await st.appendAudioBuffer(buffer)
                        }
                    }
                    self?.isStreaming = true
                    self?.logger.info("Streaming transcription active")
                }
            }
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
        inputMonitor.shouldCaptureLLMMode = false
        NotificationCenter.default.post(name: Self.recordingStateNotification, object: false)

        logger.info("Recording stopped (userInitiated=\(userInitiated))")

        // Clear the buffer tap so no more audio is forwarded after stop.
        recorder.onAudioBuffer = nil

        let wasStreaming = isStreaming
        isStreaming = false
        let isLLM = self.isLLMMode
        let streamingTranscriber = wasStreaming ? (transcriber as? (any StreamingTranscriber)) : nil

        overlay.showProcessing(isLLM: isLLM)

        if wasStreaming, let st = streamingTranscriber {
            // Dual-pass: streaming showed real-time partials from EOU 120M during
            // recording. Now stop the recorder (capturing the full audio buffer),
            // clean up the streaming engine, and re-run through the batch TDT V3
            // model for an accurate final transcript.
            recorder.stop { [weak self] audioData in
                guard let self else { return }

                // Clean up streaming engine in background (discard its result).
                Task(priority: .utility) {
                    _ = try? await st.endStreaming()
                }

                guard let audioData else {
                    self.overlay.showError("No audio captured")
                    return
                }

                // Run batch transcription for accurate final result.
                Task(priority: .userInitiated) {
                    await self.transcribe(audioData: audioData, isLLM: isLLM)
                }
            }
        } else {
            // Batch path — unchanged behaviour.
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
    }

    private func cancelRecording() {
        guard isRecording else { return }
        logger.info("Recording cancelled")
        isRecording = false
        let wasStreaming = isStreaming
        isStreaming = false
        NotificationCenter.default.post(name: Self.recordingStateNotification, object: false)
        recorder.onAudioBuffer = nil
        recorder.stop { _ in }
        overlay.hide()

        // Clean up streaming engine if it was active (discard partial result).
        if wasStreaming, let st = transcriber as? (any StreamingTranscriber) {
            Task(priority: .utility) {
                _ = try? await st.endStreaming()
            }
        }
    }

    private func confirmLLMPaste() {
        guard isAwaitingLLMConfirm else { return }
        isAwaitingLLMConfirm = false
        inputMonitor.shouldConsumeReturn = false
        let response = pendingLLMResponse
        pendingLLMResponse = ""
        textInjector.inject(response)
        overlay.hide()
        logger.info("LLM review: confirmed paste (\(response.count) chars)")
    }

    func handleCycleLLMMode() { cycleLLMMode() }

    private func cycleLLMMode() {
        let allModes: [LLMMode] = [.grammar, .rephrase, .answer]
        let current = LLMMode(rawValue: config.model.llmMode) ?? .grammar
        let currentIndex = allModes.firstIndex(of: current) ?? 0
        let nextMode = allModes[(currentIndex + 1) % allModes.count]

        config.update { model in
            model.llmMode = nextMode.rawValue
        }

        if isAwaitingLLMSend {
            // Update the pre-send review overlay with the new mode
            overlay.showLLMPreSend(prompt: pendingLLMText, mode: nextMode.displayName)
        } else if isRecording && isLLMMode {
            overlay.showRecordingLLMMode(mode: nextMode.displayName, hint: "Ctrl+Shift+M to cycle")
        } else {
            // Flash overlay briefly showing the new mode
            overlay.showLLMModeCycled(mode: nextMode.displayName)
        }
        logger.info("LLM mode cycled to: \(nextMode.displayName)")

        // Update menu bar title
        updateMenuBarLLMMode(nextMode)
    }

    /// Updates the menu bar status item to show current LLM mode.
    /// Called on cycle and on launch.
    private func updateMenuBarLLMMode(_ mode: LLMMode) {
        NotificationCenter.default.post(
            name: Notification.Name("TextEchoLLMModeChanged"),
            object: mode.displayName
        )
    }

    private func discardLLMPaste() {
        guard isAwaitingLLMConfirm else { return }
        isAwaitingLLMConfirm = false
        inputMonitor.shouldConsumeReturn = false
        pendingLLMResponse = ""
        overlay.hide()
        logger.info("LLM review: discarded")
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
                    TranscriptionHistory.shared.add(text: text)
                    self.logger.info("Transcription complete (\(text.count) chars)")
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
        guard config.model.llmAvailable else {
            overlay.showResult(text, isLLM: false)
            textInjector.inject(text)
            return
        }

        // Show pre-send review: user sees their text + current mode, can cycle
        // mode with Ctrl+Shift+M, press Enter to send, or ESC to cancel.
        pendingLLMText = text
        isAwaitingLLMSend = true
        inputMonitor.shouldConsumeReturn = true
        let mode = LLMMode(rawValue: config.model.llmMode) ?? .grammar
        overlay.showLLMPreSend(prompt: text, mode: mode.displayName)
        logger.info("LLM pre-send: awaiting Enter to process with mode=\(mode.displayName)")
    }

    private func sendToLLM() {
        guard isAwaitingLLMSend else { return }
        isAwaitingLLMSend = false
        let text = pendingLLMText
        pendingLLMText = ""

        let context = textInjector.registersContext()
        let mode = llmModeOverride ?? LLMMode(rawValue: config.model.llmMode) ?? .grammar
        let systemPrompt = mode == .custom ? config.model.llmCustomPrompt : mode.systemPrompt
        llmModeOverride = nil

        overlay.showLLMProcessing(prompt: text)
        inputMonitor.shouldConsumeReturn = false

        llmGenerationTask = Task(priority: .userInitiated) {
            do {
                if !(await llmProcessor.isLoaded) {
                    await MainActor.run {
                        self.overlay.showError("LLM model not loaded.\nOpen Settings (Cmd+Opt+Space) →\nLLM Processing → Download & Load Model")
                    }
                    AppLogger.shared.info("LLM trigger ignored — model not loaded.")
                    return
                }

                let prompt = text
                let response = try await llmProcessor.generate(
                    prompt: text,
                    systemPrompt: systemPrompt,
                    context: context
                ) { [weak self] partialText in
                    Task { @MainActor in
                        self?.overlay.showLLMPartial(prompt: prompt, partial: partialText)
                    }
                }

                guard !Task.isCancelled else { return }

                await MainActor.run {
                    self.llmGenerationTask = nil
                    TranscriptionHistory.shared.add(text: response, isLLM: true)
                    if self.config.model.llmAutoPaste {
                        self.overlay.showResult(response, isLLM: true)
                        self.textInjector.inject(response)
                    } else {
                        self.pendingLLMResponse = response
                        self.isAwaitingLLMConfirm = true
                        self.inputMonitor.shouldConsumeReturn = true
                        self.overlay.showLLMReview(prompt: prompt, response: response)
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.llmGenerationTask = nil
                    self.overlay.showError(error.localizedDescription)
                }
                AppLogger.shared.error("LLM processing failed: \(error)")
            }
        }
    }

    private func cancelLLMSend() {
        isAwaitingLLMSend = false
        pendingLLMText = ""
        inputMonitor.shouldConsumeReturn = false
        overlay.hide()
        logger.info("LLM pre-send: cancelled")
    }

    private func cancelLLMGeneration() {
        llmGenerationTask?.cancel()
        llmGenerationTask = nil
        // Tell the MLX processor to stop generating tokens (nonisolated, immediate)
        llmProcessor.cancelGeneration()
        overlay.hide()
        logger.info("LLM generation: cancelled by user")
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
