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
        MenuBarExtra("TextEcho", systemImage: appModel.isModelLoading ? "hourglass" : "waveform", isInserted: menuBarInserted) {
            Button("Start Recording") {
                appModel.startRecording(llm: false)
            }

            Button("Start LLM Recording") {
                appModel.startRecording(llm: true)
            }

            Button("Stop Recording") {
                appModel.stopRecording()
            }

            Divider()

            Button("Settings…") {
                appModel.openSettings()
            }

            Button("Open Logs") {
                appModel.openLogs()
            }

            Button("Help") {
                appModel.openHelp()
            }

            Button("Setup Wizard…") {
                appModel.openSetupWizard()
            }

            Divider()

            Toggle(
                "Launch on Login",
                isOn: Binding(
                    get: { appModel.autostartEnabled },
                    set: { appModel.setAutostartEnabled($0) }
                )
            )

            Toggle(
                "Show Menu Bar Icon",
                isOn: Binding(
                    get: { appModel.menuBarVisible },
                    set: { appModel.setMenuBarVisible($0) }
                )
            )

            Divider()

            Button("Uninstall…") {
                appModel.uninstall()
            }

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

    private let appState = AppState()
    private var restoreWindow: RestoreWindowController?
    private var setupWizard: SetupWizardController?
    private var helpWindow: HelpWindowController?

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
            forName: .textechoConfigChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let desired = AppConfig.shared.model.showMenuBarIcon
            if self.menuBarVisible != desired {
                self.applyMenuBarVisibility(desired)
            }
        }
    }

    func startRecording(llm: Bool) {
        appState.beginRecording(mode: llm ? .llm : .standard)
    }

    func stopRecording() {
        appState.endRecording(userInitiated: true)
    }

    func openSettings() {
        appState.openSettings()
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
                // Wizard sets firstLaunch=false and whisperModel before calling onClose.
                // Now preload AppState's transcriber (model is on disk, CoreML cache is warm).
                self?.appState.preloadCurrentModel()
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
