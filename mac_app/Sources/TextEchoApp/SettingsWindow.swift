import AppKit
import AVFoundation
import SwiftUI

// MARK: - SettingsSaveCallbacks (bridges save callbacks from SwiftUI struct to NSWindowDelegate)

final class SettingsSaveCallbacks {
    var onSave: (() -> Void)?
    var onResetDirty: (() -> Void)?
}

// MARK: - SettingsWindowController

final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let onUninstall: () -> Void
    private let onOpenLogs: () -> Void
    private let onOpenSetupWizard: () -> Void
    private var isDirty = false
    private let saveCallbacks = SettingsSaveCallbacks()

    init(onUninstall: @escaping () -> Void = {}, onOpenLogs: @escaping () -> Void = {}, onOpenSetupWizard: @escaping () -> Void = {}) {
        self.onUninstall = onUninstall
        self.onOpenLogs = onOpenLogs
        self.onOpenSetupWizard = onOpenSetupWizard
        super.init()
    }

    func show() {
        if window == nil {
            let view = SettingsView(
                onUninstall: onUninstall,
                onOpenLogs: onOpenLogs,
                onOpenSetupWizard: onOpenSetupWizard,
                onClose: { [weak self] in
                    self?.window?.performClose(nil)
                },
                onDirtyChanged: { [weak self] dirty in
                    self?.isDirty = dirty
                    self?.window?.isDocumentEdited = dirty
                },
                saveCallbacks: saveCallbacks
            )
            let hosting = NSHostingView(rootView: view)
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 740),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            w.minSize = NSSize(width: 520, height: 560)
            w.center()
            w.title = "TextEcho Settings"
            w.contentView = hosting
            w.isReleasedWhenClosed = false
            w.delegate = self
            self.window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Unsaved Changes"
        alert.informativeText = "You have settings changes that haven't been applied yet."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            saveCallbacks.onSave?()
            isDirty = false
            sender.isDocumentEdited = false
            return true
        case .alertSecondButtonReturn:
            isDirty = false
            saveCallbacks.onResetDirty?()
            return true
        default:
            return false
        }
    }
}

// MARK: - SettingsView

struct SettingsView: View {
    // Activation modes
    @State private var capsLockEnabled: Bool = AppConfig.shared.model.capsLockEnabled
    @State private var mouseEnabled: Bool = AppConfig.shared.model.mouseEnabled
    @State private var mouseMode: Int = AppConfig.shared.model.mouseMode
    @State private var keyboardEnabled: Bool = AppConfig.shared.model.keyboardEnabled
    @State private var keyboardMode: Int = AppConfig.shared.model.keyboardMode

    // Mouse / keyboard trigger config
    @State private var triggerButton: String
    @State private var triggerButtonChoice: Int
    @State private var dictationKey: String
    @State private var dictationModCtrl: Bool = AppConfig.shared.model.dictationModifiers & UInt(NSEvent.ModifierFlags.control.rawValue) != 0
    @State private var dictationModOpt: Bool = AppConfig.shared.model.dictationModifiers & UInt(NSEvent.ModifierFlags.option.rawValue) != 0
    @State private var dictationModCmd: Bool = AppConfig.shared.model.dictationModifiers & UInt(NSEvent.ModifierFlags.command.rawValue) != 0
    @State private var dictationModShift: Bool = AppConfig.shared.model.dictationModifiers & UInt(NSEvent.ModifierFlags.shift.rawValue) != 0
    @State private var llmModShift: Bool = AppConfig.shared.model.dictationLLMModifier & UInt(NSEvent.ModifierFlags.shift.rawValue) != 0
    @State private var llmModCtrl: Bool = AppConfig.shared.model.dictationLLMModifier & UInt(NSEvent.ModifierFlags.control.rawValue) != 0
    @State private var llmModOpt: Bool = AppConfig.shared.model.dictationLLMModifier & UInt(NSEvent.ModifierFlags.option.rawValue) != 0
    @State private var llmModCmd: Bool = AppConfig.shared.model.dictationLLMModifier & UInt(NSEvent.ModifierFlags.command.rawValue) != 0

    // Audio
    @State private var silenceEnabled: Bool = AppConfig.shared.model.silenceEnabled
    @State private var silenceDuration: Double = AppConfig.shared.model.silenceDuration
    @State private var silenceThreshold: String = String(AppConfig.shared.model.silenceThreshold)
    @State private var sampleRate: String = String(Int(AppConfig.shared.model.sampleRate))
    // Transcription engine
    @State private var selectedEngine: String = AppConfig.shared.model.transcriptionEngine
    @State private var selectedWhisperModel: String = AppConfig.shared.model.whisperModel
    @State private var selectedParakeetModel: String = AppConfig.shared.model.parakeetModel
    @State private var showModelPicker: Bool = false
    @State private var downloadedModelNames: [String] = []
    @State private var idleTimeoutPreset: Int = AppConfig.shared.model.whisperIdleTimeout
    @State private var customIdleTimeoutText: String = String(AppConfig.shared.model.whisperIdleTimeout / 60)

