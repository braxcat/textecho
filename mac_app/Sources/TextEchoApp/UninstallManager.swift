import AppKit
import Foundation

@MainActor
final class UninstallManager {
    static let shared = UninstallManager()

    private init() {}

    func requestUninstall(appState: AppState) {
        let alert = NSAlert()
        alert.messageText = "Uninstall TextEcho?"
        alert.informativeText = "This will stop background services, disable launch-on-login, and remove logs and config files. You will still need to remove macOS permissions manually."
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Uninstall & Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            performUninstall(appState: appState, moveToTrash: false)
        case .alertSecondButtonReturn:
            confirmMoveToTrash(appState: appState)
        default:
            break
        }
    }

    private func performUninstall(appState: AppState, moveToTrash: Bool) {
        appState.stop()
        LaunchdManager.shared.disable()
        cleanupFiles()
        if moveToTrash {
            moveAppToTrash()
        }
        openPermissionSettings()
        NSApplication.shared.terminate(nil)
    }

    private func cleanupFiles() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        let configFile = home.appendingPathComponent(".textecho_config")
        try? fm.removeItem(at: configFile)

        let logsDir = home.appendingPathComponent("Library/Logs/TextEcho", isDirectory: true)
        try? fm.removeItem(at: logsDir)

        let sockets = [
            "/tmp/textecho_transcription.sock",
            "/tmp/textecho_llm.sock",
            "/tmp/textecho-start.log"
        ]
        for path in sockets {
            try? fm.removeItem(atPath: path)
        }
    }

    private func openPermissionSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        ]

        for urlString in urls {
            if let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func moveAppToTrash() {
        let fm = FileManager.default
        let appURL = Bundle.main.bundleURL
        do {
            _ = try fm.trashItem(at: appURL, resultingItemURL: nil)
        } catch {
            AppLogger.shared.warn("Failed to move app to Trash: \(error)")
        }
    }

    private func confirmMoveToTrash(appState: AppState) {
        let confirm = NSAlert()
        confirm.messageText = "Move TextEcho to Trash?"
        confirm.informativeText = "This will remove the app bundle from disk."
        confirm.addButton(withTitle: "Move to Trash")
        confirm.addButton(withTitle: "Cancel")
        confirm.alertStyle = .warning
        let response = confirm.runModal()
        if response == .alertFirstButtonReturn {
            performUninstall(appState: appState, moveToTrash: true)
        }
    }
}
