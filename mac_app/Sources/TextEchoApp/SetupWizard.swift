import AppKit
import AVFoundation
import SwiftUI

final class SetupWizardController {
    private var window: NSWindow?
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func show() {
        if window == nil {
            let view = SetupWizardView(onClose: onClose)
            let hosting = NSHostingView(rootView: view)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.center()
            window.title = "TextEcho Setup"
            window.contentView = hosting
            window.isReleasedWhenClosed = false
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
    }
}

private enum WizardStep: Int, CaseIterable {
    case accessibility = 0
    case microphone = 1
    case preparing = 2
    case ready = 3
}

struct SetupWizardView: View {
    @State private var currentStep: WizardStep = .accessibility
    @State private var accessibilityTrusted: Bool = AccessibilityHelper.isTrusted()
    @State private var micStatus: AVAuthorizationStatus = MicrophoneHelper.authorizationStatus()
    @State private var timer: Timer?
    @State private var preparingStatus: String = "Starting transcription engine..."
    @State private var modelLoaded: Bool = false
    @State private var preparingStarted: Bool = false

    let onClose: () -> Void

    private var permissionsGranted: Bool {
        accessibilityTrusted && micStatus == .authorized
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Welcome to TextEcho")
                    .font(.system(size: 18, weight: .bold))

                Text(headerText)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                // Step 1: Accessibility
                permissionRow(
                    step: "1",
                    title: "Accessibility",
                    description: "Allows TextEcho to detect keyboard shortcuts and paste text.",
                    granted: accessibilityTrusted,
                    active: currentStep == .accessibility,
                    action: { openSystemPreferences(anchor: "Privacy_Accessibility") },
                    buttonLabel: "Open Accessibility Settings"
                )

                // Step 2: Microphone
                permissionRow(
                    step: "2",
                    title: "Microphone",
                    description: "Allows TextEcho to record audio for transcription.",
                    granted: micStatus == .authorized,
                    active: currentStep == .microphone,
                    action: { openSystemPreferences(anchor: "Privacy_Microphone") },
                    buttonLabel: "Open Microphone Settings"
                )

                // Step 3: Preparing
                preparingRow()

                // Step 4: Ready
                if currentStep == .ready {
                    readySection()
                }
            }
            .padding(24)

            Spacer()

            Divider()

            HStack {
                footerStatus

                Spacer()

                Button("Restart TextEcho") {
                    restartApp()
                }

                if currentStep == .ready {
                    Button("Get Started") {
                        onClose()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(16)
        }
        .frame(minWidth: 480, minHeight: 460)
        .onAppear {
            determineInitialStep()
            refreshStatus()
            timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
                refreshStatus()
                advanceIfReady()
            }
        }
        .onDisappear {
            timer?.invalidate()
        }
    }

    private var headerText: String {
        switch currentStep {
        case .accessibility, .microphone:
            return "Grant the permissions below so TextEcho can work."
        case .preparing:
            return "Setting up the transcription engine. This may take a moment on first launch."
        case .ready:
            return "You're all set! Here's how to use TextEcho."
        }
    }

    @ViewBuilder
    private var footerStatus: some View {
        switch currentStep {
        case .accessibility, .microphone:
            Text("Grant permissions above to continue")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        case .preparing:
            Text(preparingStatus)
                .font(.system(size: 12))
                .foregroundColor(.orange)
        case .ready:
            Text("TextEcho is ready")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.green)
        }
    }

    // MARK: - Step rows

    private func permissionRow(step: String, title: String, description: String, granted: Bool, active: Bool, action: @escaping () -> Void, buttonLabel: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                stepCircle(step: step, completed: granted, active: active)

                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(active || granted ? .primary : .secondary)

                Spacer()

                statusBadge(granted)
            }