    // Input device
    @State private var selectedDeviceUID: String = AppConfig.shared.model.inputDeviceUID
    @State private var inputDevices: [(id: UInt32, uid: String, name: String)] = AudioRecorder.availableInputDevices()

    // Behavior
    @State private var autoCopyToClipboard: Bool = AppConfig.shared.model.autoCopyToClipboard
    @State private var overlayPositionMode: Int = AppConfig.shared.model.overlayPositionMode
    @State private var showMenuBarIcon: Bool = AppConfig.shared.model.showMenuBarIcon

    // History
    @State private var historyEnabled: Bool = AppConfig.shared.model.historyEnabled
    @State private var menuBarHistoryEnabled: Bool = AppConfig.shared.model.menuBarHistoryEnabled
    @State private var maxHistoryCountText: String = String(AppConfig.shared.model.maxHistoryCount)

    // Theme
    @State private var themePreset: String = AppConfig.shared.model.themePreset
    @State private var userPresetNames: [String] = Array(UserThemePresets.shared.presets.keys).sorted()
    @State private var showingSavePresetAlert: Bool = false
    @State private var newPresetName: String = ""
    @State private var colorRecording: Color = Color(hex: AppConfig.shared.model.colorRecording) ?? .cyan
    @State private var colorProcessing: Color = Color(hex: AppConfig.shared.model.colorProcessing) ?? .purple
    @State private var colorSuccess: Color = Color(hex: AppConfig.shared.model.colorSuccess) ?? .green
    @State private var colorError: Color = Color(hex: AppConfig.shared.model.colorError) ?? .red
    @State private var colorLoading: Color = Color(hex: AppConfig.shared.model.colorLoading) ?? .orange
    @State private var colorWaveform: Color = Color(hex: AppConfig.shared.model.colorWaveform) ?? .blue
    @State private var colorBgDark: Color = Color(hex: AppConfig.shared.model.colorBgDark) ?? .black
    @State private var colorBgLight: Color = Color(hex: AppConfig.shared.model.colorBgLight) ?? .black

    // Pedal
    @State private var pedalEnabled: Bool = AppConfig.shared.model.pedalEnabled
    @State private var pedalPosition: Int = AppConfig.shared.model.pedalPosition

    // Magic Trackpad
    @State private var trackpadEnabled: Bool = AppConfig.shared.model.trackpadEnabled
    @State private var trackpadGesture: Int = AppConfig.shared.model.trackpadGesture
    @State private var trackpadMode: Int = AppConfig.shared.model.trackpadMode

    // LLM
    @State private var llmEnabled: Bool = AppConfig.shared.model.llmEnabled
    @State private var llmModelPath: String = AppConfig.shared.model.llmModelPath
    @State private var pythonPath: String = AppConfig.shared.model.pythonPath
    @State private var scriptsDir: String = AppConfig.shared.model.daemonScriptsDir

    // Permissions
    @State private var accessibilityTrusted: Bool = AccessibilityHelper.isTrusted()
    @State private var micStatus: AVAuthorizationStatus = MicrophoneHelper.authorizationStatus()

    // Dirty tracking
    @State private var isDirty = false

    private let llmAvailable = AppConfig.shared.model.llmAvailable
    let onUninstall: () -> Void
    let onOpenLogs: () -> Void
    let onOpenSetupWizard: () -> Void
    let onClose: () -> Void
    let onDirtyChanged: (Bool) -> Void
    let saveCallbacks: SettingsSaveCallbacks

    init(
        onUninstall: @escaping () -> Void = {},
        onOpenLogs: @escaping () -> Void = {},
        onOpenSetupWizard: @escaping () -> Void = {},
        onClose: @escaping () -> Void = {},
        onDirtyChanged: @escaping (Bool) -> Void = { _ in },
        saveCallbacks: SettingsSaveCallbacks = SettingsSaveCallbacks()
    ) {
        self.onUninstall = onUninstall
        self.onOpenLogs = onOpenLogs
        self.onOpenSetupWizard = onOpenSetupWizard
        self.onClose = onClose
        self.onDirtyChanged = onDirtyChanged
        self.saveCallbacks = saveCallbacks

        let trigger = AppConfig.shared.model.triggerButton
        _triggerButton = State(initialValue: String(trigger))
        if trigger == 0 || trigger == 1 || trigger == 2 {
            _triggerButtonChoice = State(initialValue: trigger)
        } else {
            _triggerButtonChoice = State(initialValue: 3)
        }
        _dictationKey = State(initialValue: SettingsView.keyName(for: AppConfig.shared.model.dictationKeyCode))
    }

