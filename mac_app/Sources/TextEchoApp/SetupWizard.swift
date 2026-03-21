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
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 580),
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
    case model = 1
    case ready = 2

    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .model: return "Model"
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
    @State private var validatingModels: Set<String> = []
    @State private var downloadedModels: Set<String> = []
    @State private var downloadError: String? = nil
    @State private var showModelPicker: Bool = false

    let onClose: () -> Void

    private let curatedModels = WhisperKitTranscriber.availableModelList

    var body: some View {
        VStack(spacing: 0) {
            progressDots
                .padding(.top, 20)
                .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch currentStep {
                    case .welcome:
                        welcomeStep
                    case .model:
                        modelStep
                    case .ready:
                        readyStep
                    }
                }
                .padding(28)
            }

            Spacer(minLength: 0)

            Divider()

            navigationBar
                .padding(16)
        }
        .frame(minWidth: 500, minHeight: 540)
        .sheet(isPresented: $showModelPicker) {
            ModelPickerView(selectedModel: $selectedModel)
                .onDisappear {
                    checkCacheStatus(for: curatedModels.map(\.name))
                }
        }
        .onAppear {
            determineInitialStep()
            checkCacheStatus(for: curatedModels.map(\.name))
            timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
                refreshStatus()
            }
        }
        .onChange(of: currentStep) { step in
            if step == .model {
                checkCacheStatus(for: curatedModels.map(\.name))
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
        if step.rawValue < currentStep.rawValue { return .green }
        if step == currentStep { return .accentColor }
        return Color.gray.opacity(0.3)
    }

    // MARK: - Step views

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Welcome to TextEcho")
                    .font(.system(size: 24, weight: .bold))
                Text("Voice-to-text dictation that runs entirely on your Mac.")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                featureRow(icon: "waveform", title: "Local Transcription", detail: "Powered by WhisperKit on Apple Neural Engine. No cloud, fully offline after setup.")
                featureRow(icon: "keyboard", title: "Push-to-Talk", detail: "Hold a key or mouse button, speak, release to paste text wherever your cursor is.")
                featureRow(icon: "lock.shield", title: "Private by Design", detail: "Audio never leaves your Mac. No accounts, no data collection.")
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text("Permissions")
                    .font(.system(size: 14, weight: .semibold))

                permissionRow(
                    icon: "hand.raised",
                    title: "Accessibility",
                    detail: "Required to detect keyboard shortcuts and paste transcribed text.",
                    granted: accessibilityTrusted,
                    settingsAnchor: "Privacy_Accessibility"
                )

                permissionRow(
                    icon: "mic",
                    title: "Microphone",
                    detail: "Required to capture audio for transcription.",
                    granted: micStatus == .authorized,
                    settingsAnchor: "Privacy_Microphone"
                )

                if !accessibilityTrusted || micStatus != .authorized {
                    Text("Grant the permissions above before using TextEcho. You can also continue and grant them later.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private func featureRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .frame(width: 24, height: 24)
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func permissionRow(icon: String, title: String, detail: String, granted: Bool, settingsAnchor: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .font(.system(size: 18))
                .foregroundColor(granted ? .green : .orange)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    statusBadge(granted)
                }
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !granted {
                    Button("Open Settings") {
                        openSystemPreferences(anchor: settingsAnchor)
                    }
                    .font(.system(size: 11))
                    .padding(.top, 2)
                }
            }
        }
        .padding(10)
        .background(granted ? Color.green.opacity(0.04) : Color.orange.opacity(0.04))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(granted ? Color.green.opacity(0.2) : Color.orange.opacity(0.2), lineWidth: 1)
        )
    }

    private var modelStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Transcription Model")
                    .font(.system(size: 20, weight: .bold))
                Text("Download a model to enable transcription. Stored locally for offline use.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = downloadError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
                    .padding(8)
                    .background(Color.red.opacity(0.08))
                    .cornerRadius(6)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(curatedModels, id: \.name) { model in
                    modelRow(model: model)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: WhisperKitTranscriber.downloadProgressNotification)) { _ in }

            Button(action: { showModelPicker = true }) {
                HStack(spacing: 4) {
                    Text("Other models")
                        .font(.system(size: 11))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9))
                }
                .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)

            if downloadedModels.isEmpty && validatingModels.isEmpty && downloadingModel == nil {
                Text("Download at least one model to continue.")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
            }
        }
    }

    private func modelRow(model: WhisperKitTranscriber.ModelInfo) -> some View {
        let isSelected = selectedModel == model.name
        let isDownloading = downloadingModel == model.name
        let isValidating = validatingModels.contains(model.name)
        let isDownloaded = downloadedModels.contains(model.name)

        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                .foregroundColor(isSelected ? .accentColor : .secondary)
                .font(.system(size: 16))
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(model.displayName).font(.system(size: 12, weight: .semibold))
                    Text(model.size).font(.system(size: 10)).foregroundColor(.secondary)
                }
                Text(model.description).font(.system(size: 10)).foregroundColor(.secondary)
                if isDownloading {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .padding(.top, 2)
                    Text("Downloading...")
                        .font(.system(size: 9))
                        .foregroundColor(.orange)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                if isDownloaded {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 10))
                        Text("Downloaded").font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundColor(.green)
                } else if isValidating {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("Validating...").font(.system(size: 10)).foregroundColor(.secondary)
                    }
                } else if !isDownloading {
                    Button("Download") {
                        selectedModel = model.name
                        startModelDownload(modelName: model.name)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(downloadingModel != nil)
                }
            }
        }
        .padding(10)
        .background(isSelected ? Color.accentColor.opacity(0.06) : Color.clear)
        .cornerRadius(7)
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(isSelected ? Color.accentColor.opacity(0.35) : Color.gray.opacity(0.15), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { selectedModel = model.name }
    }

    private var readyStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.green)
                Text("You're All Set!")
                    .font(.system(size: 20, weight: .bold))
            }

            Text("TextEcho is ready to use.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("Recording")
                    .font(.system(size: 12, weight: .semibold))
                hotkeyRow(keys: "Ctrl + D", action: "Toggle recording via keyboard")
                hotkeyRow(keys: "Middle mouse", action: "Toggle recording via mouse")
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Other")
                    .font(.system(size: 12, weight: .semibold))
                hotkeyRow(keys: "Esc", action: "Cancel recording")
                hotkeyRow(keys: "Cmd + Opt + Space", action: "Open Settings")
                hotkeyRow(keys: "Cmd + Opt + 1–9", action: "Save clipboard to register")
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
                Button("Back") { goBack() }
            }

            Spacer()

            switch currentStep {
            case .welcome:
                Button("Get Started") {
                    currentStep = .model
                }
                .buttonStyle(.borderedProminent)

            case .model:
                Button("Next") {
                    AppConfig.shared.update { model in
                        model.whisperModel = selectedModel
                    }
                    currentStep = .ready
                }
                .buttonStyle(.borderedProminent)
                .disabled(downloadedModels.isEmpty && validatingModels.isEmpty)

            case .ready:
                Button("Start Using TextEcho") {
                    AppConfig.shared.update { model in
                        model.firstLaunch = false
                        model.whisperModel = selectedModel
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
        case .model: currentStep = .welcome
        case .ready: currentStep = .model
        }
    }

    // MARK: - Shared components

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
            .font(.system(size: 10, weight: .semibold))
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .background(ok ? Color.green.opacity(0.2) : Color.red.opacity(0.2))
            .foregroundColor(ok ? .green : .red)
            .cornerRadius(4)
    }

    // MARK: - Logic

    private func determineInitialStep() {
        if !curatedModels.contains(where: { WhisperKitTranscriber.isModelCached($0.name) }) {
            currentStep = .model
        } else {
            currentStep = .welcome
        }
    }

    private func refreshStatus() {
        accessibilityTrusted = AccessibilityHelper.isTrusted()
        micStatus = MicrophoneHelper.authorizationStatus()
    }

    private func checkCacheStatus(for modelNames: [String]) {
        for name in modelNames {
            guard WhisperKitTranscriber.isModelCached(name) else { continue }
            guard !downloadedModels.contains(name) && !validatingModels.contains(name) else { continue }
            validatingModels.insert(name)
            Task {
                let isValid = await WhisperKitTranscriber.validateModel(name)
                await MainActor.run {
                    validatingModels.remove(name)
                    if isValid { downloadedModels.insert(name) }
                }
            }
        }
    }

    private func startModelDownload(modelName: String) {
        downloadingModel = modelName
        downloadError = nil
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
}