            if active || granted {
                Text(description)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.leading, 30)
            }

            if active && !granted {
                Button(buttonLabel, action: action)
                    .padding(.leading, 30)
            }
        }
    }

    @ViewBuilder
    private func preparingRow() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                stepCircle(step: "3", completed: modelLoaded, active: currentStep == .preparing)

                Text("Preparing")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(currentStep.rawValue >= WizardStep.preparing.rawValue ? .primary : .secondary)

                Spacer()

                if modelLoaded {
                    statusBadge(true)
                } else if currentStep == .preparing {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if currentStep == .preparing || modelLoaded {
                Text("Downloads and loads the voice recognition model.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.leading, 30)

                if currentStep == .preparing && !modelLoaded {
                    Text(preparingStatus)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.orange)
                        .padding(.leading, 30)
                }
            }
        }
    }

    @ViewBuilder
    private func readySection() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                stepCircle(step: "4", completed: true, active: true)

                Text("Ready!")
                    .font(.system(size: 14, weight: .semibold))
            }

            VStack(alignment: .leading, spacing: 6) {
                hotkeyRow(keys: "Ctrl + D (hold)", action: "Start/stop dictation")
                hotkeyRow(keys: "Ctrl + Shift + D (hold)", action: "Dictation + LLM processing")
                hotkeyRow(keys: "Middle mouse (hold)", action: "Start/stop dictation")
                hotkeyRow(keys: "Esc", action: "Cancel recording")
            }
            .padding(.leading, 30)
            .padding(.top, 4)
        }
    }

    private func hotkeyRow(keys: String, action: String) -> some View {
        HStack(spacing: 8) {
            Text(keys)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .padding(.vertical, 2)
                .padding(.horizontal, 6)
                .background(Color.primary.opacity(0.08))
                .cornerRadius(4)

            Text(action)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Helpers

    private func stepCircle(step: String, completed: Bool, active: Bool) -> some View {
        Text(completed ? "\u{2713}" : step)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .frame(width: 22, height: 22)
            .background(completed ? Color.green : (active ? Color.accentColor : Color.gray.opacity(0.3)))
            .foregroundColor(completed || active ? .white : .secondary)
            .clipShape(Circle())
    }

    private func statusBadge(_ ok: Bool) -> some View {
        Text(ok ? "Done" : "Missing")
            .font(.system(size: 11, weight: .semibold))
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(ok ? Color.green.opacity(0.2) : Color.red.opacity(0.2))
            .cornerRadius(6)
    }

    private func determineInitialStep() {
        if !accessibilityTrusted {
            currentStep = .accessibility
        } else if micStatus != .authorized {
            currentStep = .microphone
        } else {
            currentStep = .preparing
            startPreparing()
        }
    }

    private func advanceIfReady() {
        switch currentStep {
        case .accessibility:
            if accessibilityTrusted {
                if micStatus == .authorized {
                    currentStep = .preparing
                    startPreparing()
                } else {
                    currentStep = .microphone
                }
            }
        case .microphone:
            if micStatus == .authorized {
                currentStep = .preparing
                startPreparing()
            }
        case .preparing:
            if modelLoaded {
                currentStep = .ready
            }
        case .ready:
            break
        }
    }

    private func startPreparing() {
        guard !preparingStarted else { return }
        preparingStarted = true
        preparingStatus = "Starting transcription engine..."

        DispatchQueue.global(qos: .userInitiated).async {
            let services = PythonServiceManager()
            services.ensureTranscriptionDaemon()

            // Wait for socket to appear
            let socketPath = AppConfig.shared.model.transcriptionSocket
            let socketDeadline = Date().addingTimeInterval(10.0)
            while Date() < socketDeadline {
                if UnixSocket.ping(socketPath: socketPath, command: "ping") {
                    break
                }
                Thread.sleep(forTimeInterval: 0.5)
            }

            DispatchQueue.main.async {
                self.preparingStatus = "Loading voice model..."
            }

            // Send preload command
            let _ = try? UnixSocket.request(
                socketPath: socketPath,
                header: ["command": "preload"],
                body: nil
            )

            // Poll for model_loaded
            let modelDeadline = Date().addingTimeInterval(120.0)
            while Date() < modelDeadline {
                if let response = try? UnixSocket.request(
                    socketPath: socketPath,
                    header: ["command": "status"],
                    body: nil
                ), response["model_loaded"] as? Bool == true {
                    DispatchQueue.main.async {
                        self.modelLoaded = true
                        self.preparingStatus = "Model loaded!"
                    }
                    return
                }
                Thread.sleep(forTimeInterval: 2.0)
            }

            // Timeout — still mark as done so user isn't stuck
            DispatchQueue.main.async {
                self.modelLoaded = true
                self.preparingStatus = "Ready (model will load on first use)"
            }
        }
    }

    private func refreshStatus() {
        accessibilityTrusted = AccessibilityHelper.isTrusted()
        micStatus = MicrophoneHelper.authorizationStatus()
    }

    private func openSystemPreferences(anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func restartApp() {
        let appPath = Bundle.main.bundleURL.path
        let script = """
            sleep 1
            open "\(appPath)"
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        try? process.run()
        NSApplication.shared.terminate(nil)
    }
}
