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
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 620),
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
    case model = 2
    case ready = 3
}

struct SetupWizardView: View {
    @State private var currentStep: WizardStep = .accessibility
    @State private var accessibilityTrusted: Bool = AccessibilityHelper.isTrusted()
    @State private var micStatus: AVAuthorizationStatus = MicrophoneHelper.authorizationStatus()
    @State private var timer: Timer?
    @State private var modelStatus: String = "Waiting..."
    @State private var modelLoaded: Bool = false
    @State private var downloadStarted: Bool = false
    @State private var selectedModel: String = AppConfig.shared.model.whisperModel

    let onClose: () -> Void

    private var permissionsGranted: Bool {
        accessibilityTrusted && micStatus == .authorized
    }

    private let models = WhisperKitTranscriber.availableModelList

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

                // Step 3: Model download
                modelRow()

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
        .frame(minWidth: 480, minHeight: 520)
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
        case .model:
            return "Choose and download a transcription model. This only happens once."
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
        case .model:
            Text(modelStatus)
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
    private func modelRow() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                stepCircle(step: "3", completed: modelLoaded, active: currentStep == .model)

                Text("Transcription Model")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(currentStep.rawValue >= WizardStep.model.rawValue ? .primary : .secondary)

                Spacer()

                if modelLoaded {
                    statusBadge(true)
                } else if currentStep == .model && downloadStarted {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if currentStep == .model || modelLoaded {
                if !modelLoaded && currentStep == .model {
                    // Model picker cards
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(models, id: \.name) { model in
                            modelCard(model: model, isSelected: selectedModel == model.name)
                                .onTapGesture {
                                    selectedModel = model.name
                                }
                        }
                    }
                    .padding(.leading, 30)
                    .padding(.top, 4)

                    if !downloadStarted {
                        Button("Download & Continue") {
                            startModelDownload()
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.leading, 30)
                        .padding(.top, 4)
                    } else {
                        Text(modelStatus)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.orange)
                            .padding(.leading, 30)
                    }
                } else {
                    Text("Model ready: \(selectedModel)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(.leading, 30)
                }

                Text("You can change this later in Settings.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .padding(.leading, 30)
            }
        }
    }

    private func modelCard(model: WhisperKitTranscriber.ModelInfo, isSelected: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(model.displayName)
                        .font(.system(size: 12, weight: .semibold))
                    if model.name == "large-v3-turbo" {
                        Text("Recommended")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.2))
                            .cornerRadius(3)
                    }
                    if WhisperKitTranscriber.isModelCached(model.name) {
                        Text("Cached")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.green)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.green.opacity(0.15))
                            .cornerRadius(3)
                    }
                }
                Text("\(model.size) — \(model.description)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundColor(isSelected ? .accentColor : .secondary)
        }
        .padding(8)
        .background(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.accentColor.opacity(0.3) : Color.gray.opacity(0.2), lineWidth: 1)
        )
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
            currentStep = .model
            // If model already cached, auto-advance
            if WhisperKitTranscriber.isModelCached(selectedModel) {
                modelLoaded = true
                modelStatus = "Model ready"
                currentStep = .ready
            }
        }
    }

    private func advanceIfReady() {
        switch currentStep {
        case .accessibility:
            if accessibilityTrusted {
                if micStatus == .authorized {
                    currentStep = .model
                    if WhisperKitTranscriber.isModelCached(selectedModel) {
                        modelLoaded = true
                        modelStatus = "Model ready"
                        currentStep = .ready
                    }
                } else {
                    currentStep = .microphone
                }
            }
        case .microphone:
            if micStatus == .authorized {
                currentStep = .model
                if WhisperKitTranscriber.isModelCached(selectedModel) {
                    modelLoaded = true
                    modelStatus = "Model ready"
                    currentStep = .ready
                }
            }
        case .model:
            if modelLoaded {
                currentStep = .ready
            }
        case .ready:
            break
        }
    }

    private func startModelDownload() {
        downloadStarted = true
        modelStatus = "Downloading and loading model..."

        // Save selected model to config
        AppConfig.shared.update { model in
            model.whisperModel = selectedModel
        }

        Task {
            let transcriber = WhisperKitTranscriber(
                modelName: selectedModel,
                idleTimeout: AppConfig.shared.model.whisperIdleTimeout
            )
            do {
                try await transcriber.preload()
                await MainActor.run {
                    self.modelLoaded = true
                    self.modelStatus = "Model loaded!"
                }
            } catch {
                await MainActor.run {
                    // Still mark as done so user isn't stuck — model will load on first use
                    self.modelLoaded = true
                    self.modelStatus = "Ready (model will load on first use)"
                }
                AppLogger.shared.error("Setup wizard model preload failed: \(error.localizedDescription)")
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
