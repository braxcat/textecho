import AppKit
import AVFoundation
import SwiftUI

final class SettingsWindowController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let view = SettingsView()
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
    @State private var silenceDuration: String = String(AppConfig.shared.model.silenceDuration)
    @State private var silenceThreshold: String = String(AppConfig.shared.model.silenceThreshold)
    @State private var sampleRate: String = String(Int(AppConfig.shared.model.sampleRate))
    @State private var llmEnabled: Bool = AppConfig.shared.model.llmEnabled
    @State private var llmModelPath: String = AppConfig.shared.model.llmModelPath
    @State private var showMenuBarIcon: Bool = AppConfig.shared.model.showMenuBarIcon
    @State private var accessibilityTrusted: Bool = AccessibilityHelper.isTrusted()
    @State private var micStatus: AVAuthorizationStatus = MicrophoneHelper.authorizationStatus()
    @State private var pythonPath: String = AppConfig.shared.model.pythonPath
    @State private var scriptsDir: String = AppConfig.shared.model.daemonScriptsDir

    // WhisperKit model settings
    @State private var selectedWhisperModel: String = AppConfig.shared.model.whisperModel
    @State private var cachedModels: [String] = WhisperKitTranscriber.cachedModels()
    @State private var showManageModels: Bool = false
    @State private var downloadingModel: String? = nil

    // Input device
    @State private var selectedDeviceUID: String = AppConfig.shared.model.inputDeviceUID
    @State private var inputDevices: [(id: UInt32, uid: String, name: String)] = AudioRecorder.availableInputDevices()

    private let llmAvailable = AppConfig.shared.model.llmAvailable

    init() {
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
            VStack(alignment: .leading, spacing: 16) {
                Text("General")
                    .font(.system(size: 14, weight: .semibold))

                Picker("Mouse Button", selection: $triggerButtonChoice) {
                    Text("Left").tag(0)
                    Text("Right").tag(1)
                    Text("Middle").tag(2)
                    Text("Other…").tag(3)
                }
                .pickerStyle(.segmented)

                if triggerButtonChoice == 3 {
                    HStack {
                        Text("Mouse Button Number")
                        Spacer()
                        TextField("2", text: $triggerButton)
                            .frame(width: 80)
                    }
                }

                Divider()

                Text("Permissions")
                    .font(.system(size: 14, weight: .semibold))

                HStack {
                    Text("Accessibility")
                    Spacer()
                    statusBadge(accessibilityTrusted)
                }

                Button("Open Accessibility Settings") {
                    openSystemPreferences(anchor: "Privacy_Accessibility")
                }

                HStack {
                    Text("Microphone")
                    Spacer()
                    statusBadge(micStatus == .authorized)
                }

                Button("Open Microphone Settings") {
                    openSystemPreferences(anchor: "Privacy_Microphone")
                }

                Button("Refresh Permissions Status") {
                    refreshPermissions()
                }

                Divider()

                // Transcription Model section
                Text("Transcription Model")
                    .font(.system(size: 14, weight: .semibold))

                HStack {
                    Text("Active Model")
                    Spacer()
                    Picker("", selection: $selectedWhisperModel) {
                        ForEach(WhisperKitTranscriber.availableModelList, id: \.name) { model in
                            let cached = cachedModels.contains(model.name)
                            Text("\(model.displayName)\(cached ? "" : " (not downloaded)")")
                                .tag(model.name)
                        }
                    }
                    .frame(width: 240)
                }

                DisclosureGroup("Manage Models", isExpanded: $showManageModels) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(WhisperKitTranscriber.availableModelList, id: \.name) { model in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(model.displayName)
                                        .font(.system(size: 12, weight: .semibold))
                                    HStack(spacing: 4) {
                                        Text(model.size)
                                        Text("—")
                                        Text(model.description)
                                    }
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                }

                                Spacer()

                                if cachedModels.contains(model.name) {
                                    Text("Downloaded")
                                        .font(.system(size: 10))
                                        .foregroundColor(.green)

                                    Button("Delete") {
                                        try? WhisperKitTranscriber.deleteModel(model.name)
                                        cachedModels = WhisperKitTranscriber.cachedModels()
                                    }
                                    .font(.system(size: 11))
                                } else if downloadingModel == model.name {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Downloading...")
                                        .font(.system(size: 10))
                                        .foregroundColor(.orange)
                                } else {
                                    Button("Download") {
                                        downloadModel(model.name)
                                    }
                                    .font(.system(size: 11))
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .padding(.leading, 4)
                }

                Divider()

                Text("Key Bindings")
                    .font(.system(size: 14, weight: .semibold))

                HStack {
                    Text("Dictation Key (letter)")
                    Spacer()
                    TextField("D", text: $dictationKey)
                        .frame(width: 80)
                }

                Text("Dictation Modifiers")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)

                HStack(spacing: 12) {
                    Toggle("Ctrl", isOn: $dictationModCtrl)
                    Toggle("Opt", isOn: $dictationModOpt)
                    Toggle("Cmd", isOn: $dictationModCmd)
                    Toggle("Shift", isOn: $dictationModShift)
                }

                Text("LLM Extra Modifier (added on top of dictation modifiers)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)

                HStack(spacing: 12) {
                    Toggle("Ctrl", isOn: $llmModCtrl)
                    Toggle("Opt", isOn: $llmModOpt)
                    Toggle("Cmd", isOn: $llmModCmd)
                    Toggle("Shift", isOn: $llmModShift)
                }

                Divider()

                Text("Audio")
                    .font(.system(size: 14, weight: .semibold))

                HStack {
                    Text("Input Device")
                    Spacer()
                    Picker("", selection: $selectedDeviceUID) {
                        Text("System Default").tag("")
                        ForEach(inputDevices, id: \.uid) { device in
                            Text(device.name).tag(device.uid)
                        }
                    }
                    .frame(width: 240)

                    Button("Refresh") {
                        inputDevices = AudioRecorder.availableInputDevices()
                    }
                    .font(.system(size: 11))
                }

                HStack {
                    Text("Silence Duration (sec)")
                    Spacer()
                    TextField("2.5", text: $silenceDuration)
                        .frame(width: 80)
                }

                HStack {
                    Text("Silence Threshold")
                    Spacer()
                    TextField("0.015", text: $silenceThreshold)
                        .frame(width: 80)
                }

                HStack {
                    Text("Sample Rate")
                    Spacer()
                    TextField("16000", text: $sampleRate)
                        .frame(width: 80)
                }

                Divider()

                // LLM section — only show if module is installed
                if llmAvailable {
                    Text("LLM")
                        .font(.system(size: 14, weight: .semibold))

                    Toggle("Enable LLM", isOn: $llmEnabled)

                    HStack {
                        Text("LLM Model Path")
                        Spacer()
                        TextField("/path/to/model.gguf", text: $llmModelPath)
                            .frame(width: 260)
                    }

                    Divider()

                    Text("Python (LLM)")
                        .font(.system(size: 14, weight: .semibold))

                    HStack {
                        Text("Python Path")
                        Spacer()
                        TextField("/opt/homebrew/bin/python3", text: $pythonPath)
                            .frame(width: 260)
                    }

                    HStack {
                        Text("Daemons Dir")
                        Spacer()
                        TextField("/path/to/scripts", text: $scriptsDir)
                            .frame(width: 260)
                    }
                } else {
                    Text("LLM")
                        .font(.system(size: 14, weight: .semibold))

                    Text("LLM module not installed. Rebuild with: ./build_native_app.sh --with-llm")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Divider()

                Toggle("Show Menu Bar Icon", isOn: $showMenuBarIcon)

                Divider()

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
            cachedModels = WhisperKitTranscriber.cachedModels()
            inputDevices = AudioRecorder.availableInputDevices()
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

    private func downloadModel(_ modelName: String) {
        downloadingModel = modelName
        Task {
            let transcriber = WhisperKitTranscriber(
                modelName: modelName,
                idleTimeout: AppConfig.shared.model.whisperIdleTimeout
            )
            do {
                try await transcriber.preload()
            } catch {
                AppLogger.shared.error("Model download failed: \(error.localizedDescription)")
            }
            await MainActor.run {
                self.downloadingModel = nil
                self.cachedModels = WhisperKitTranscriber.cachedModels()
            }
        }
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
