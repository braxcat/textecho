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
    case activation = 2
    case customize = 3
    case ready = 4

    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .model: return "Model"
        case .activation: return "Activation"
        case .customize: return "Customize"
        case .ready: return "Ready"
        }
    }
}

struct SetupWizardView: View {
    @State private var currentStep: WizardStep = .welcome
    @State private var accessibilityTrusted: Bool = AccessibilityHelper.isTrusted()
    @State private var micStatus: AVAuthorizationStatus = MicrophoneHelper.authorizationStatus()
    @State private var timer: Timer?
    @State private var selectedEngine: String = AppConfig.shared.model.transcriptionEngine
    @State private var selectedModel: String = AppConfig.shared.model.transcriptionEngine == "whisper"
        ? AppConfig.shared.model.whisperModel : AppConfig.shared.model.parakeetModel
    @State private var downloadingModel: String? = nil
    @State private var validatingModels: Set<String> = []
    @State private var downloadedModels: Set<String> = []
    @State private var downloadError: String? = nil
    @State private var showModelPicker: Bool = false
    @State private var pendingModelSelection: String = ""  // intermediate binding for model picker sheet
    @State private var loadingModelName: String? = nil   // being loaded into memory
    @State private var modelReadyByModel: [String: Bool] = [:]  // per-model load state
    @State private var capsLockEnabled: Bool = Self.defaultActivationSelection(\.capsLockEnabled)
    @State private var mouseEnabled: Bool = Self.defaultActivationSelection(\.mouseEnabled)
    @State private var mouseMode: Int = AppConfig.shared.model.mouseMode
    @State private var keyboardEnabled: Bool = Self.defaultActivationSelection(\.keyboardEnabled)
    @State private var keyboardMode: Int = AppConfig.shared.model.keyboardMode
    @State private var dictationKey: String = Self.keyName(for: AppConfig.shared.model.dictationKeyCode)
    @State private var dictationModCtrl: Bool = AppConfig.shared.model.dictationModifiers & UInt(NSEvent.ModifierFlags.control.rawValue) != 0
    @State private var dictationModOpt: Bool = AppConfig.shared.model.dictationModifiers & UInt(NSEvent.ModifierFlags.option.rawValue) != 0
    @State private var dictationModCmd: Bool = AppConfig.shared.model.dictationModifiers & UInt(NSEvent.ModifierFlags.command.rawValue) != 0
    @State private var dictationModShift: Bool = AppConfig.shared.model.dictationModifiers & UInt(NSEvent.ModifierFlags.shift.rawValue) != 0
    @State private var llmModShift: Bool = AppConfig.shared.model.dictationLLMModifier & UInt(NSEvent.ModifierFlags.shift.rawValue) != 0
    @State private var llmModCtrl: Bool = AppConfig.shared.model.dictationLLMModifier & UInt(NSEvent.ModifierFlags.control.rawValue) != 0
    @State private var llmModOpt: Bool = AppConfig.shared.model.dictationLLMModifier & UInt(NSEvent.ModifierFlags.option.rawValue) != 0
    @State private var llmModCmd: Bool = AppConfig.shared.model.dictationLLMModifier & UInt(NSEvent.ModifierFlags.command.rawValue) != 0
    @State private var triggerButtonChoice: Int = {
        let b = AppConfig.shared.model.triggerButton
        return (b == 0 || b == 1 || b == 2) ? b : 2
    }()
    @State private var pedalEnabled: Bool = Self.defaultActivationSelection(\.pedalEnabled)
    @State private var pedalPosition: Int = AppConfig.shared.model.pedalPosition
    @State private var silenceEnabled: Bool = AppConfig.shared.model.silenceEnabled
    @State private var silenceDuration: Double = AppConfig.shared.model.silenceDuration
    @State private var llmEnabled: Bool = AppConfig.shared.model.llmEnabled
    @State private var llmAutoPaste: Bool = AppConfig.shared.model.llmAutoPaste
    @State private var llmModelID: String = AppConfig.shared.model.llmModelID
    @State private var llmDownloading: Bool = false
    @State private var llmDownloadProgress: Double = 0.0
    @State private var llmDownloadError: String? = nil
    @State private var llmModelReady: Bool = false
    @State private var idleTimeoutPreset: Int = {
        let t = AppConfig.shared.model.whisperIdleTimeout
        return [0, 3600, 14400, 28800].contains(t) ? t : -1
    }()
    @State private var customTimeoutSeconds: String = {
        let t = AppConfig.shared.model.whisperIdleTimeout
        return [0, 3600, 14400, 28800].contains(t) ? "" : "\(t)"
    }()

