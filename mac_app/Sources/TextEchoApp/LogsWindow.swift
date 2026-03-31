import AppKit
import SwiftUI

final class LogsWindowController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let view = LogsView()
            let hosting = NSHostingView(rootView: view)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.center()
            window.title = "TextEcho Logs"
            window.contentView = hosting
            window.isReleasedWhenClosed = false
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct LogsView: View {
    @State private var logText: String = ""
    @State private var timer: Timer?
    @State private var selectedLog: LogKind = .app

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Refresh") { load() }
                Button("Clear Logs") { clearLogs() }
                Button("Open Logs Folder") { AppLogger.shared.openLogsFolder() }
                Spacer()
            }

            Picker("Log", selection: $selectedLog) {
                ForEach(LogKind.allCases, id: \.self) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            ScrollView {
                Text(logText)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding(16)
        .onAppear {
            load()
            timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
                load()
            }
        }
        .onChange(of: selectedLog) { _ in
            load()
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }

    private func load() {
        let path = selectedLog.path
        let maxBytes: UInt64 = 100 * 1024 // 100KB
        guard let handle = FileHandle(forReadingAtPath: path) else {
            logText = ""
            return
        }
        defer { try? handle.close() }
        let fileSize = handle.seekToEndOfFile()
        if fileSize > maxBytes {
            handle.seek(toFileOffset: fileSize - maxBytes)
        } else {
            handle.seek(toFileOffset: 0)
        }
        let data = handle.readDataToEndOfFile()
        logText = String(data: data, encoding: .utf8) ?? ""
    }

    private func clearLogs() {
        for path in LogKind.allCases.map(\.path) {
            try? "".write(toFile: path, atomically: true, encoding: .utf8)
        }
        load()
    }
}

private enum LogKind: CaseIterable {
    case app
    case python

    var title: String {
        switch self {
        case .app: return "App"
        case .python: return "Python"
        }
    }

    var path: String {
        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/TextEcho", isDirectory: true)
        switch self {
        case .app:
            return logsDir.appendingPathComponent("app.log").path
        case .python:
            return logsDir.appendingPathComponent("python.log").path
        }
    }
}
