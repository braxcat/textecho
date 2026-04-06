import SwiftUI

@main
struct TextEchoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appModel = AppModel()

    private var menuBarInserted: Binding<Bool> {
        Binding(
            get: { appModel.menuBarVisible },
            set: { value in
                appModel.setMenuBarVisible(value)
            }
        )
    }

    var body: some Scene {
        MenuBarExtra("TextEcho", systemImage: appModel.isModelLoading ? "hourglass" : (appModel.isRecording ? "record.circle" : "waveform"), isInserted: menuBarInserted) {
            // Stop Recording — only shown when recording
            if appModel.isRecording {
                Button("Stop Recording") {
                    appModel.stopRecording()
                }
                Divider()
            }

            Button("Model: \(appModel.currentModelDisplayName)") {
                appModel.openModelPicker()
            }
            Divider()

            if AppConfig.shared.model.llmAvailable {
                Button("LLM Mode: \(appModel.llmModeDisplay)") {
                    appModel.cycleLLMMode()
                }
                Button("Start LLM Recording") {
                    appModel.startRecording(llm: true)
                }
                .disabled(appModel.isRecording)
                Divider()
            }

            // Recent transcriptions (FlyCut-style)
            if AppConfig.shared.model.historyEnabled && AppConfig.shared.model.menuBarHistoryEnabled {
                if !appModel.recentHistory.isEmpty {
                    Text("Recent Transcriptions")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    ForEach(appModel.recentHistory) { entry in
                        Button(action: {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(entry.text, forType: .string)
                        }) {
                            Text(entry.text.count > 120
                                ? String(entry.text.prefix(120)) + "…"
                                : entry.text)
                        }
                    }
                    Divider()
                }
                Button("Transcription History…") {
                    appModel.openHistory()
                }
                Divider()
            }

            Button("Settings…") {
                appModel.openSettings()
            }

            Button("Help") {
                appModel.openHelp()
            }

            Divider()

            Button("Quit TextEcho") {
                appModel.quit()
            }
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var menuBarVisible: Bool
    @Published var autostartEnabled: Bool
    @Published var isModelLoading: Bool = false
    @Published var isRecording: Bool = false
    @Published var recentHistory: [HistoryEntry] = []

    private let appState = AppState()
    private var restoreWindow: RestoreWindowController?
    private var setupWizard: SetupWizardController?
    private var helpWindow: HelpWindowController?
    private var historyWindow: HistoryWindowController?
    private var modelPickerWindow: ModelPickerWindowController?
    private var notificationObservers: [NSObjectProtocol] = []

    init() {
        menuBarVisible = AppConfig.shared.model.showMenuBarIcon
        autostartEnabled = LaunchdManager.shared.isEnabled()
        AppLogger.shared.info("AppModel init")
        StartupLogger.write("AppModel init")
        appState.start()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.showSetupWizardIfNeeded()
            let shouldShowRestore = !self.menuBarVisible
            if shouldShowRestore {
                self.showRestoreWindow()
            }
        }

        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: AppState.modelLoadingNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.isModelLoading = notification.object as? Bool ?? false
        })

        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: AppState.recordingStateNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.isRecording = notification.object as? Bool ?? false
        })

        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: TranscriptionHistory.changedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshHistory()
        })

        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: .textechoConfigChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let desired = AppConfig.shared.model.showMenuBarIcon
            if self.menuBarVisible != desired {
                self.applyMenuBarVisibility(desired)
            }
            self.appState.reloadTranscriber()
            self.refreshHistory()
        })

        refreshHistory()
    }

    func startRecording(llm: Bool) {
        appState.beginRecording(mode: llm ? .llm : .standard)
    }

    func stopRecording() {
        appState.endRecording(userInitiated: true)
    }

    func openHistory() {
        if historyWindow == nil {
            historyWindow = HistoryWindowController()
        }
        historyWindow?.show()
    }

    func openModelPicker() {
        if modelPickerWindow == nil {
            modelPickerWindow = ModelPickerWindowController()
        }
        modelPickerWindow?.show()
    }

    var currentModelDisplayName: String {
        let config = AppConfig.shared.model
        if config.transcriptionEngine == "whisper" {
            let name = config.whisperModel
            return WhisperKitTranscriber.availableModelList
                .first(where: { $0.name == name })?.displayName ?? name
        } else {
            let name = config.parakeetModel
            return ParakeetTranscriber.availableModelList
                .first(where: { $0.name == name })?.displayName ?? name
        }
    }

    var llmModeDisplay: String {
        let mode = LLMMode(rawValue: AppConfig.shared.model.llmMode) ?? .grammar
        return mode.displayName
    }

    func cycleLLMMode() {
        appState.handleCycleLLMMode()
    }

    private func refreshHistory() {
        guard AppConfig.shared.model.historyEnabled && AppConfig.shared.model.menuBarHistoryEnabled else {
            recentHistory = []
            return
        }
        recentHistory = Array(TranscriptionHistory.shared.getEntries().prefix(5))
    }

    func openSettings() {
        appState.openSettings(onOpenSetupWizard: { [weak self] in
            self?.openSetupWizard()
        })
    }

    func openLogs() {
        appState.openLogs()
    }

    func openHelp() {
        if helpWindow == nil {
            helpWindow = HelpWindowController()
        }
        helpWindow?.show()
    }

    func openSetupWizard() {
        if setupWizard == nil {
            setupWizard = SetupWizardController(onClose: { [weak self] in
                self?.setupWizard?.close()
                self?.setupWizard = nil
                self?.appState.restartInputMonitor()
            })
        }
        setupWizard?.show()
    }

    func uninstall() {
        UninstallManager.shared.requestUninstall(appState: appState)
    }

    func quit() {
        appState.quit()
    }

    private func showRestoreWindow() {
        if restoreWindow == nil {
            restoreWindow = RestoreWindowController(onRestore: { [weak self] in
                self?.setMenuBarVisible(true)
            })
        }
        restoreWindow?.show()
    }

    private func hideRestoreWindow() {
        restoreWindow?.close()
        restoreWindow = nil
    }

    private func showSetupWizardIfNeeded() {
        guard AppConfig.shared.model.firstLaunch else { return }

        if setupWizard == nil {
            setupWizard = SetupWizardController(onClose: { [weak self] in
                AppLogger.shared.info("Setup wizard onClose fired (self=\(self == nil ? "nil" : "alive"))")
                self?.setupWizard?.close()
                self?.setupWizard = nil
                self?.appState.finalizeFirstLaunchSetup()
                self?.appState.restartInputMonitor()
            })
        }
        setupWizard?.show()
    }

    private func syncMenuBarVisibility() {
        AppConfig.shared.update { model in
            model.showMenuBarIcon = menuBarVisible
        }
        if menuBarVisible {
            hideRestoreWindow()
        } else {
            showRestoreWindow()
        }
    }

    private func applyMenuBarVisibility(_ value: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.menuBarVisible != value {
                self.menuBarVisible = value
            }
            if value {
                self.hideRestoreWindow()
            } else {
                self.showRestoreWindow()
            }
        }
    }

    private func syncAutostart() {
        if autostartEnabled {
            LaunchdManager.shared.enable()
        } else {
            LaunchdManager.shared.disable()
        }
    }

    deinit {
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        notificationObservers.removeAll()
        // deinit is nonisolated — dispatch to MainActor for @MainActor AppState.stop()
        let state = appState
        Task { @MainActor in
            state.stop()
        }
    }

    // SwiftUI onChange hooks
    func setMenuBarVisible(_ value: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.menuBarVisible != value {
                self.menuBarVisible = value
            }
            self.syncMenuBarVisibility()
        }
    }

    func setAutostartEnabled(_ value: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.autostartEnabled != value {
                self.autostartEnabled = value
            }
            self.syncAutostart()
        }
    }
}
