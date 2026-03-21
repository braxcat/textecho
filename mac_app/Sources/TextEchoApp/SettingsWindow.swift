import AppKit
import AVFoundation
import SwiftUI

final class SettingsWindowController {
    private var window: NSWindow?
    private let onUninstall: () -> Void

    init(onUninstall: @escaping () -> Void = {}) {
        self.onUninstall = onUninstall
    }

    func show() {
        if window == nil {
            let view = SettingsView(onUninstall: onUninstall)
            let hosting = NSHostingView(rootView: view)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 700),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.minSize = NSSize(width: 520, height: 520)
            window.center()
            window.title = "TextEcho Settings"
            window.contentView = hosting
            window.isReleasedWhenClosed = false
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

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
    @State private var silenceDuration: String = String(AppConfig.shared.model.silenceDuration)
    @State private var silenceThreshold: String = String(AppConfig.shared.model.silenceThreshold)
    @State private var sampleRate: String = String(Int(AppConfig.shared.model.sampleRate))

    // WhisperKit model
    @State private var selectedWhisperModel: String = AppConfig.shared.model.whisperModel
    @State private var showModelPicker: Bool = false

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
    @State private var maxHistoryCount: Int = AppConfig.shared.model.maxHistoryCount

    // Pedal
    @State private var pedalEnabled: Bool = AppConfig.shared.model.pedalEnabled
    @State private var pedalPosition: Int = AppConfig.shared.model.pedalPosition

    // LLM
    @State private var llmEnabled: Bool = AppConfig.shared.model.llmEnabled
    @State private var llmModelPath: String = AppConfig.shared.model.llmModelPath
    @State private var pythonPath: String = AppConfig.shared.model.pythonPath
    @State private var scriptsDir: String = AppConfig.shared.model.daemonScriptsDir

    // Permissions
    @State private var accessibilityTrusted: Bool = AccessibilityHelper.isTrusted()
    @State private var micStatus: AVAuthorizationStatus = MicrophoneHelper.authorizationStatus()

    private let llmAvailable = AppConfig.shared.model.llmAvailable
    let onUninstall: () -> Void

    init(onUninstall: @escaping () -> Void = {}) {
        self.onUninstall = onUninstall
        let trigger = AppConfig.shared.model.triggerButton
        _triggerButton = State(initialValue: String(trigger))
        if trigger == 0 || trigger == 1 || trigger == 2 {
            _triggerButtonChoice = State(initialValue: trigger)
        } else {
            _triggerButtonChoice = State(initialValue: 3)
        }
        _dictationKey = State(initialValue: SettingsView.keyName(for: AppConfig.shared.model.dictationKeyCode))
    }

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
                        Toggle("", isOn: $capsLockEnabled).labelsHidden()
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
                            Toggle("", isOn: $mouseEnabled).labelsHidden()
                        }
                        if mouseEnabled {
                            HStack {
                                Text("Button")
                                    .font(.system(size: 12)).foregroundColor(.secondary)
                                Spacer()
                                Picker("", selection: $triggerButtonChoice) {
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
                                    TextField("2", text: $triggerButton).frame(width: 60)
                                }
                                .padding(.leading, 30)
                            }
                            HStack {
                                Text("Mode")
                                    .font(.system(size: 12)).foregroundColor(.secondary)
                                Spacer()
                                Picker("", selection: $mouseMode) {
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
                            Toggle("", isOn: $keyboardEnabled).labelsHidden()
                        }
                        if keyboardEnabled {
                            HStack {
                                Text("Key")
                                    .font(.system(size: 12)).foregroundColor(.secondary)
                                Spacer()
                                TextField("Z", text: $dictationKey)
                                    .frame(width: 44)
                                    .multilineTextAlignment(.center)
                            }
                            .padding(.leading, 30)
                            HStack {
                                Text("Modifiers")
                                    .font(.system(size: 12)).foregroundColor(.secondary)
                                Spacer()
                                HStack(spacing: 8) {
                                    Toggle("⌃", isOn: $dictationModCtrl)
                                    Toggle("⌥", isOn: $dictationModOpt)
                                    Toggle("⌘", isOn: $dictationModCmd)
                                    Toggle("⇧", isOn: $dictationModShift)
                                }
                            }
                            .padding(.leading, 30)
                            HStack {
                                Text("Mode")
                                    .font(.system(size: 12)).foregroundColor(.secondary)
                                Spacer()
                                Picker("", selection: $keyboardMode) {
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
                                    Toggle("⌃", isOn: $llmModCtrl)
                                    Toggle("⌥", isOn: $llmModOpt)
                                    Toggle("⌘", isOn: $llmModCmd)
                                    Toggle("⇧", isOn: $llmModShift)
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

                sectionDivider()

                // MARK: - Transcription Model
                sectionHeader("Transcription Model")

                HStack {
                    Text("Active Model")
                    Spacer()
                    Text(WhisperKitTranscriber.availableModelList.first(where: { $0.name == selectedWhisperModel })?.displayName ?? selectedWhisperModel)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .padding(.bottom, 8)

                Button("Manage & Download Models") {
                    showModelPicker = true
                }
                .sheet(isPresented: $showModelPicker) {
                    ModelPickerView(selectedModel: $selectedWhisperModel)
                }

                sectionDivider()

                // MARK: - Audio
                sectionHeader("Audio")

                HStack {
                    Text("Input Device")
                    Spacer()
                    Picker("", selection: $selectedDeviceUID) {
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

                HStack {
                    Text("Silence Duration (sec)")
                    Spacer()
                    TextField("2.5", text: $silenceDuration).frame(width: 80)
                }

                HStack {
                    Text("Silence Threshold")
                    Spacer()
                    TextField("0.015", text: $silenceThreshold).frame(width: 80)
                }

                HStack {
                    Text("Sample Rate")
                    Spacer()
                    TextField("16000", text: $sampleRate).frame(width: 80)
                }

                sectionDivider()

                // MARK: - Behavior
                sectionHeader("Behavior")

                Toggle("Auto-paste transcription", isOn: $autoCopyToClipboard)
                Text("Automatically pastes transcribed text at your cursor after recording.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .padding(.bottom, 6)

                HStack {
                    Text("Overlay Position")
                    Spacer()
                    Picker("", selection: $overlayPositionMode) {
                        Text("Static").tag(0)
                        Text("Follow Cursor").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }

                Toggle("Show Menu Bar Icon", isOn: $showMenuBarIcon)
                    .padding(.top, 4)

                sectionDivider()

                // MARK: - Transcription History
                sectionHeader("Transcription History")

                Toggle("Enable History", isOn: $historyEnabled)
                Text("Saves transcriptions so you can review and re-copy them later.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .padding(.bottom, 4)

                if historyEnabled {
                    Toggle("Show in Menu Bar", isOn: $menuBarHistoryEnabled)
                    Text("Shows your 5 most recent transcriptions in the menu bar for quick re-copy.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .padding(.bottom, 4)

                    HStack {
                        Text("Max history entries")
                        Spacer()
                        Stepper("\(maxHistoryCount)", value: $maxHistoryCount, in: 10...500, step: 10)
                            .frame(width: 160)
                    }
                }

                sectionDivider()

                // MARK: - Stream Deck Pedal
                sectionHeader("Stream Deck Pedal")

                Toggle("Enable Stream Deck Pedal", isOn: $pedalEnabled)

                if pedalEnabled {
                    HStack {
                        Text("Push-to-talk pedal")
                        Spacer()
                        Picker("", selection: $pedalPosition) {
                            Text("Left").tag(0)
                            Text("Center").tag(1)
                            Text("Right").tag(2)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 200)
                    }
                    Text("Left = Paste, Center = Push-to-talk, Right = Enter")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text("Quit Elgato Stream Deck app if pedal is not detected.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                sectionDivider()

                // MARK: - LLM (only if available)
                if llmAvailable {
                    sectionHeader("LLM")
                    Toggle("Enable LLM", isOn: $llmEnabled)
                    HStack {
                        Text("LLM Model Path")
                        Spacer()
                        TextField("/path/to/model.gguf", text: $llmModelPath).frame(width: 260)
                    }

                    sectionDivider()

                    sectionHeader("Python (LLM)")
                    HStack {
                        Text("Python Path")
                        Spacer()
                        TextField("/opt/homebrew/bin/python3", text: $pythonPath).frame(width: 260)
                    }
                    HStack {
                        Text("Daemons Dir")
                        Spacer()
                        TextField("/path/to/scripts", text: $scriptsDir).frame(width: 260)
                    }

                    sectionDivider()
                }

                // MARK: - Permissions (moved to bottom)
                sectionHeader("Permissions")

                HStack {
                    Text("Microphone")
                    Spacer()
                    statusBadge(micStatus == .authorized)
                }
                Button("Open Microphone Settings") {
                    openSystemPreferences(anchor: "Privacy_Microphone")
                }

                HStack {
                    Text("Accessibility")
                    Spacer()
                    statusBadge(accessibilityTrusted)
                }
                .padding(.top, 4)
                Button("Open Accessibility Settings") {
                    openSystemPreferences(anchor: "Privacy_Accessibility")
                }

                Button("Refresh Permissions Status") {
                    refreshPermissions()
                }

                sectionDivider()

                // MARK: - Danger Zone
                Button("Uninstall TextEcho…") {
                    onUninstall()
                }
                .foregroundColor(.red)

                sectionDivider()

                // MARK: - Actions
                HStack {
                    Button("Restart TextEcho") {
                        save()
                        restartApp()
                    }
                    Spacer()
                    Button("Save") {
                        save()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 520, minHeight: 520)
        .onAppear {
            refreshPermissions()
            inputDevices = AudioRecorder.availableInputDevices()
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

    // MARK: - Logic

    private func restartApp() {
        let appPath = Bundle.main.bundleURL.path
        let script = "sleep 1\nopen \"\(appPath)\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        try? process.run()
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
            model.silenceDuration = Double(silenceDuration) ?? model.silenceDuration
            model.silenceThreshold = Double(silenceThreshold) ?? model.silenceThreshold
            model.sampleRate = Double(sampleRate) ?? model.sampleRate
            model.llmEnabled = llmEnabled
            model.llmModelPath = llmModelPath
            model.showMenuBarIcon = showMenuBarIcon
            model.pythonPath = pythonPath
            model.daemonScriptsDir = scriptsDir
            model.whisperModel = selectedWhisperModel
            model.inputDeviceUID = selectedDeviceUID
            model.pedalEnabled = pedalEnabled
            model.pedalPosition = pedalPosition
            model.overlayPositionMode = overlayPositionMode == 1 ? 1 : 0
            model.capsLockEnabled = capsLockEnabled
            model.mouseEnabled = mouseEnabled
            model.mouseMode = mouseMode
            model.keyboardEnabled = keyboardEnabled
            model.keyboardMode = keyboardMode
            model.autoCopyToClipboard = autoCopyToClipboard
            model.historyEnabled = historyEnabled
            model.menuBarHistoryEnabled = menuBarHistoryEnabled
            model.maxHistoryCount = max(10, min(maxHistoryCount, 500))
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

    private func refreshPermissions() {
        accessibilityTrusted = AccessibilityHelper.isTrusted()
        micStatus = MicrophoneHelper.authorizationStatus()
    }

    private func statusBadge(_ ok: Bool) -> some View {
        Text(ok ? "Granted" : "Missing")
            .font(.system(size: 11, weight: .semibold))
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(ok ? Color.green.opacity(0.2) : Color.red.opacity(0.2))
            .cornerRadius(6)
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