    // MARK: - Dirty tracking helper

    private func dirty<T: Equatable>(_ binding: Binding<T>) -> Binding<T> {
        Binding(
            get: { binding.wrappedValue },
            set: { newVal in
                guard binding.wrappedValue != newVal else { return }
                binding.wrappedValue = newVal
                if !isDirty {
                    isDirty = true
                    onDirtyChanged(true)
                }
            }
        )
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // MARK: - Transcription Activation
                sectionHeader("Transcription Activation")

                activationCard {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "lock")
                            .font(.system(size: 15))
                            .frame(width: 20, height: 20)
                            .foregroundColor(.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Caps Lock")
                                .font(.system(size: 13, weight: .semibold))
                            Text("Press Caps Lock to start recording. Press again to stop.")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: dirty($capsLockEnabled)).labelsHidden()
                    }
                }

                activationCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "computermouse")
                                .font(.system(size: 15))
                                .frame(width: 20, height: 20)
                                .foregroundColor(.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Mouse Button")
                                    .font(.system(size: 13, weight: .semibold))
                                Text("Click or hold a mouse button to record.")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: dirty($mouseEnabled)).labelsHidden()
                        }
                        if mouseEnabled {
                            HStack {
                                Text("Button")
                                    .font(.system(size: 12)).foregroundColor(.secondary)
                                Spacer()
                                Picker("", selection: dirty($triggerButtonChoice)) {
                                    Text("Left").tag(0)
                                    Text("Right").tag(1)
                                    Text("Middle").tag(2)
                                    Text("Other…").tag(3)
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 240)
                            }
                            .padding(.leading, 30)
                            if triggerButtonChoice == 3 {
                                HStack {
                                    Text("Button Number")
                                        .font(.system(size: 12)).foregroundColor(.secondary)
                                    Spacer()
                                    TextField("2", text: dirty($triggerButton)).frame(width: 60)
                                }
                                .padding(.leading, 30)
                            }
                            HStack {
                                Text("Mode")
                                    .font(.system(size: 12)).foregroundColor(.secondary)
                                Spacer()
                                Picker("", selection: dirty($mouseMode)) {
                                    Text("Toggle").tag(0)
                                    Text("Hold").tag(1)
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 160)
                            }
                            .padding(.leading, 30)
                        }
                    }
                }

                activationCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "keyboard")
                                .font(.system(size: 15))
                                .frame(width: 20, height: 20)
                                .foregroundColor(.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Keyboard Shortcut")
                                    .font(.system(size: 13, weight: .semibold))
                                Text("Press a keyboard shortcut to start recording.")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: dirty($keyboardEnabled)).labelsHidden()
                        }
                        if keyboardEnabled {
                            HStack {
                                Text("Key")
                                    .font(.system(size: 12)).foregroundColor(.secondary)
                                Spacer()
                                TextField("Z", text: dirty($dictationKey))
                                    .frame(width: 44)
                                    .multilineTextAlignment(.center)
                            }
                            .padding(.leading, 30)
                            HStack {
                                Text("Modifiers")
                                    .font(.system(size: 12)).foregroundColor(.secondary)
                                Spacer()
                                HStack(spacing: 8) {
                                    Toggle("⌃", isOn: dirty($dictationModCtrl))
                                    Toggle("⌥", isOn: dirty($dictationModOpt))
                                    Toggle("⌘", isOn: dirty($dictationModCmd))
                                    Toggle("⇧", isOn: dirty($dictationModShift))
                                }
                            }
                            .padding(.leading, 30)
                            HStack {
                                Text("Mode")
                                    .font(.system(size: 12)).foregroundColor(.secondary)
                                Spacer()
                                Picker("", selection: dirty($keyboardMode)) {
                                    Text("Toggle").tag(0)
                                    Text("Hold").tag(1)
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 160)
                            }
                            .padding(.leading, 30)
                            HStack {
                                Text("LLM Extra Modifier")
                                    .font(.system(size: 12)).foregroundColor(.secondary)
                                Spacer()
                                HStack(spacing: 8) {
                                    Toggle("⌃", isOn: dirty($llmModCtrl))
                                    Toggle("⌥", isOn: dirty($llmModOpt))
                                    Toggle("⌘", isOn: dirty($llmModCmd))
                                    Toggle("⇧", isOn: dirty($llmModShift))
                                }
                            }
                            .padding(.leading, 30)
                            Text("LLM modifier is added on top of the main shortcut to trigger LLM mode.")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .padding(.leading, 30)
                        }
                    }
                }

                activationCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "pedal.accelerator")
                                .font(.system(size: 15))
                                .frame(width: 20, height: 20)
                                .foregroundColor(.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Stream Deck Pedal")
                                    .font(.system(size: 13, weight: .semibold))
                                Text("Use an Elgato Stream Deck Pedal to control recording.")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: dirty($pedalEnabled)).labelsHidden()
                        }
                        if pedalEnabled {
                            HStack {
                                Text("Push-to-talk pedal")
                                    .font(.system(size: 12)).foregroundColor(.secondary)
                                Spacer()
                                Picker("", selection: dirty($pedalPosition)) {
                                    Text("Left").tag(0)
                                    Text("Center").tag(1)
                                    Text("Right").tag(2)
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 200)
                            }
                            .padding(.leading, 30)
                            Text("Left pedal = Paste, Center = Push-to-talk, Right = Enter. Quit Elgato Stream Deck app if not detected.")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .padding(.leading, 30)
                        }
                    }
                }

                activationCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "hand.tap")
                                .font(.system(size: 15))
                                .frame(width: 20, height: 20)
                                .foregroundColor(.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Magic Trackpad")
                                    .font(.system(size: 13, weight: .semibold))
                                Text("Use force click or right-click on an external Magic Trackpad to trigger recording.")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: dirty($trackpadEnabled)).labelsHidden()
                        }
                        if trackpadEnabled {
                            HStack {
                                Text("Trigger gesture")
                                    .font(.system(size: 12)).foregroundColor(.secondary)
                                Spacer()
                                Picker("", selection: dirty($trackpadGesture)) {
                                    Text("Force Click").tag(0)
                                    Text("Right Click").tag(1)
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 200)
                            }
                            .padding(.leading, 30)
                            HStack {
                                Text("Recording mode")
                                    .font(.system(size: 12)).foregroundColor(.secondary)
                                Spacer()
                                Picker("", selection: dirty($trackpadMode)) {
                                    Text("Toggle").tag(0)
                                    Text("Hold").tag(1)
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 200)
                            }
                            .padding(.leading, 30)
                            Text("Works with any Apple Magic Trackpad. Does not affect your Mac's built-in trackpad or mouse.")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .padding(.leading, 30)
                        }
                    }
                }

                sectionDivider()

                // MARK: - Transcription Engine
                sectionHeader("Transcription Engine")

                HStack {
                    Text("Engine")
                    Spacer()
                    Picker("", selection: dirty($selectedEngine)) {
                        Text("Parakeet (Recommended)").tag("parakeet")
                        Text("Whisper").tag("whisper")
                    }
                    .frame(maxWidth: 220)
                }
                .padding(.bottom, 4)

                if selectedEngine == "parakeet" {
                    Text("NVIDIA Parakeet TDT — 2.1% WER, 3-6x faster than Whisper. Powered by FluidAudio.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .padding(.bottom, 4)

                    HStack {
                        Text("Model")
                        Spacer()
                        Picker("", selection: dirty($selectedParakeetModel)) {
                            ForEach(ParakeetTranscriber.availableModelList, id: \.name) { model in
                                Text(model.displayName).tag(model.name)
                            }
                        }
                        .frame(maxWidth: 220)
                    }
                    .padding(.bottom, 4)
                } else {
                    HStack {
                        Text("Active Model")
                        Spacer()
                        if downloadedModelNames.isEmpty {
                            Text("No models downloaded")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        } else {
                            Picker("", selection: dirty($selectedWhisperModel)) {
                                ForEach(downloadedModelNames, id: \.self) { name in
                                    let info = WhisperKitTranscriber.availableModelList.first(where: { $0.name == name })
                                    Text(info?.displayName ?? name).tag(name)
                                }
                            }
                            .frame(maxWidth: 220)
                        }
                    }
                    .padding(.bottom, 4)

                    Button("Manage & Download Models…") {
                        showModelPicker = true
                    }
                    .sheet(isPresented: $showModelPicker) {
                        ModelPickerView(selectedModel: dirty($selectedWhisperModel))
                    }
                }

                // MARK: - Model Memory (Idle Timeout)
                Text("Model Memory")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.top, 12)
                    .padding(.bottom, 4)

                HStack {
                    Text("Unload model after idle")
                    Spacer()
                    Picker("", selection: dirty($idleTimeoutPreset)) {
                        Text("Never").tag(0)
                        Text("1 hour").tag(3600)
                        Text("4 hours").tag(14400)
                        Text("8 hours").tag(28800)
                        Text("Custom").tag(-1)
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 140)
                    .onChange(of: idleTimeoutPreset) { newValue in
                        if newValue >= 0 {
                            customIdleTimeoutText = newValue > 0 ? String(newValue / 60) : "0"
                        }
                    }
                }

                if idleTimeoutPreset == -1 {
                    HStack {
                        Text("Minutes")
                            .font(.system(size: 12)).foregroundColor(.secondary)
                        Spacer()
                        TextField("60", text: dirty($customIdleTimeoutText))
                            .frame(width: 70)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: customIdleTimeoutText) { newValue in
                                let filtered = newValue.filter { $0.isNumber }
                                if filtered != newValue {
                                    customIdleTimeoutText = filtered
                                }
                            }
                    }
                    .padding(.leading, 16)
                }

                Text(idleTimeoutPreset == 0
                     ? "Model stays in RAM for instant transcription (~1.6GB)."
                     : "Model unloads from RAM after idle to free memory. Next recording re-loads it (1-3s).")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .padding(.bottom, 4)

                sectionDivider()

                // MARK: - Audio
                sectionHeader("Audio")

                HStack {
                    Text("Input Device")
                    Spacer()
                    Picker("", selection: dirty($selectedDeviceUID)) {
                        Text("System Default").tag("")
                        ForEach(inputDevices, id: \.uid) { device in
                            Text(device.name).tag(device.uid)
                        }
                    }
                    .frame(width: 220)
                    Button("Refresh") {
                        inputDevices = AudioRecorder.availableInputDevices()
                    }
                    .font(.system(size: 11))
                }

                Toggle("Stop on silence", isOn: dirty($silenceEnabled))
                Text("Automatically stop recording after a period of silence.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .padding(.bottom, 4)

                if silenceEnabled {
                    HStack(spacing: 12) {
                        Text("Silence timeout")
                        Slider(value: dirty($silenceDuration), in: 0.5...10.0, step: 0.5)
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
                }

                HStack {
                    Text("Silence threshold")
                    Spacer()
                    TextField("0.015", text: dirty($silenceThreshold)).frame(width: 80)
                }

                HStack {
                    Text("Sample rate")
                    Spacer()
                    TextField("16000", text: dirty($sampleRate)).frame(width: 80)
                }

                sectionDivider()

                // MARK: - Behavior
                sectionHeader("Behavior")

                Toggle("Auto-paste transcription", isOn: dirty($autoCopyToClipboard))
                Text("Automatically pastes transcribed text at your cursor after recording.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .padding(.bottom, 6)

                sectionDivider()

                // MARK: - Interface
                sectionHeader("Interface")

                HStack {
                    Text("Overlay position")
                    Spacer()
                    Picker("", selection: dirty($overlayPositionMode)) {
                        Text("Fixed position").tag(0)
                        Text("Follow cursor").tag(1)
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 180)
                }

                Toggle("Show Menu Bar Icon", isOn: dirty($showMenuBarIcon))
                    .padding(.top, 4)

                sectionDivider()

                // MARK: - Overlay Theme
                sectionHeader("Overlay Theme")

                HStack {
                    Text("Color preset")
                    Spacer()
                    Picker("", selection: Binding(
                        get: { themePreset },
                        set: { newValue in
                            themePreset = newValue
                            if newValue != "custom" {
                                if let preset = OverlayTheme.presets[newValue] {
                                    applyPreset(preset)
                                } else if let preset = UserThemePresets.shared.presets[newValue] {
                                    applyPreset(preset)
                                }
                            }
                            if !isDirty { isDirty = true; onDirtyChanged(true) }
                        }
                    )) {
                        Text("TextEcho").tag("textecho")
                        Text("Cyber").tag("cyber")
                        Text("Classic").tag("classic")
                        Text("Ocean").tag("ocean")
                        Text("Sunset").tag("sunset")
                        ForEach(userPresetNames, id: \.self) { name in
                            Text(name.capitalized).tag(name)
                        }
                        Text("Custom").tag("custom")
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 160)
                }

                HStack(spacing: 8) {
                    Button("Save Current…") {
                        newPresetName = ""
                        showingSavePresetAlert = true
                    }
                    .font(.system(size: 11))

                    if !UserThemePresets.shared.isReserved(themePreset) && themePreset != "custom" && userPresetNames.contains(themePreset) {
                        Button("Delete \"\(themePreset.capitalized)\"") {
                            UserThemePresets.shared.delete(name: themePreset)
                            refreshUserPresets()
                            themePreset = "cyber"
                            if let preset = OverlayTheme.presets["cyber"] {
                                applyPreset(preset)
                            }
                            if !isDirty { isDirty = true; onDirtyChanged(true) }
                        }
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                    }

                    Spacer()
                }
                .sheet(isPresented: $showingSavePresetAlert) {
                    VStack(spacing: 16) {
                        Text("Save Current Colors as Preset")
                            .font(.headline)

                        TextField("Preset name", text: $newPresetName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)

                        if UserThemePresets.shared.isReserved(newPresetName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
                            Text("Cannot overwrite built-in presets.")
                                .font(.system(size: 10))
                                .foregroundColor(.red)
                        }

                        HStack(spacing: 12) {
                            Button("Cancel") {
                                showingSavePresetAlert = false
                            }
                            Button("Save") {
                                saveCurrentAsPreset()
                                showingSavePresetAlert = false
                            }
                            .disabled(newPresetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || UserThemePresets.shared.isReserved(newPresetName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()))
                            .keyboardShortcut(.defaultAction)
                        }
                    }
                    .padding(24)
                    .frame(minWidth: 300)
                }

                // Color preview strip
                HStack(spacing: 4) {
                    colorSwatch(colorRecording, label: "Rec")
                    colorSwatch(colorProcessing, label: "Proc")
                    colorSwatch(colorSuccess, label: "Done")
                    colorSwatch(colorError, label: "Err")
                    colorSwatch(colorLoading, label: "Load")
                    colorSwatch(colorWaveform, label: "Wave")
                    colorSwatch(colorBgDark, label: "BG")
                }
                .padding(.vertical, 6)

                if themePreset == "custom" {
                    VStack(spacing: 8) {
                        themeColorRow("Recording", color: dirty($colorRecording))
                        themeColorRow("Processing / LLM", color: dirty($colorProcessing))
                        themeColorRow("Success / Result", color: dirty($colorSuccess))
                        themeColorRow("Error", color: dirty($colorError))
                        themeColorRow("Loading", color: dirty($colorLoading))
                        themeColorRow("Waveform", color: dirty($colorWaveform))
                        themeColorRow("Background Dark", color: dirty($colorBgDark))
                        themeColorRow("Background Light", color: dirty($colorBgLight))
                    }
                }

                Text("Colors apply after saving. Presets override all custom colors.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .padding(.top, 2)

                sectionDivider()

                // MARK: - Transcription History
                sectionHeader("Transcription History")

                Toggle("Enable History", isOn: dirty($historyEnabled))
                Text("Saves transcriptions so you can review and re-copy them later.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .padding(.bottom, 4)

                if historyEnabled {
                    Toggle("Show in Menu Bar", isOn: dirty($menuBarHistoryEnabled))
                    Text("Shows your 5 most recent transcriptions in the menu bar for quick re-copy.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .padding(.bottom, 4)

                    HStack {
                        Text("Max history entries")
                        Spacer()
                        TextField("50", text: dirty($maxHistoryCountText))
                            .frame(width: 70)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: maxHistoryCountText) { newValue in
                                let filtered = newValue.filter { $0.isNumber }
                                if filtered != newValue {
                                    maxHistoryCountText = filtered
                                }
                            }
                    }
                    Text("Between 10 and 1000 entries.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                sectionDivider()

                // MARK: - LLM (only if available)
                if llmAvailable {
                    sectionHeader("LLM")
                    Toggle("Enable LLM", isOn: dirty($llmEnabled))
                    HStack {
                        Text("LLM Model Path")
                        Spacer()
                        TextField("/path/to/model.gguf", text: dirty($llmModelPath)).frame(width: 260)
                    }

                    sectionDivider()

                    sectionHeader("Python (LLM)")
                    HStack {
                        Text("Python Path")
                        Spacer()
                        TextField("/opt/homebrew/bin/python3", text: dirty($pythonPath)).frame(width: 260)
                    }
                    HStack {
                        Text("Daemons Dir")
                        Spacer()
                        TextField("/path/to/scripts", text: dirty($scriptsDir)).frame(width: 260)
                    }

                    sectionDivider()
                }

                // MARK: - Permissions
                sectionHeader("Permissions")

                VStack(spacing: 0) {
                    permissionRow(
                        name: "Microphone",
                        description: "Required to record your voice.",
                        granted: micStatus == .authorized,
                        openAnchor: "Privacy_Microphone"
                    )
                    Divider().padding(.leading, 16)
                    permissionRow(
                        name: "Accessibility",
                        description: "Required to detect hotkeys and inject text.",
                        granted: accessibilityTrusted,
                        openAnchor: "Privacy_Accessibility"
                    )
                }
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.2), lineWidth: 1))

                Button("Revoke All Permissions…") {
                    revokePermissions()
                }
                .foregroundColor(.secondary)
                .font(.system(size: 11))
                .padding(.top, 6)

                sectionDivider()

                // MARK: - Debug / maintenance row
                HStack(spacing: 12) {
                    Button("Open Logs") {
                        onOpenLogs()
                    }
                    Button("Setup Wizard…") {
                        onOpenSetupWizard()
                    }
                    Button("Restart TextEcho") {
                        save()
                        restartApp()
                    }
                    Spacer()
                    Button("Uninstall TextEcho…") {
                        onUninstall()
                    }
                    .foregroundColor(.red)
                }
                .font(.system(size: 12))

                sectionDivider()

                // MARK: - Unsaved changes indicator + Save/Done buttons
                HStack {
                    if isDirty {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 6, height: 6)
                            Text("Unsaved changes")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    Button("Close") {
                        onClose()
                    }
                    .buttonStyle(.bordered)
                    Button("Save") {
                        save()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isDirty)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 520, minHeight: 560)
        .onAppear {
            refreshUserPresets()
            refreshPermissions()
            inputDevices = AudioRecorder.availableInputDevices()
            downloadedModelNames = WhisperKitTranscriber.availableModelList
                .map(\.name)
                .filter { WhisperKitTranscriber.isModelCached($0) }
            if !downloadedModelNames.isEmpty && !downloadedModelNames.contains(selectedWhisperModel) {
                downloadedModelNames.insert(selectedWhisperModel, at: 0)
            }
            // Map stored idle timeout to nearest preset or custom
            let storedTimeout = AppConfig.shared.model.whisperIdleTimeout
            if [0, 3600, 14400, 28800].contains(storedTimeout) {
                idleTimeoutPreset = storedTimeout
            } else {
                idleTimeoutPreset = -1
                customIdleTimeoutText = String(storedTimeout / 60)
            }
            saveCallbacks.onSave = { save() }
            saveCallbacks.onResetDirty = { isDirty = false; onDirtyChanged(false) }
        }
    }

    // MARK: - View helpers

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 14, weight: .semibold))
            .padding(.bottom, 10)
    }

    @ViewBuilder
    private func sectionDivider() -> some View {
        Divider().padding(.vertical, 12)
    }

    @ViewBuilder
    private func activationCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.2), lineWidth: 1))
            .padding(.bottom, 8)
    }

    @ViewBuilder
    private func permissionRow(name: String, description: String, granted: Bool, openAnchor: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundColor(granted ? .green : .orange)
                .font(.system(size: 20))
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 13, weight: .medium))
                Text(granted ? "Granted" : description)
                    .font(.system(size: 11))
                    .foregroundColor(granted ? .secondary : .red)
            }
            Spacer()
            Button("Open Settings") {
                openSystemPreferences(anchor: openAnchor)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
    }

    // MARK: - Theme helpers

    @ViewBuilder
    private func themeColorRow(_ label: String, color: Binding<Color>) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer()
            ColorPicker("", selection: color, supportsOpacity: false)
                .labelsHidden()
        }
        .padding(.leading, 16)
    }

    @ViewBuilder
    private func colorSwatch(_ color: Color, label: String) -> some View {
        VStack(spacing: 2) {
            RoundedRectangle(cornerRadius: 4)
                .fill(color)
                .frame(width: 36, height: 24)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.2), lineWidth: 1))
            Text(label)
                .font(.system(size: 8))
                .foregroundColor(.secondary)
        }
    }

    private func applyPreset(_ preset: [String: String]) {
        if let v = preset["colorRecording"] { colorRecording = Color(hex: v) ?? colorRecording }
        if let v = preset["colorProcessing"] { colorProcessing = Color(hex: v) ?? colorProcessing }
        if let v = preset["colorSuccess"] { colorSuccess = Color(hex: v) ?? colorSuccess }
        if let v = preset["colorError"] { colorError = Color(hex: v) ?? colorError }
        if let v = preset["colorLoading"] { colorLoading = Color(hex: v) ?? colorLoading }
        if let v = preset["colorWaveform"] { colorWaveform = Color(hex: v) ?? colorWaveform }
        if let v = preset["colorBgDark"] { colorBgDark = Color(hex: v) ?? colorBgDark }
        if let v = preset["colorBgLight"] { colorBgLight = Color(hex: v) ?? colorBgLight }
    }

    private func saveCurrentAsPreset() {
        let name = newPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let colors: [String: String] = [
            "colorRecording": colorRecording.toHex(),
            "colorProcessing": colorProcessing.toHex(),
            "colorSuccess": colorSuccess.toHex(),
            "colorError": colorError.toHex(),
            "colorLoading": colorLoading.toHex(),
            "colorWaveform": colorWaveform.toHex(),
            "colorBgDark": colorBgDark.toHex(),
            "colorBgLight": colorBgLight.toHex(),
        ]
        UserThemePresets.shared.save(name: name, colors: colors)
        refreshUserPresets()
        themePreset = name.lowercased()
        if !isDirty { isDirty = true; onDirtyChanged(true) }
    }

    private func refreshUserPresets() {
        UserThemePresets.shared.load()
        userPresetNames = Array(UserThemePresets.shared.presets.keys).sorted()
    }

    // MARK: - Logic

    private func restartApp() {
        let appURL = Bundle.main.bundleURL
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", appURL.path]
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            try? process.run()
        }
        NSApplication.shared.terminate(nil)
    }

    private func save() {
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
            if triggerButtonChoice == 3 {
                model.triggerButton = Int(triggerButton) ?? model.triggerButton
            } else {
                model.triggerButton = triggerButtonChoice
            }
            if let keyCode = SettingsView.keyCode(for: dictationKey) {
                model.dictationKeyCode = keyCode
            }
            model.dictationModifiers = dictationMods
            model.dictationLLMModifier = llmMods
            model.silenceEnabled = silenceEnabled
            model.silenceDuration = silenceDuration
            model.silenceThreshold = Double(silenceThreshold) ?? model.silenceThreshold
            model.sampleRate = Double(sampleRate) ?? model.sampleRate
            model.llmEnabled = llmEnabled
            model.llmModelPath = llmModelPath
            model.showMenuBarIcon = showMenuBarIcon
            model.pythonPath = pythonPath
            model.daemonScriptsDir = scriptsDir
            model.transcriptionEngine = selectedEngine
            model.whisperModel = selectedWhisperModel
            model.parakeetModel = selectedParakeetModel
            model.inputDeviceUID = selectedDeviceUID
            model.pedalEnabled = pedalEnabled
            model.pedalPosition = pedalPosition
            model.trackpadEnabled = trackpadEnabled
            model.trackpadGesture = trackpadGesture
            model.trackpadMode = trackpadMode
            model.overlayPositionMode = overlayPositionMode == 1 ? 1 : 0
            model.capsLockEnabled = capsLockEnabled
            model.mouseEnabled = mouseEnabled
            model.mouseMode = mouseMode
            model.keyboardEnabled = keyboardEnabled
            model.keyboardMode = keyboardMode
            model.autoCopyToClipboard = autoCopyToClipboard
            model.historyEnabled = historyEnabled
            model.menuBarHistoryEnabled = menuBarHistoryEnabled
            model.maxHistoryCount = max(10, min(Int(maxHistoryCountText) ?? 50, 1000))

            // Theme
            model.themePreset = themePreset
            model.colorRecording = colorRecording.toHex()
            model.colorProcessing = colorProcessing.toHex()
            model.colorSuccess = colorSuccess.toHex()
            model.colorError = colorError.toHex()
            model.colorLoading = colorLoading.toHex()
            model.colorWaveform = colorWaveform.toHex()
            model.colorBgDark = colorBgDark.toHex()
            model.colorBgLight = colorBgLight.toHex()

            // Idle timeout
            if idleTimeoutPreset == -1 {
                let minutes = Int(customIdleTimeoutText) ?? 60
                model.whisperIdleTimeout = minutes == 0 ? 0 : max(1, minutes) * 60
            } else {
                model.whisperIdleTimeout = idleTimeoutPreset
            }
        }

        isDirty = false
        onDirtyChanged(false)
    }

    private func buildModifierMask(ctrl: Bool, opt: Bool, cmd: Bool, shift: Bool) -> UInt {
        var mask: UInt = 0
        if ctrl { mask |= UInt(NSEvent.ModifierFlags.control.rawValue) }
        if opt { mask |= UInt(NSEvent.ModifierFlags.option.rawValue) }
        if cmd { mask |= UInt(NSEvent.ModifierFlags.command.rawValue) }
        if shift { mask |= UInt(NSEvent.ModifierFlags.shift.rawValue) }
        return mask
    }

    private func refreshPermissions() {
        accessibilityTrusted = AccessibilityHelper.isTrusted()
        micStatus = MicrophoneHelper.authorizationStatus()
    }

    private func revokePermissions() {
        let alert = NSAlert()
        alert.messageText = "Revoke Permissions"
        alert.informativeText = "This will open Terminal commands to remove TextEcho's microphone and accessibility permissions. You'll need to re-grant them the next time TextEcho starts."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            openSystemPreferences(anchor: "Privacy_Microphone")
        }
    }

    private func openSystemPreferences(anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
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
        return map[keyCode] ?? String(keyCode)
    }
}