    let onClose: () -> Void

    private let whisperModels = WhisperKitTranscriber.availableModelList
    private let parakeetModels = ParakeetTranscriber.availableModelList
    private var curatedModels: [WhisperKitTranscriber.ModelInfo] {
        whisperModels // Used for Whisper-specific UI (model picker sheet)
    }
    private var hasSelectedActivationMethod: Bool {
        capsLockEnabled || mouseEnabled || keyboardEnabled || pedalEnabled
    }

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
                    case .activation:
                        activationStep
                    case .customize:
                        customizeStep
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
        .sheet(isPresented: $showModelPicker, onDismiss: {
            // Only commit the selection if the user explicitly tapped Select/Download inside the sheet.
            // Tapping Done without any action leaves selectedModel unchanged.
            if !pendingModelSelection.isEmpty && pendingModelSelection != selectedModel {
                selectedModel = pendingModelSelection
                startModelPreload(modelName: pendingModelSelection)
            }
            pendingModelSelection = ""
            var names = curatedModels.map(\.name)
            if !names.contains(selectedModel) { names.append(selectedModel) }
            checkCacheStatus(for: names)
        }) {
            ModelPickerView(selectedModel: $pendingModelSelection)
        }
        .onAppear {
            determineInitialStep()
            var names = curatedModels.map(\.name)
            if !names.contains(selectedModel) { names.append(selectedModel) }
            checkCacheStatus(for: names)
            timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
                refreshStatus()
            }
        }
        .onChange(of: currentStep) { step in
            if step == .model {
                var names = curatedModels.map(\.name)
                if !names.contains(selectedModel) { names.append(selectedModel) }
                checkCacheStatus(for: names)
                maybeStartPreload(for: selectedModel)
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
                    icon: "mic",
                    title: "Microphone",
                    detail: "Required to capture audio for transcription.",
                    granted: micStatus == .authorized,
                    settingsAnchor: "Privacy_Microphone"
                )

                permissionRow(
                    icon: "hand.raised",
                    title: "Accessibility",
                    detail: "Required to detect keyboard shortcuts and paste transcribed text.",
                    granted: accessibilityTrusted,
                    settingsAnchor: "Privacy_Accessibility"
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
                Text("Transcription Engine")
                    .font(.system(size: 20, weight: .bold))
                Text("Choose an engine, download a model, then select it to load.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Engine picker
            Picker("", selection: $selectedEngine) {
                Text("Parakeet (Recommended)").tag("parakeet")
                Text("Whisper (Legacy)").tag("whisper")
            }
            .pickerStyle(.segmented)
            .onChange(of: selectedEngine) { _, newEngine in
                if newEngine == "parakeet" {
                    selectedModel = AppConfig.shared.model.parakeetModel
                } else {
                    selectedModel = AppConfig.shared.model.whisperModel
                }
                downloadError = nil
            }

            if selectedEngine == "parakeet" {
                Text("Parakeet TDT by NVIDIA — 3.7x better accuracy than Whisper, faster on Apple Silicon.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            if let error = downloadError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
                    .padding(8)
                    .background(Color.red.opacity(0.08))
                    .cornerRadius(6)
            }

            if selectedEngine == "parakeet" {
                // Parakeet model list
                Text("Parakeet Models")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.bottom, 2)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(parakeetModels, id: \.name) { model in
                        modelRow(name: model.name, displayName: model.displayName,
                                 size: model.version == .v3 ? "~6 GB" : "~6 GB",
                                 detail: model.description)
                    }
                }
            } else {
                // Whisper model list
                Text("Whisper Models")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.bottom, 2)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(curatedModels, id: \.name) { model in
                        modelRow(name: model.name, displayName: model.displayName,
                                 size: sizeFromName(model.name) ?? "", detail: model.description)
                    }
                    if !curatedModels.map(\.name).contains(selectedModel) {
                        modelRow(name: selectedModel,
                                 displayName: cleanDisplayName(selectedModel),
                                 size: sizeFromName(selectedModel) ?? "",
                                 detail: "Selected from full model list")
                    }
                }
            }

            if selectedEngine == "whisper" {
                Button(action: { showModelPicker = true }) {
                    HStack(spacing: 4) {
                        Text("All models")
                            .font(.system(size: 11))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 9))
                    }
                    .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
            }

            if !(modelReadyByModel[selectedModel] ?? false) {
                Text(downloadingModel != nil
                     ? "Downloading model…"
                     : !validatingModels.isEmpty
                       ? "Validating model…"
                       : loadingModelName != nil
                         ? "Loading model into memory…"
                         : downloadedModels.isEmpty
                           ? "Download a model to get started."
                           : "Select a model to continue.")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
            }
        }
    }

    private func modelRow(name: String, displayName: String, size: String, detail: String) -> some View {
        let isSelected = selectedModel == name
        let isDownloading = downloadingModel == name
        let isValidating = validatingModels.contains(name)
        let isDownloaded = downloadedModels.contains(name)
        let isLoadingThis = loadingModelName == name
        let isReadyThis = modelReadyByModel[name] ?? false

        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(displayName).font(.system(size: 12, weight: .semibold))
                    if !size.isEmpty {
                        Text(size).font(.system(size: 10)).foregroundColor(.secondary)
                    }
                }
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 10)).foregroundColor(.secondary)
                }
                if isDownloading {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .padding(.top, 2)
                    Text("Downloading & loading model — this may take a few minutes…")
                        .font(.system(size: 9))
                        .foregroundColor(.orange)
                    DownloadElapsedTimer()
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                if isReadyThis {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 10))
                        Text("Selected").font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundColor(.accentColor)
                } else if isLoadingThis {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("Loading into memory…").font(.system(size: 10)).foregroundColor(.secondary)
                    }
                } else if isDownloaded {
                    Button("Select") {
                        selectedModel = name
                        startModelPreload(modelName: name)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(loadingModelName != nil)
                } else if isValidating {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("Validating…").font(.system(size: 10)).foregroundColor(.secondary)
                    }
                } else if !isDownloading {
                    Button("Download") {
                        startModelDownload(modelName: name)
                    }
                    .buttonStyle(.bordered)
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
    }

    private var activationStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("How to Activate")
                    .font(.system(size: 20, weight: .bold))
                Text("Choose how to trigger voice recording. You can enable multiple methods at once.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Caps Lock
            activationOptionCard(
                icon: "lock",
                title: "Caps Lock",
                detail: "Press Caps Lock to start recording. Press again to stop.",
                enabled: $capsLockEnabled
            ) {
                EmptyView()
            }

            // Mouse
            activationOptionCard(
                icon: "computermouse",
                title: "Mouse Button",
                detail: "Click or hold a mouse button to record.",
                enabled: $mouseEnabled
            ) {
                if mouseEnabled {
                    HStack {
                        Text("Button")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Spacer()
                        Picker("", selection: $triggerButtonChoice) {
                            Text("Left").tag(0)
                            Text("Right").tag(1)
                            Text("Middle").tag(2)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 180)
                    }
                    HStack {
                        Text("Mode")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Spacer()
                        Picker("", selection: $mouseMode) {
                            Text("Toggle").tag(0)
                            Text("Hold").tag(1)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 180)
                    }
                }
            }

            // Keyboard
            activationOptionCard(
                icon: "keyboard",
                title: "Keyboard Shortcut",
                detail: "Press a keyboard shortcut to start recording.",
                enabled: $keyboardEnabled
            ) {
                if keyboardEnabled {
                    HStack {
                        Text("Key")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Spacer()
                        TextField("Z", text: $dictationKey)
                            .frame(width: 44)
                            .multilineTextAlignment(.center)
                    }
                    HStack {
                        Text("Modifiers")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Spacer()
                        HStack(spacing: 8) {
                            Toggle("⌃", isOn: $dictationModCtrl)
                            Toggle("⌥", isOn: $dictationModOpt)
                            Toggle("⌘", isOn: $dictationModCmd)
                            Toggle("⇧", isOn: $dictationModShift)
                        }
                    }
                    HStack {
                        Text("Mode")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Spacer()
                        Picker("", selection: $keyboardMode) {
                            Text("Toggle").tag(0)
                            Text("Hold").tag(1)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 180)
                    }
                    HStack {
                        Text("LLM Extra Modifier")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Spacer()
                        HStack(spacing: 8) {
                            Toggle("⌃", isOn: $llmModCtrl)
                            Toggle("⌥", isOn: $llmModOpt)
                            Toggle("⌘", isOn: $llmModCmd)
                            Toggle("⇧", isOn: $llmModShift)
                        }
                    }
                    Text("LLM modifier is added on top of the main shortcut to trigger LLM mode.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }

            // Stream Deck Pedal
            activationOptionCard(
                icon: "pedal.accelerator",
                title: "Stream Deck Pedal",
                detail: "Use an Elgato Stream Deck Pedal to control recording.",
                enabled: $pedalEnabled
            ) {
                if pedalEnabled {
                    HStack {
                        Text("Push-to-talk pedal")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Spacer()
                        Picker("", selection: $pedalPosition) {
                            Text("Left").tag(0)
                            Text("Center").tag(1)
                            Text("Right").tag(2)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 180)
                    }
                    Text("Left = Paste, Center = Push-to-talk, Right = Enter")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }

            if !hasSelectedActivationMethod {
                Text("Enable at least one activation method to use TextEcho.")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
            }
        }
    }

    private var customizeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Customize")
                    .font(.system(size: 20, weight: .bold))
                Text("Set your recording behavior and model memory. You can always change these later in Settings.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Stop on silence", isOn: $silenceEnabled)
                    .font(.system(size: 14, weight: .semibold))
                Text("Automatically stop recording after a period of silence.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if silenceEnabled {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Silence Timeout")
                            .font(.system(size: 14, weight: .semibold))
                        Text("How long to wait after you stop speaking before recording auto-stops and transcription begins.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 12) {
                            Slider(value: $silenceDuration, in: 0.5...10.0, step: 0.5)
                            Text(String(format: "%.1fs", silenceDuration))
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .frame(width: 40)
                        }

                        Text(silenceDuration <= 1.5
                             ? "Short — good for quick commands and single sentences."
                             : silenceDuration <= 3.0
                                 ? "Default — works well for most dictation."
                                 : "Long — good for pausing to think mid-sentence.")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Model Memory")
                    .font(.system(size: 14, weight: .semibold))
                Text("The transcription model uses ~1.6GB RAM when loaded. Choose how long it stays in memory after your last transcription.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("Unload after", selection: $idleTimeoutPreset) {
                    Text("Never (always ready)").tag(0)
                    Text("1 hour").tag(3600)
                    Text("4 hours").tag(14400)
                    Text("8 hours").tag(28800)
                    Text("Custom").tag(-1)
                }
                .pickerStyle(.menu)

                if idleTimeoutPreset == -1 {
                    HStack {
                        Text("Seconds:")
                            .font(.system(size: 12))
                        TextField("e.g. 7200", text: $customTimeoutSeconds)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                    }
                }

                Text(idleTimeoutPreset == 0
                    ? "Model stays loaded permanently — transcription is always instant."
                    : "Model unloads after inactivity to free RAM. Next transcription may take a few seconds to reload.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            // MARK: - LLM (AI Assistant)
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Enable AI Assistant (LLM)", isOn: $llmEnabled)
                    .font(.system(size: 14, weight: .semibold))
                Text("Ask questions by voice — hold Shift while recording. TextEcho transcribes your question, sends it to a local AI model, and shows the answer. Everything runs on your Mac, nothing leaves your device.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if llmEnabled {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("AI Model")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Choose a model based on your Mac's RAM. Larger models give better answers but need more memory.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Picker("Model", selection: $llmModelID) {
                            ForEach(recommendedLLMModels, id: \.id) { model in
                                VStack(alignment: .leading) {
                                    Text(model.displayName)
                                }
                                .tag(model.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .disabled(llmDownloading)
                        .onChange(of: llmModelID) {
                            // Reset state when user picks a different model
                            llmModelReady = false
                            llmDownloadError = nil
                        }

                        if let selected = recommendedLLMModels.first(where: { $0.id == llmModelID }) {
                            Text("\(selected.description) — ~\(String(format: "%.1f", selected.sizeGB)) GB download")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        // Download / status
                        if llmModelReady {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text("Model ready")
                                    .font(.system(size: 12))
                                    .foregroundColor(.green)
                            }
                        } else if llmDownloading {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(llmDownloadProgress < 1.0 ? "Downloading..." : "Compiling model...")
                                        .font(.system(size: 12, weight: .medium))
                                    Spacer()
                                    if llmDownloadProgress < 1.0 {
                                        Text("\(Int(llmDownloadProgress * 100))%")
                                            .font(.system(size: 12, design: .monospaced))
                                            .foregroundColor(.secondary)
                                    }
                                }
                                ProgressView(value: min(llmDownloadProgress, 1.0))
                                    .progressViewStyle(.linear)
                            }
                            .padding(.vertical, 4)
                        } else {
                            Button("Download & Load Model") {
                                startLLMDownload()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }

                        if let error = llmDownloadError {
                            Text(error)
                                .font(.system(size: 10))
                                .foregroundColor(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Divider().padding(.vertical, 4)

                        Text("After Recording")
                            .font(.system(size: 13, weight: .semibold))
                        Text("When the AI responds, should TextEcho paste it automatically or let you review it first?")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Picker("", selection: $llmAutoPaste) {
                            Text("Auto-paste — response is pasted immediately").tag(true)
                            Text("Review first — press Enter to paste, Esc to dismiss").tag(false)
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()

                        Text(llmAutoPaste
                            ? "The AI response will be pasted into the active app right away."
                            : "You'll see the response in a floating overlay. Press Enter to paste it, or Esc to dismiss.")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, 4)
                }
            }
        }
    }

    @ViewBuilder
    private func activationOptionCard<Extra: View>(
        icon: String,
        title: String,
        detail: String,
        enabled: Binding<Bool>,
        @ViewBuilder extra: () -> Extra
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .frame(width: 22, height: 22)
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("", isOn: enabled)
                    .labelsHidden()
            }
            if enabled.wrappedValue {
                extra()
                    .padding(.leading, 32)
            }
        }
        .padding(12)
        .background(enabled.wrappedValue ? Color.accentColor.opacity(0.05) : Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(enabled.wrappedValue ? Color.accentColor.opacity(0.3) : Color.gray.opacity(0.15), lineWidth: 1)
        )
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
                if keyboardEnabled {
                    hotkeyRow(keys: formattedMainShortcut(), action: "Keyboard shortcut")
                }
                if mouseEnabled {
                    let buttonName = triggerButtonChoice == 0 ? "Left click" : triggerButtonChoice == 1 ? "Right click" : "Middle click"
                    let modeStr = mouseMode == 1 ? " (hold)" : " (toggle)"
                    hotkeyRow(keys: buttonName, action: "Mouse button" + modeStr)
                }
                if capsLockEnabled {
                    hotkeyRow(keys: "Caps Lock", action: "Toggle recording with Caps Lock")
                }
                if pedalEnabled {
                    let pedalName = pedalPosition == 0 ? "Left pedal" : pedalPosition == 2 ? "Right pedal" : "Center pedal"
                    hotkeyRow(keys: pedalName, action: "Stream Deck Pedal (push-to-talk)")
                }
            }

            if llmEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    Text("AI Assistant")
                        .font(.system(size: 12, weight: .semibold))
                    if let model = recommendedLLMModels.first(where: { $0.id == llmModelID }) {
                        hotkeyRow(keys: "Shift + trigger", action: "Ask AI (\(model.displayName))")
                    } else {
                        hotkeyRow(keys: "Shift + trigger", action: "Ask AI")
                    }
                    hotkeyRow(keys: llmAutoPaste ? "Auto-paste" : "Enter / Esc", action: llmAutoPaste ? "Response pasted automatically" : "Review before pasting")
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Other")
                    .font(.system(size: 12, weight: .semibold))
                hotkeyRow(keys: "Esc", action: "Cancel recording")
                hotkeyRow(keys: "Cmd + Opt + Space", action: "Open Settings")
            }

            Text("TextEcho lives in your menu bar. Click the icon to access Settings, Help, and more.")
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
                Button("Next") {
                    currentStep = .model
                }
                .buttonStyle(.borderedProminent)

            case .model:
                Button("Next") {
                    AppConfig.shared.update { model in
                        model.transcriptionEngine = selectedEngine
                        if selectedEngine == "whisper" {
                            model.whisperModel = selectedModel
                        } else {
                            model.parakeetModel = selectedModel
                        }
                    }
                    currentStep = .activation
                }
                .buttonStyle(.borderedProminent)
                .disabled(!(modelReadyByModel[selectedModel] ?? false))

            case .activation:
                Button("Next") {
                    saveActivationConfig()
                    currentStep = .customize
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasSelectedActivationMethod)

            case .customize:
                Button("Next") {
                    saveCustomizeConfig()
                    currentStep = .ready
                }
                .buttonStyle(.borderedProminent)

            case .ready:
                Button("Start Using TextEcho") {
                    AppConfig.shared.update { model in
                        model.firstLaunch = false
                        model.transcriptionEngine = selectedEngine
                        if selectedEngine == "whisper" {
                            model.whisperModel = selectedModel
                        } else {
                            model.parakeetModel = selectedModel
                        }
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
        case .activation: currentStep = .model
        case .customize: currentStep = .activation
        case .ready: currentStep = .customize
        }
    }

    private func saveActivationConfig() {
        let dictationMods = buildModifierMask(
            ctrl: dictationModCtrl,
            opt: dictationModOpt,
            cmd: dictationModCmd,
            shift: dictationModShift
        )
        let llmMods = buildModifierMask(
            ctrl: llmModCtrl,
            opt: llmModOpt,
            cmd: llmModCmd,
            shift: llmModShift
        )
        AppConfig.shared.update { model in
            model.capsLockEnabled = capsLockEnabled
            model.mouseEnabled = mouseEnabled
            model.mouseMode = mouseMode
            model.keyboardEnabled = keyboardEnabled
            model.keyboardMode = keyboardMode
            model.triggerButton = triggerButtonChoice
            model.pedalEnabled = pedalEnabled
            model.pedalPosition = pedalPosition
            if let keyCode = Self.keyCode(for: dictationKey) {
                model.dictationKeyCode = keyCode
            }
            model.dictationModifiers = dictationMods
            model.dictationLLMModifier = llmMods
        }
    }

    private func saveCustomizeConfig() {
        let timeout: Int
        if idleTimeoutPreset == -1 {
            timeout = Int(customTimeoutSeconds) ?? 3600
        } else {
            timeout = idleTimeoutPreset
        }
        AppConfig.shared.update { model in
            model.silenceEnabled = silenceEnabled
            model.silenceDuration = silenceDuration
            model.whisperIdleTimeout = timeout
            model.llmEnabled = llmEnabled
            model.llmAutoPaste = llmAutoPaste
            model.llmModelID = llmModelID
        }
    }

    private func buildModifierMask(ctrl: Bool, opt: Bool, cmd: Bool, shift: Bool) -> UInt {
        var mask: UInt = 0
        if ctrl { mask |= UInt(NSEvent.ModifierFlags.control.rawValue) }
        if opt { mask |= UInt(NSEvent.ModifierFlags.option.rawValue) }
        if cmd { mask |= UInt(NSEvent.ModifierFlags.command.rawValue) }
        if shift { mask |= UInt(NSEvent.ModifierFlags.shift.rawValue) }
        return mask
    }

    private func formattedMainShortcut() -> String {
        let modifiers: [(Bool, String)] = [
            (dictationModCtrl, "⌃"),
            (dictationModOpt, "⌥"),
            (dictationModCmd, "⌘"),
            (dictationModShift, "⇧"),
        ]
        let symbols = modifiers.filter { $0.0 }.map { $0.1 }.joined()
        let key = dictationKey.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if key.isEmpty { return symbols.isEmpty ? "No shortcut set" : symbols }
        return symbols + key
    }

    private static func keyCode(for input: String) -> Int? {
        guard let char = input.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().first else {
            return nil
        }
        let map: [Character: Int] = [
            "A": 0, "S": 1, "D": 2, "F": 3, "H": 4, "G": 5,
            "Z": 6, "X": 7, "C": 8, "V": 9, "B": 11,
            "Q": 12, "W": 13, "E": 14, "R": 15, "Y": 16, "T": 17,
            "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
            "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
            "]": 30, "O": 31, "U": 32, "[": 33, "I": 34, "P": 35,
            "L": 37, "J": 38, "'": 39, "K": 40, ";": 41,
            "\\": 42, ",": 43, "/": 44, "N": 45, "M": 46,
            ".": 47, "`": 50
        ]
        return map[char]
    }

    private static func keyName(for keyCode: Int) -> String {
        let map: [Int: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G",
            6: "Z", 7: "X", 8: "C", 9: "V", 11: "B",
            12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
            18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
            24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
            37: "L", 38: "J", 39: "'", 40: "K", 41: ";",
            42: "\\", 43: ",", 44: "/", 45: "N", 46: "M",
            47: ".", 50: "`"
        ]
        return map[keyCode] ?? "Z"
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
        let hasCachedModel: Bool
        if selectedEngine == "parakeet" {
            hasCachedModel = parakeetModels.contains(where: { ParakeetTranscriber.isModelCached($0.name) })
        } else {
            hasCachedModel = whisperModels.contains(where: { WhisperKitTranscriber.isModelCached($0.name) })
        }
        currentStep = hasCachedModel ? .welcome : .model
    }

    private func refreshStatus() {
        accessibilityTrusted = AccessibilityHelper.isTrusted()
        micStatus = MicrophoneHelper.authorizationStatus()
    }

    private func checkCacheStatus(for modelNames: [String]) {
        for name in modelNames {
            let isCached: Bool
            if selectedEngine == "parakeet" {
                isCached = ParakeetTranscriber.isModelCached(name)
            } else {
                isCached = WhisperKitTranscriber.isModelCached(name)
            }
            guard isCached else { continue }
            guard !downloadedModels.contains(name) && !validatingModels.contains(name) else { continue }

            if selectedEngine == "parakeet" {
                // FluidAudio models don't need validation — if cached, they're valid
                downloadedModels.insert(name)
                if name == selectedModel { maybeStartPreload(for: name) }
            } else {
                validatingModels.insert(name)
                Task {
                    let isValid = await WhisperKitTranscriber.validateModel(name)
                    await MainActor.run {
                        validatingModels.remove(name)
                        if isValid {
                            downloadedModels.insert(name)
                            if name == selectedModel { maybeStartPreload(for: name) }
                        }
                    }
                }
            }
        }
    }

    /// Start preloading into memory if the model is downloaded and not already loading/ready.
    private func maybeStartPreload(for modelName: String) {
        guard downloadedModels.contains(modelName) else { return }
        guard !(modelReadyByModel[modelName] ?? false) else { return }
        guard loadingModelName == nil else { return }
        startModelPreload(modelName: modelName)
    }

    private func startModelPreload(modelName: String) {
        loadingModelName = modelName
        Task {
            do {
                if selectedEngine == "parakeet" {
                    var transcriber: ParakeetTranscriber? = ParakeetTranscriber(
                        modelName: modelName,
                        idleTimeout: AppConfig.shared.model.whisperIdleTimeout
                    )
                    try await transcriber?.preload()
                    transcriber = nil
                } else {
                    var transcriber: WhisperKitTranscriber? = WhisperKitTranscriber(
                        modelName: modelName,
                        idleTimeout: AppConfig.shared.model.whisperIdleTimeout
                    )
                    try await transcriber?.preload()
                    transcriber = nil
                }
                await MainActor.run {
                    loadingModelName = nil
                    modelReadyByModel[modelName] = true
                }
            } catch {
                await MainActor.run {
                    loadingModelName = nil
                    downloadError = "Model failed to load: \(error.localizedDescription)"
                }
                AppLogger.shared.error("Wizard model preload failed: \(error)")
            }
        }
    }

    private func cleanDisplayName(_ name: String) -> String {
        var n = name
        for prefix in ["openai_whisper-", "distil-whisper_"] {
            if n.hasPrefix(prefix) { n = String(n.dropFirst(prefix.count)); break }
        }
        if let last = n.components(separatedBy: "_").last,
           last.hasSuffix("MB") || last.hasSuffix("GB") {
            n = String(n.dropLast(last.count + 1))
        }
        return n
    }

    private func sizeFromName(_ name: String) -> String? {
        guard let last = name.components(separatedBy: "_").last,
              last.hasSuffix("MB") || last.hasSuffix("GB") else { return nil }
        return last
    }

    private func startModelDownload(modelName: String) {
        downloadingModel = modelName
        downloadError = nil
        // Use .detached to avoid inheriting @MainActor — heavy download + model
        // init must not block the UI thread.
        Task.detached(priority: .userInitiated) {
            do {
                if await self.selectedEngine == "parakeet" {
                    // FluidAudio handles download + load in one call
                    let transcriber = ParakeetTranscriber(
                        modelName: modelName,
                        idleTimeout: AppConfig.shared.model.whisperIdleTimeout
                    )
                    try await transcriber.preload()
                    await MainActor.run {
                        self.downloadingModel = nil
                        self.downloadedModels.insert(modelName)
                        self.modelReadyByModel[modelName] = true
                        self.selectedModel = modelName
                    }
                } else {
                    let transcriber = WhisperKitTranscriber(
                        modelName: modelName,
                        idleTimeout: AppConfig.shared.model.whisperIdleTimeout
                    )
                    try await transcriber.preload()
                    await MainActor.run {
                        self.downloadingModel = nil
                        self.validatingModels.insert(modelName)
                    }
                    let isValid = await WhisperKitTranscriber.validateModel(modelName)
                    await MainActor.run {
                        self.validatingModels.remove(modelName)
                        if isValid {
                            self.downloadedModels.insert(modelName)
                            self.modelReadyByModel[modelName] = true
                            self.selectedModel = modelName
                        } else {
                            self.downloadError = "Download completed but validation failed. Try again."
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.downloadingModel = nil
                    self.downloadError = "Download failed: \(error.localizedDescription)"
                }
                AppLogger.shared.error("Setup wizard model download failed: \(error)")
            }
        }
    }

    private func startLLMDownload() {
        llmDownloading = true
        llmDownloadProgress = 0.0
        llmDownloadError = nil
        let modelID = llmModelID
        Task.detached(priority: .userInitiated) {
            do {
                let processor = MLXLLMProcessor()
                try await processor.loadModel(id: modelID) { progress in
                    Task { @MainActor in
                        self.llmDownloadProgress = progress
                    }
                }
                await MainActor.run {
                    self.llmDownloading = false
                    self.llmModelReady = true
                }
            } catch {
                await MainActor.run {
                    self.llmDownloading = false
                    self.llmDownloadError = "Download failed: \(error.localizedDescription)"
                }
                AppLogger.shared.error("LLM model download failed: \(error)")
            }
        }
    }

    private func openSystemPreferences(anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func defaultActivationSelection(_ keyPath: KeyPath<AppConfig.Model, Bool>) -> Bool {
        let model = AppConfig.shared.model
        return model.firstLaunch ? false : model[keyPath: keyPath]
    }
}

/// Shows elapsed time during model download so the user knows it's not frozen.
private struct DownloadElapsedTimer: View {
    @State private var elapsed: Int = 0
    @State private var timer: Timer?

    var body: some View {
        Text("Elapsed: \(elapsed / 60)m \(elapsed % 60)s")
            .font(.system(size: 9, design: .monospaced))
            .foregroundColor(.secondary)
            .onAppear {
                elapsed = 0
                timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                    elapsed += 1
                }
            }
            .onDisappear {
                timer?.invalidate()
                timer = nil
            }
    }
}
