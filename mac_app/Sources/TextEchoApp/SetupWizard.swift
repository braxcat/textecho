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
                contentRect: NSRect(x: 0, y: 0, width: 540, height: 640),
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
    case welcome = 0
    case accessibility = 1
    case microphone = 2
    case model = 3
    case pedal = 4
    case ready = 5

    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .accessibility: return "Accessibility"
        case .microphone: return "Microphone"
        case .model: return "Model"
        case .pedal: return "Pedal"
        case .ready: return "Ready"
        }
    }
}

struct SetupWizardView: View {
    @State private var currentStep: WizardStep = .welcome
    @State private var accessibilityTrusted: Bool = AccessibilityHelper.isTrusted()
    @State private var micStatus: AVAuthorizationStatus = MicrophoneHelper.authorizationStatus()
    @State private var timer: Timer?
    @State private var selectedModel: String = AppConfig.shared.model.whisperModel
    @State private var downloadingModel: String? = nil
    @State private var downloadProgress: Double = 0.0
    @State private var validatingModels: Set<String> = []
    @State private var downloadedModels: Set<String> = []
    @State private var downloadError: String? = nil
    @State private var pedalDetected: Bool = false
    @State private var pedalEnabled: Bool = AppConfig.shared.model.pedalEnabled
    @State private var pedalScanning: Bool = false

    let onClose: () -> Void

    private let models = WhisperKitTranscriber.availableModelList

