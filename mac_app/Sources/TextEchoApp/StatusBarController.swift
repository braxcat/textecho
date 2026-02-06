import AppKit

final class StatusBarController {
    var onStartRecording: ((RecordingMode) -> Void)?
    var onStopRecording: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onOpenLogs: (() -> Void)?
    var onToggleAutostart: ((Bool) -> Void)?
    var onQuit: (() -> Void)?

    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    private let autostartItem = NSMenuItem(title: "Launch on Login", action: #selector(toggleAutostart), keyEquivalent: "")
    private var autostartEnabled = false

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.isVisible = true
        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "TextEcho") {
                button.image = image
            } else {
                button.title = "TextEcho"
            }
        }

        menu.autoenablesItems = false

        let recordItem = NSMenuItem(title: "Start Recording", action: #selector(startRecording), keyEquivalent: "")
        let recordLLMItem = NSMenuItem(title: "Start LLM Recording", action: #selector(startLLMRecording), keyEquivalent: "")
        let stopItem = NSMenuItem(title: "Stop Recording", action: #selector(stopRecording), keyEquivalent: "")
        stopItem.isEnabled = true

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        let logsItem = NSMenuItem(title: "Open Logs", action: #selector(openLogs), keyEquivalent: "")
        let quitItem = NSMenuItem(title: "Quit TextEcho", action: #selector(quit), keyEquivalent: "q")

        autostartItem.state = .off

        menu.addItem(recordItem)
        menu.addItem(recordLLMItem)
        menu.addItem(stopItem)
        menu.addItem(.separator())
        menu.addItem(settingsItem)
        menu.addItem(logsItem)
        menu.addItem(.separator())
        menu.addItem(autostartItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    func setAutostartEnabled(_ enabled: Bool) {
        autostartEnabled = enabled
        autostartItem.state = enabled ? .on : .off
    }

    @objc private func startRecording() {
        onStartRecording?(.standard)
    }

    @objc private func startLLMRecording() {
        onStartRecording?(.llm)
    }

    @objc private func stopRecording() {
        onStopRecording?()
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    @objc private func openLogs() {
        onOpenLogs?()
    }

    @objc private func toggleAutostart() {
        autostartEnabled.toggle()
        onToggleAutostart?(autostartEnabled)
    }

    @objc private func quit() {
        onQuit?()
    }
}
