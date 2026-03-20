import Foundation

/// Manages the optional Python LLM daemon process.
/// Transcription is now handled natively by WhisperKit — this class only manages LLM.
final class PythonServiceManager {
    private var llmProcess: Process?

    deinit {
        stopAll()
    }

    func ensureLLMDaemon() {
        guard AppConfig.shared.model.llmEnabled else { return }
        guard AppConfig.shared.model.llmAvailable else {
            AppLogger.shared.info("LLM module not installed — skipping daemon launch")
            return
        }
        if UnixSocket.ping(socketPath: AppConfig.shared.model.llmSocket, command: "ping") {
            return
        }
        startLLM()
    }

    func stopAll() {
        llmProcess?.terminate()
        llmProcess = nil
    }

    private func startLLM() {
        guard llmProcess == nil else { return }
        guard let script = ScriptLocator.locate(name: "llm_daemon.py") else {
            AppLogger.shared.error("Could not locate LLM daemon script")
            return
        }
        cleanStaleSocket(path: AppConfig.shared.model.llmSocket)
        llmProcess = launchPython(scriptPath: script)
    }

    private func launchPython(scriptPath: String) -> Process? {
        let process = Process()
        let pythonPath = AppConfig.shared.model.pythonPath
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = ["-u", scriptPath]
        var env = ProcessInfo.processInfo.environment

        // Ensure Homebrew paths are in PATH so dependencies are found.
        let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin"]
        let currentPath = env["PATH"] ?? "/usr/bin:/bin"
        let missingPaths = extraPaths.filter { !currentPath.contains($0) }
        if !missingPaths.isEmpty {
            env["PATH"] = (missingPaths + [currentPath]).joined(separator: ":")
        }

        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let cachesDir = homeDir.appendingPathComponent("Library/Caches/TextEcho", isDirectory: true)
        try? FileManager.default.createDirectory(at: cachesDir, withIntermediateDirectories: true)
        let cachePath = cachesDir.path
        env["XDG_CACHE_HOME"] = cachePath
        env["PYTHONPYCACHEPREFIX"] = cachePath + "/__pycache__"
        env["HF_HOME"] = cachePath + "/hf"
        env["TRANSFORMERS_CACHE"] = cachePath + "/hf"
        env["HOME"] = homeDir.path
        env["TMPDIR"] = cachePath + "/tmp"
        env["PYTHONUNBUFFERED"] = "1"
        process.environment = env
        process.currentDirectoryURL = homeDir

        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/TextEcho", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let logURL = logsDir.appendingPathComponent("python.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let logHandle = try? FileHandle(forWritingTo: logURL)
        logHandle?.seekToEndOfFile()
        process.standardOutput = logHandle
        process.standardError = logHandle
        process.terminationHandler = { [weak self] proc in
            AppLogger.shared.error("Python LLM daemon exited (status=\(proc.terminationStatus), reason=\(proc.terminationReason.rawValue))")
            try? logHandle?.close()
            guard let self else { return }
            if self.llmProcess === proc {
                self.llmProcess = nil
            }
        }

        do {
            try process.run()
            AppLogger.shared.info("Python executable: \(pythonPath)")
            AppLogger.shared.info("Started LLM daemon: \(scriptPath)")
            return process
        } catch {
            AppLogger.shared.error("Failed to start LLM daemon: \(error)")
            return nil
        }
    }

    private func cleanStaleSocket(path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        if !UnixSocket.ping(socketPath: path, command: "status") {
            try? FileManager.default.removeItem(atPath: path)
            AppLogger.shared.info("Removed stale socket: \(path)")
        }
    }
}

enum ScriptLocator {
    static func locate(name: String) -> String? {
        let configDir = AppConfig.shared.model.daemonScriptsDir
        if !configDir.isEmpty {
            let path = (configDir as NSString).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        if let resourcePath = Bundle.main.resourcePath {
            let path = (resourcePath as NSString).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        let cwd = FileManager.default.currentDirectoryPath
        let path = (cwd as NSString).appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: path) {
            return path
        }

        return nil
    }
}