    var body: some View {
        VStack(spacing: 0) {
            // Progress dots
            progressDots
                .padding(.top, 20)
                .padding(.bottom, 12)

            Divider()

            // Step content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch currentStep {
                    case .welcome:
                        welcomeStep
                    case .accessibility:
                        accessibilityStep
                    case .microphone:
                        microphoneStep
                    case .model:
                        modelStep
                    case .pedal:
                        pedalStep
                    case .ready:
                        readyStep
                    }
                }
                .padding(28)
            }

            Spacer()

            Divider()

            // Navigation buttons
            navigationBar
                .padding(16)
        }
        .frame(minWidth: 500, minHeight: 560)
        .onAppear {
            // Skip to first incomplete step
            determineInitialStep()
            checkInitialModelStatus()
            timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
                refreshStatus()
            }
        }
        .onChange(of: currentStep) { step in
            if step == .model {
                checkInitialModelStatus()
            }
        }
        .onDisappear {
            timer?.invalidate()
        }
    }

    // MARK: - Progress dots

    private var progressDots: some View {
        HStack(spacing: 8) {
            ForEach(WizardStep.allCases, id: \.rawValue) { step in
                VStack(spacing: 4) {
                    Circle()
                        .fill(dotColor(for: step))
                        .frame(width: 10, height: 10)
                        .overlay(
                            step.rawValue < currentStep.rawValue
                                ? Image(systemName: "checkmark")
                                    .font(.system(size: 6, weight: .bold))
                                    .foregroundColor(.white)
                                : nil
                        )

                    Text(step.title)
                        .font(.system(size: 9))
                        .foregroundColor(step == currentStep ? .primary : .secondary)
                }
            }
        }
    }

    private func dotColor(for step: WizardStep) -> Color {
        if step.rawValue < currentStep.rawValue {
            return .green
        } else if step == currentStep {
            return .accentColor
        } else {
            return Color.gray.opacity(0.3)
        }
    }

    // MARK: - Step views

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Welcome to TextEcho")
                .font(.system(size: 24, weight: .bold))

            Text("Voice-to-text dictation that runs entirely on your Mac.")
                .font(.system(size: 14))
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                featureRow(icon: "waveform", title: "Local Transcription", detail: "Powered by WhisperKit on Apple Neural Engine. No cloud, fully offline after setup.")
                featureRow(icon: "keyboard", title: "Push-to-Talk", detail: "Hold a key or mouse button, speak, release to paste text wherever your cursor is.")
                featureRow(icon: "lock.shield", title: "Private by Design", detail: "Audio never leaves your Mac. No accounts, no data collection.")
            }
            .padding(.top, 8)

            Text("Let's set you up in a few quick steps.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .padding(.top, 8)
        }
    }

    private func featureRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .frame(width: 24, height: 24)
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var accessibilityStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeader(title: "Accessibility Permission", icon: "hand.raised")

            Text("TextEcho needs Accessibility access to detect keyboard shortcuts and paste transcribed text into other apps.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("Status:")
                    .font(.system(size: 13))
                statusBadge(accessibilityTrusted)
            }

            if !accessibilityTrusted {
                Text("Click the button below, find TextEcho in the list, and enable it.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                Button("Open Accessibility Settings") {
                    openSystemPreferences(anchor: "Privacy_Accessibility")
                }
                .buttonStyle(.borderedProminent)

                Text("After enabling, TextEcho may need a restart for the change to take effect.")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
            } else {
                Text("Accessibility permission granted.")
                    .font(.system(size: 13))
                    .foregroundColor(.green)
            }
        }
    }

    private var microphoneStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeader(title: "Microphone Permission", icon: "mic")

            Text("TextEcho needs microphone access to record audio for transcription.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("Status:")
                    .font(.system(size: 13))
                statusBadge(micStatus == .authorized)
            }

            if micStatus != .authorized {
                Button("Open Microphone Settings") {
                    openSystemPreferences(anchor: "Privacy_Microphone")
                }
                .buttonStyle(.borderedProminent)
            } else {
                Text("Microphone permission granted.")
                    .font(.system(size: 13))
                    .foregroundColor(.green)
            }
        }
    }

    private var modelStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeader(title: "Transcription Model", icon: "brain")

            Text("Download a model to enable transcription. This only happens once — models are stored locally for offline use.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(models, id: \.name) { model in
                    modelCard(model: model)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: WhisperKitTranscriber.downloadProgressNotification)) { notification in
                if let progress = notification.object as? Double {
                    downloadProgress = progress
                }
            }

            if let error = downloadError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
                    .padding(.top, 4)
            }

            if downloadedModels.isEmpty && validatingModels.isEmpty && downloadingModel == nil {
                Text("Download at least one model to continue.")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
            }

            Text("You can download additional models later in Settings.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }

    private var pedalStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeader(title: "Stream Deck Pedal", icon: "gamecontroller")

            Text("Do you have an Elgato Stream Deck Pedal? TextEcho can use it for hands-free push-to-talk.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if pedalDetected {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Stream Deck Pedal detected!")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.green)
                }

                VStack(alignment: .leading, spacing: 6) {
                    pedalActionRow(position: "Left pedal", action: "Paste (Cmd+V)")
                    pedalActionRow(position: "Center pedal", action: "Push-to-talk")
                    pedalActionRow(position: "Right pedal", action: "Enter")
                }
                .padding(.leading, 4)

                Toggle("Enable Stream Deck Pedal", isOn: $pedalEnabled)
                    .onChange(of: pedalEnabled) { newValue in
                        AppConfig.shared.update { model in
                            model.pedalEnabled = newValue
                        }
                    }
            } else {
                HStack(spacing: 8) {
                    if pedalScanning {
                        ProgressView()
                            .controlSize(.small)
                        Text("Scanning for pedal...")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    } else {
                        Image(systemName: "xmark.circle")
                            .foregroundColor(.secondary)
                        Text("No pedal detected")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                }

                Text("Make sure the pedal is plugged in via USB and the Elgato Stream Deck app is quit.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Scan Again") {
                    pedalScanning = true
                    // The timer will pick up the connection
                }
            }

            Text("You can skip this step if you don't have a pedal.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }

    private func pedalActionRow(position: String, action: String) -> some View {
        HStack(spacing: 8) {
            Text(position)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .frame(width: 100, alignment: .leading)
                .padding(.vertical, 2)
                .padding(.horizontal, 6)
                .background(Color.primary.opacity(0.08))
                .cornerRadius(4)

            Text(action)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    private var readyStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeader(title: "You're All Set!", icon: "checkmark.seal")

            Text("TextEcho is ready to use. Here's how:")
                .font(.system(size: 13))
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("Recording")
                    .font(.system(size: 12, weight: .semibold))
                hotkeyRow(keys: "Middle mouse (hold)", action: "Push-to-talk via mouse")
                if pedalEnabled {
                    hotkeyRow(keys: "Center pedal (hold)", action: "Push-to-talk via pedal")
                    hotkeyRow(keys: "Left pedal", action: "Paste")
                    hotkeyRow(keys: "Right pedal", action: "Enter")
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Other")
                    .font(.system(size: 12, weight: .semibold))
                hotkeyRow(keys: "Esc", action: "Cancel recording")
                hotkeyRow(keys: "Cmd + Opt + Space", action: "Open Settings")
                hotkeyRow(keys: "Cmd + Opt + 1-9", action: "Save clipboard to register")
            }

            Text("TextEcho lives in your menu bar. Right-click the icon for Settings, Help, and more.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        }
    }

    // MARK: - Navigation

    private var navigationBar: some View {
        HStack {
            if currentStep != .welcome {
                Button("Back") {
                    goBack()
                }
            }

            Spacer()

            if currentStep == .accessibility && !accessibilityTrusted {
                Button("Restart TextEcho") {
                    restartApp()
                }
            }

            switch currentStep {
            case .welcome:
                Button("Get Started") {
                    currentStep = .accessibility
                }
                .buttonStyle(.borderedProminent)

            case .accessibility:
                Button("Next") {
                    currentStep = .microphone
                }
                .buttonStyle(.borderedProminent)
                .disabled(!accessibilityTrusted)

            case .microphone:
                Button("Next") {
                    currentStep = .model
                }
                .buttonStyle(.borderedProminent)
                .disabled(micStatus != .authorized)

            case .model:
                Button("Next") {
                    currentStep = .pedal
                    pedalScanning = true
                    checkPedalConnection()
                }
                .buttonStyle(.borderedProminent)
                .disabled(downloadedModels.isEmpty)

            case .pedal:
                Button(pedalDetected ? "Next" : "Skip") {
                    currentStep = .ready
                }
                .buttonStyle(.borderedProminent)

            case .ready:
                Button("Start Using TextEcho") {
                    AppConfig.shared.update { model in
                        model.firstLaunch = false
                    }
                    onClose()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func goBack() {
        switch currentStep {
        case .welcome: break
        case .accessibility: currentStep = .welcome
        case .microphone: currentStep = .accessibility
        case .model: currentStep = .microphone
        case .pedal: currentStep = .model
        case .ready: currentStep = .pedal
        }
    }

    // MARK: - Shared components

    private func stepHeader(title: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(.accentColor)
                .frame(width: 28)

            Text(title)
                .font(.system(size: 20, weight: .bold))
        }
    }

    private func modelCard(model: WhisperKitTranscriber.ModelInfo) -> some View {
        let isDownloading = downloadingModel == model.name
        let isValidating = validatingModels.contains(model.name)
        let isDownloaded = downloadedModels.contains(model.name)
        let isFirst = model.name == WhisperKitTranscriber.availableModelList.first?.name

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(model.displayName)
                            .font(.system(size: 12, weight: .semibold))
                        if isFirst {
                            Text("Recommended")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.2))
                                .cornerRadius(3)
                        }
                    }
                    Text("\(model.size) — \(model.description)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                Spacer()

                if isDownloaded {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.green)
                        Text("Downloaded")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.green)
                    }
                } else if isValidating {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Validating...")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                } else if !isDownloading {
                    Button("Download") {
                        startModelDownload(modelName: model.name)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(downloadingModel != nil)
                }
            }

            if isDownloading {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .padding(.top, 2)
                    Text("Downloading \(model.size)...")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                }
            }
        }
        .padding(10)
        .background(isDownloaded ? Color.green.opacity(0.05) : Color.clear)
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(
                    isDownloaded ? Color.green.opacity(0.3) : Color.gray.opacity(0.2),
                    lineWidth: 1
                )
        )
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

    private func statusBadge(_ ok: Bool) -> some View {
        Text(ok ? "Granted" : "Missing")
            .font(.system(size: 11, weight: .semibold))
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(ok ? Color.green.opacity(0.2) : Color.red.opacity(0.2))
            .cornerRadius(6)
    }

    // MARK: - Logic

    private func determineInitialStep() {
        if !AppConfig.shared.model.firstLaunch {
            // Re-opened from menu — start at welcome but allow quick navigation
            currentStep = .welcome
            return
        }
        if !accessibilityTrusted {
            currentStep = .accessibility
        } else if micStatus != .authorized {
            currentStep = .microphone
        } else if !WhisperKitTranscriber.availableModelList.contains(where: { WhisperKitTranscriber.isModelCached($0.name) }) {
            currentStep = .model
        } else {
            currentStep = .ready
        }
    }

    private func refreshStatus() {
        accessibilityTrusted = AccessibilityHelper.isTrusted()
        micStatus = MicrophoneHelper.authorizationStatus()
        if currentStep == .pedal && pedalScanning {
            checkPedalConnection()
        }
    }

    private func checkPedalConnection() {
        // Check if a Stream Deck Pedal is visible on USB
        let devices = StreamDeckPedalMonitor.detectConnectedPedals()
        pedalDetected = !devices.isEmpty
        if pedalDetected {
            pedalScanning = false
            pedalEnabled = true
            AppConfig.shared.update { model in
                model.pedalEnabled = true
            }
        }
    }

    private func checkInitialModelStatus() {
        for model in models {
            guard WhisperKitTranscriber.isModelCached(model.name) else { continue }
            guard !downloadedModels.contains(model.name) && !validatingModels.contains(model.name) else { continue }
            validatingModels.insert(model.name)
            Task {
                let isValid = await WhisperKitTranscriber.validateModel(model.name)
                await MainActor.run {
                    validatingModels.remove(model.name)
                    if isValid {
                        downloadedModels.insert(model.name)
                    }
                }
            }
        }
    }

    private func startModelDownload(modelName: String) {
        downloadingModel = modelName
        downloadProgress = 0.0
        downloadError = nil
        selectedModel = modelName

        AppConfig.shared.update { model in
            model.whisperModel = modelName
        }

        Task {
            let transcriber = WhisperKitTranscriber(
                modelName: modelName,
                idleTimeout: AppConfig.shared.model.whisperIdleTimeout
            )
            do {
                try await transcriber.preload()
            } catch {
                await MainActor.run {
                    self.downloadingModel = nil
                    self.downloadError = "Download failed: \(error.localizedDescription)"
                }
                AppLogger.shared.error("Setup wizard model download failed: \(error)")
                return
            }

            await MainActor.run {
                self.downloadingModel = nil
                self.validatingModels.insert(modelName)
            }

            let isValid = await WhisperKitTranscriber.validateModel(modelName)

            await MainActor.run {
                self.validatingModels.remove(modelName)
                if isValid {
                    self.downloadedModels.insert(modelName)
                } else {
                    self.downloadError = "Download completed but validation failed. Try again."
                }
            }
        }
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
