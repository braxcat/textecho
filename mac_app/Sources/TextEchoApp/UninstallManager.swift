import AppKit
import Foundation

@MainActor
final class UninstallManager {
    static let shared = UninstallManager()

    private init() {}

    func requestUninstall(appState: AppState) {
        Task { @MainActor in
            let (cacheURLs, cacheSizeString) = await Self.fetchCacheInfo()
            showUninstallAlert(appState: appState, cacheURLs: cacheURLs, cacheSizeString: cacheSizeString)
        }
    }

    // MARK: - Private

    @MainActor
    private func showUninstallAlert(appState: AppState, cacheURLs: [URL], cacheSizeString: String?) {
        let alert = NSAlert()
        alert.messageText = "Uninstall TextEcho?"
        alert.informativeText = "This will stop background services, disable launch-on-login, and remove logs and config files. You will still need to remove macOS permissions manually."
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Uninstall & Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        // Show cache checkbox only when caches exist
        var cacheCheckbox: NSButton?
        if let sizeString = cacheSizeString {
            let checkbox = NSButton(checkboxWithTitle: "Also delete transcription model caches (\(sizeString))", target: nil, action: nil)
            checkbox.state = .on
            alert.accessoryView = checkbox
            cacheCheckbox = checkbox
        }

        let response = alert.runModal()
        let deleteCaches = cacheCheckbox?.state == .on

        switch response {
        case .alertFirstButtonReturn:
            performUninstall(appState: appState, moveToTrash: false, cacheURLs: deleteCaches ? cacheURLs : [])
        case .alertSecondButtonReturn:
            confirmMoveToTrash(appState: appState, cacheURLs: deleteCaches ? cacheURLs : [])
        default:
            break
        }
    }

    @MainActor
    private func performUninstall(appState: AppState, moveToTrash: Bool, cacheURLs: [URL]) {
        appState.stop()
        LaunchdManager.shared.disable()
        cleanupFiles(cacheURLs: cacheURLs)
        if moveToTrash {
            moveAppToTrash()
        }
        openPermissionSettings()
        NSApplication.shared.terminate(nil)
    }

    private func cleanupFiles(cacheURLs: [URL]) {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        let configFile = home.appendingPathComponent(".textecho_config")
        try? fm.removeItem(at: configFile)

        let themesFile = home.appendingPathComponent(".textecho_themes.json")
        try? fm.removeItem(at: themesFile)

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

        for url in cacheURLs {
            do {
                try fm.removeItem(at: url)
                AppLogger.shared.info("Removed model cache: \(url.path)")
            } catch {
                AppLogger.shared.warn("Failed to remove model cache \(url.path): \(error)")
            }
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

    private func confirmMoveToTrash(appState: AppState, cacheURLs: [URL]) {
        let confirm = NSAlert()
        confirm.messageText = "Move TextEcho to Trash?"
        confirm.informativeText = "This will remove the app bundle from disk."
        confirm.addButton(withTitle: "Move to Trash")
        confirm.addButton(withTitle: "Cancel")
        confirm.alertStyle = .warning
        let response = confirm.runModal()
        if response == .alertFirstButtonReturn {
            performUninstall(appState: appState, moveToTrash: true, cacheURLs: cacheURLs)
        }
    }

    // MARK: - Cache info

    /// Returns the list of existing cache directories and a human-readable combined size string.
    /// Returns nil for the size string if no cache directories exist.
    private nonisolated static func fetchCacheInfo() async -> ([URL], String?) {
        return await Task.detached(priority: .utility) {
            let fm = FileManager.default
            var urls: [URL] = []

            for dir in WhisperKitTranscriber.modelCacheDirectories() {
                if fm.fileExists(atPath: dir.path) {
                    urls.append(dir)
                }
            }

            let parakeetDir = ParakeetTranscriber.modelCacheDirectory(for: .v3)
            if fm.fileExists(atPath: parakeetDir.path) && !urls.contains(parakeetDir) {
                urls.append(parakeetDir)
            }

            guard !urls.isEmpty else { return ([], nil) }

            let totalBytes = urls.reduce(Int64(0)) { $0 + Self.directorySize(at: $1) }
            let sizeString = Self.formatBytes(totalBytes)
            return (urls, sizeString)
        }.value
    }

    private nonisolated static func directorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var size: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                size += Int64(fileSize)
            }
        }
        return size
    }

    private nonisolated static func formatBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / (1024 * 1024 * 1024)
        if gb >= 0.1 {
            return String(format: "%.1f GB", gb)
        }
        let mb = Double(bytes) / (1024 * 1024)
        return String(format: "%.0f MB", mb)
    }
}
