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
                            let preview = entry.text.count > 40
                                ? String(entry.text.prefix(40)) + "…"
                                : entry.text
                            Text(preview)
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

    init() {
        menuBarVisible = AppConfig.shared.model.showMenuBarIcon
        autostartEnabled = LaunchdManager.shared.isEnabled()
        AppLogger.shared.info("AppModel init")
        StartupLogger.write("AppModel init")
        appState.start()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.showSetupWizardIfNeeded()
            let shouldShowRestore = AppConfig.shared.model.firstLaunch || !self.menuBarVisible
            if shouldShowRestore {
                self.showRestoreWindow()
            }
        }

        NotificationCenter.default.addObserver(
            forName: AppState.modelLoadingNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.isModelLoading = notification.object as? Bool ?? false
        }

        NotificationCenter.default.addObserver(
            forName: AppState.recordingStateNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.isRecording = notification.object as? Bool ?? false
        }

        NotificationCenter.default.addObserver(
            forName: TranscriptionHistory.changedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshHistory()
        }

        NotificationCenter.default.addObserver(
            forName: .textechoConfigChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let desired = AppConfig.shared.model.showMenuBarIcon
            if self.menuBarVisible != desired {
                self.applyMenuBarVisibility(desired)
            }
            self.refreshHistory()
        }

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
        let name = AppConfig.shared.model.whisperModel
        return WhisperKitTranscriber.availableModelList
            .first(where: { $0.name == name })?.displayName ?? name
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
                self?.setupWizard?.close()
                self?.setupWizard = nil
                // Wizard already loaded the model into memory inline.
                // Do NOT call preloadCurrentModel() here — it would trigger a redundant
                // second load (showing a confusing "loading model" overlay after wizard).
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
        appState.stop()
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
