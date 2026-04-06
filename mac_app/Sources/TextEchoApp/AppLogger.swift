import AppKit
import Foundation

final class AppLogger {
    static let shared = AppLogger()

    private let logFileURL: URL
    private let queue = DispatchQueue(label: "textecho.logger")

    private init() {
        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/TextEcho", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        logFileURL = logsDir.appendingPathComponent("app.log")
    }

    func info(_ message: String) {
        write(level: "INFO", message: message)
    }

    func warn(_ message: String) {
        write(level: "WARN", message: message)
    }

    func error(_ message: String) {
        write(level: "ERROR", message: message)
    }

    private func write(level: String, message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] [\(level)] \(message)\n"
        queue.async {
            self.rotateIfNeeded()
            if let data = line.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: self.logFileURL.path) {
                    if let handle = try? FileHandle(forWritingTo: self.logFileURL) {
                        _ = try? handle.seekToEnd()
                        handle.write(data)
                        try? handle.close()
                    }
                } else {
                    try? data.write(to: self.logFileURL)
                    // Restrict log file to owner-only — logs may contain dictated text.
                    try? FileManager.default.setAttributes(
                        [.posixPermissions: 0o600], ofItemAtPath: self.logFileURL.path)
                }
            }
        }
    }

    private func rotateIfNeeded() {
        let maxSize: UInt64 = 5 * 1024 * 1024 // 5MB
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
              let fileSize = attrs[.size] as? UInt64,
              fileSize > maxSize else {
            return
        }
        let oldURL = logFileURL.deletingPathExtension().appendingPathExtension("old.log")
        try? FileManager.default.removeItem(at: oldURL)
        try? FileManager.default.moveItem(at: logFileURL, to: oldURL)
    }

    func openLogsFolder() {
        let folder = logFileURL.deletingLastPathComponent()
        NSWorkspace.shared.open(folder)
    }

    func logFilePath() -> String {
        return logFileURL.path
    }
}
