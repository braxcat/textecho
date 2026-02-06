import Foundation

final class LaunchdManager {
    static let shared = LaunchdManager()

    private let label = "com.textecho.app"

    func isEnabled() -> Bool {
        let plist = launchAgentPath()
        return FileManager.default.fileExists(atPath: plist.path)
    }

    func enable() {
        let plist = launchAgentPath()
        let executable = Bundle.main.executablePath ?? ""
        let launchAgentsDir = plist.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)
        let contents: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "KeepAlive": false
        ]

        do {
            let data = try PropertyListSerialization.data(fromPropertyList: contents, format: .xml, options: 0)
            try data.write(to: plist)
            _ = runLaunchctl(["bootstrap", "gui/\(getuid())", plist.path])
        } catch {
            AppLogger.shared.error("Failed to enable autostart: \(error)")
        }
    }

    func disable() {
        let plist = launchAgentPath()
        _ = runLaunchctl(["bootout", "gui/\(getuid())", plist.path])
        try? FileManager.default.removeItem(at: plist)
    }

    private func launchAgentPath() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    private func runLaunchctl(_ args: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            AppLogger.shared.error("launchctl error: \(error)")
            return false
        }
    }
}
