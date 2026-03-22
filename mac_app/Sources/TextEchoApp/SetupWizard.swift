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
    @State private var selectedModel: String = AppConfig.shared.model.whisperModel
    @State private var downloadingModel: String? = nil
    @State private var validatingModels: Set<String> = []
    @State private var downloadedModels: Set<String> = []
    @State private var downloadError: String? = nil
    @State private var showModelPicker: Bool = false
    @State private var loadingModelName: String? = nil   // being loaded into memory
    @State private var modelReady: Bool = false           // selected model is loaded & ready
    @State private var capsLockEnabled: Bool = AppConfig.shared.model.capsLockEnabled
    @State private var mouseEnabled: Bool = AppConfig.shared.model.mouseEnabled
    @State private var mouseMode: Int = AppConfig.shared.model.mouseMode
    @State private var keyboardEnabled: Bool = AppConfig.shared.model.keyboardEnabled
    @State private var keyboardMode: Int = AppConfig.shared.model.keyboardMode
    @State private var triggerButtonChoice: Int = {
        let b = AppConfig.shared.model.triggerButton
        return (b == 0 || b == 1 || b == 2) ? b : 2
    }()
    @State private var pedalEnabled: Bool = AppConfig.shared.model.pedalEnabled
    @State private var pedalPosition: Int = AppConfig.shared.model.pedalPosition
    @State private var themePreset: String = AppConfig.shared.model.themePreset
    @State private var idleTimeoutPreset: Int = {
        let t = AppConfig.shared.model.whisperIdleTimeout
        return [0, 3600, 14400, 28800].contains(t) ? t : -1
    }()
    @State private var customTimeoutSeconds: String = {
        let t = AppConfig.shared.model.whisperIdleTimeout
        return [0, 3600, 14400, 28800].contains(t) ? "" : "\(t)"
    }()

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
            // Re-check cache status for all curated models plus any non-curated
            // model that may have been downloaded inside ModelPickerView.
            var names = curatedModels.map(\.name)
            if !names.contains(selectedModel) { names.append(selectedModel) }
            checkCacheStatus(for: names)
        }) {
            ModelPickerView(selectedModel: $selectedModel)
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
        .onChange(of: selectedModel) { _ in
            // Reset ready state when selection changes.
            // Preload is triggered explicitly by the "Select" button.
            modelReady = false
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
                Text("Transcription Model")
                    .font(.system(size: 20, weight: .bold))
                Text("Download a model, then select it to load it into memory.")
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

            Text("Recommended Models")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.bottom, 2)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(curatedModels, id: \.name) { model in
                    modelRow(name: model.name, displayName: model.displayName,
                             size: sizeFromName(model.name) ?? "", detail: model.description)
                }
                // Show a non-curated model if it was selected via "Other models"
                if !curatedModels.map(\.name).contains(selectedModel) {
                    modelRow(name: selectedModel,
                             displayName: cleanDisplayName(selectedModel),
                             size: sizeFromName(selectedModel) ?? "",
                             detail: "Selected from full model list")
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: WhisperKitTranscriber.downloadProgressNotification)) { _ in }

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

            if !modelReady {
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
        let isReadyThis = modelReady && selectedModel == name

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
                    Text("Downloading…")
                        .font(.system(size: 9))
                        .foregroundColor(.orange)
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
                detail: "Use a keyboard shortcut (configurable in Settings — default ⌃⌥Z).",
                enabled: $keyboardEnabled
            ) {
                if keyboardEnabled {
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

            if !capsLockEnabled && !mouseEnabled && !keyboardEnabled && !pedalEnabled {
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
                Text("Set your preferred theme and model memory behavior. You can always change these later in Settings.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Theme
            VStack(alignment: .leading, spacing: 8) {
                Text("Overlay Theme")
                    .font(.system(size: 14, weight: .semibold))
                Text("Choose how the recording overlay looks.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                let allPresets = ["textecho", "cyber", "classic", "ocean", "sunset"]
                ForEach(allPresets, id: \.self) { name in
                    themeOptionRow(name: name, selected: themePreset == name) {
                        themePreset = name
                    }
                }
            }

            Divider()

            // Idle Timeout
            VStack(alignment: .leading, spacing: 8) {
                Text("Model Memory")
                    .font(.system(size: 14, weight: .semibold))
                Text("The transcription model uses ~1.6GB RAM when loaded. Choose how long it stays in memory after your last transcription. \"Never\" keeps it loaded for instant response.")
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
        }
    }

    private func themeOptionRow(name: String, selected: Bool, action: @escaping () -> Void) -> some View {
        let descriptions: [String: String] = [
            "textecho": "Bright cyan-blue — the original look",
            "cyber": "Teal-green cyberpunk",
            "classic": "Clean grey",
            "ocean": "Deep blue",
            "sunset": "Warm orange-red"
        ]
        return Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "circle.inset.filled" : "circle")
                    .font(.system(size: 14))
                    .foregroundColor(selected ? .accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name.capitalized)
                        .font(.system(size: 12, weight: .semibold))
                    Text(descriptions[name] ?? "")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(8)
            .background(selected ? Color.accentColor.opacity(0.06) : Color.clear)
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(selected ? Color.accentColor.opacity(0.35) : Color.gray.opacity(0.15), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
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
                    hotkeyRow(keys: "⌃⌥Z", action: "Keyboard shortcut (configurable in Settings)")
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
                        model.whisperModel = selectedModel
                    }
                    currentStep = .activation
                }
                .buttonStyle(.borderedProminent)
                .disabled(!modelReady)

            case .activation:
                Button("Next") {
                    saveActivationConfig()
                    currentStep = .customize
                }
                .buttonStyle(.borderedProminent)
                .disabled(!capsLockEnabled && !mouseEnabled && !keyboardEnabled && !pedalEnabled)

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
        case .activation: currentStep = .model
        case .customize: currentStep = .activation
        case .ready: currentStep = .customize
        }
    }

    private func saveActivationConfig() {
        AppConfig.shared.update { model in
            model.capsLockEnabled = capsLockEnabled
            model.mouseEnabled = mouseEnabled
            model.mouseMode = mouseMode
            model.keyboardEnabled = keyboardEnabled
            model.keyboardMode = keyboardMode
            model.triggerButton = triggerButtonChoice
            model.pedalEnabled = pedalEnabled
            model.pedalPosition = pedalPosition
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
            model.themePreset = themePreset
            model.whisperIdleTimeout = timeout
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
                    if isValid {
                        downloadedModels.insert(name)
                        // Auto-preload if this is the selected model and not loading yet
                        if name == selectedModel { maybeStartPreload(for: name) }
                    }
                }
            }
        }
    }

    /// Start preloading into memory if the model is downloaded and not already loading/ready.
    private func maybeStartPreload(for modelName: String) {
        guard downloadedModels.contains(modelName) else { return }
        guard !modelReady || selectedModel != modelName else { return }
        guard loadingModelName == nil else { return }
        startModelPreload(modelName: modelName)
    }

    private func startModelPreload(modelName: String) {
        loadingModelName = modelName
        Task {
            var transcriber: WhisperKitTranscriber? = WhisperKitTranscriber(
                modelName: modelName,
                idleTimeout: AppConfig.shared.model.whisperIdleTimeout
            )
            do {
                try await transcriber?.preload()
                transcriber = nil  // Release CoreML models from memory
                await MainActor.run {
                    loadingModelName = nil
                    if selectedModel == modelName { modelReady = true }
                }
            } catch {
                transcriber = nil  // Release on error too
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
        Task {
            var transcriber: WhisperKitTranscriber? = WhisperKitTranscriber(
                modelName: modelName,
                idleTimeout: AppConfig.shared.model.whisperIdleTimeout
            )
            do {
                try await transcriber?.preload()
                transcriber = nil  // Release CoreML models from memory
            } catch {
                transcriber = nil  // Release on error too
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
                    // The download's preload() already loaded the model into memory,
                    // so mark it ready directly — no second preload needed.
                    if modelName == self.selectedModel {
                        self.modelReady = true
                    }
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
