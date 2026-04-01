import AppKit
import Foundation

final class AppConfig {
    static let shared = AppConfig()

    private let fileURL: URL
    private let queue = DispatchQueue(label: "textecho.config")

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        fileURL = home.appendingPathComponent(".textecho_config")
        load()
    }

    struct Model: Codable {
        // Mouse button number (0=left, 1=right, 2=middle)
        var triggerButton: Int
        // Keyboard shortcut
        var dictationKeyCode: Int
        var dictationModifiers: UInt
        var dictationLLMModifier: UInt
        // Audio
        var silenceDuration: Double
        var silenceThreshold: Double
        var sampleRate: Double
        var silenceEnabled: Bool      // Auto-stop on silence
        // LLM
        var llmEnabled: Bool
        var llmModelPath: String
        // App
        var showMenuBarIcon: Bool
        var firstLaunch: Bool
        var pythonPath: String
        var daemonScriptsDir: String
        var transcriptionSocket: String
        var llmSocket: String
        // Stream Deck Pedal
        var pedalEnabled: Bool
        var pedalPosition: Int // 0=left, 1=center, 2=right
        // Magic Trackpad
        var trackpadEnabled: Bool
        var trackpadGesture: Int    // 0=forceClick, 1=rightClick
        var trackpadMode: Int       // 0=toggle, 1=hold
        // Overlay
        var overlayPositionMode: Int // 0=static bottom middle, 1=follow cursor
        // Transcription engine
        var transcriptionEngine: String  // "parakeet" or "whisper"
        // WhisperKit
        var whisperModel: String
        var whisperIdleTimeout: Int
        // Parakeet (FluidAudio)
        var parakeetModel: String  // "parakeet-tdt-v3" or "parakeet-tdt-v2"
        var inputDeviceUID: String  // empty = system default

        // --- Transcription Activation Modes ---
        var capsLockEnabled: Bool       // Caps Lock toggles recording
        var mouseEnabled: Bool          // Mouse button triggers recording
        var mouseMode: Int              // 0=toggle, 1=hold
        var keyboardEnabled: Bool       // Keyboard shortcut triggers recording
        var keyboardMode: Int           // 0=toggle, 1=hold

        // --- Behavior ---
        var autoCopyToClipboard: Bool   // Auto-paste transcription after recording
        var historyEnabled: Bool        // Save transcription history
        var menuBarHistoryEnabled: Bool // Show recent transcriptions in menu bar
        var maxHistoryCount: Int        // Max number of history entries to keep

        // --- Theme ---
        var themePreset: String         // "textecho", "cyber", "classic", "ocean", "sunset", "custom", or user preset name
        var colorRecording: String      // Hex color for recording state
        var colorProcessing: String     // Hex color for processing state
        var colorSuccess: String        // Hex color for success state
        var colorError: String          // Hex color for error state
        var colorLoading: String        // Hex color for loading state
        var colorWaveform: String       // Hex color for waveform
        var colorBgDark: String         // Hex color for dark background
        var colorBgLight: String        // Hex color for light background

        /// Whether the LLM daemon script is bundled in the app.
        var llmAvailable: Bool {
            if let resourcePath = Bundle.main.resourcePath {
                let path = (resourcePath as NSString).appendingPathComponent("llm_daemon.py")
                if FileManager.default.fileExists(atPath: path) { return true }
            }
            return ScriptLocator.locate(name: "llm_daemon.py") != nil
        }
    }

    private(set) var model = Model(
        triggerButton: 2,
        dictationKeyCode: 6,  // Z key — default Ctrl+Opt+Z
        dictationModifiers: UInt(NSEvent.ModifierFlags.control.rawValue | NSEvent.ModifierFlags.option.rawValue),
        dictationLLMModifier: UInt(NSEvent.ModifierFlags.shift.rawValue),
        silenceDuration: 2.5,
        silenceThreshold: 0.015,
        sampleRate: 16000,
        silenceEnabled: false,
        llmEnabled: false,
        llmModelPath: "",
        showMenuBarIcon: true,
        firstLaunch: true,
        pythonPath: AppConfig.defaultPythonPath(),
        daemonScriptsDir: AppConfig.defaultDaemonsDir(),
        transcriptionSocket: "/tmp/textecho_transcription.sock",
        llmSocket: "/tmp/textecho_llm.sock",
        pedalEnabled: false,
        pedalPosition: 1,
        trackpadEnabled: false,
        trackpadGesture: 0,
        trackpadMode: 1,
        overlayPositionMode: 0,
        transcriptionEngine: "parakeet",
        whisperModel: "openai_whisper-large-v3_turbo",
        whisperIdleTimeout: 0,
        parakeetModel: "parakeet-tdt-v2",
        inputDeviceUID: "",
        capsLockEnabled: false,
        mouseEnabled: true,
        mouseMode: 1,           // hold by default for mouse
        keyboardEnabled: true,
        keyboardMode: 0,        // toggle by default for keyboard
        autoCopyToClipboard: true,
        historyEnabled: true,
        menuBarHistoryEnabled: true,
        maxHistoryCount: 50,
        themePreset: "textecho",
        colorRecording: "#00E6FF",
        colorProcessing: "#8A5CF6",
        colorSuccess: "#4DD9A6",
        colorError: "#FF3333",
        colorLoading: "#FFC200",
        colorWaveform: "#00E6FF",
        colorBgDark: "#0A0A1A",
        colorBgLight: "#0F0F24"
    )

    var triggerButton: Int { queue.sync { model.triggerButton } }
    var dictationKeyCode: Int { queue.sync { model.dictationKeyCode } }
    var dictationModifiers: UInt { queue.sync { model.dictationModifiers } }
    var dictationLLMModifier: UInt { queue.sync { model.dictationLLMModifier } }
    var silenceDuration: Double { queue.sync { model.silenceDuration } }
    var silenceThreshold: Double { queue.sync { model.silenceThreshold } }
    var sampleRate: Double { queue.sync { model.sampleRate } }
    var llmEnabled: Bool { queue.sync { model.llmEnabled } }

    func update(_ mutate: (inout Model) -> Void) {
        queue.sync {
            mutate(&model)
            save()
        }
        NotificationCenter.default.post(name: .textechoConfigChanged, object: nil)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        var updated = model
        if let value = obj["trigger_button"] as? Int { updated.triggerButton = value }
        if let value = obj["dictation_keycode"] as? Int { updated.dictationKeyCode = value }
        if let value = obj["dictation_modifiers"] as? UInt { updated.dictationModifiers = value }
        if let value = obj["dictation_llm_modifier"] as? UInt { updated.dictationLLMModifier = value }
        if let value = obj["dictation_modifiers"] as? UInt64 { updated.dictationModifiers = UInt(value) }
        if let value = obj["dictation_llm_modifier"] as? UInt64 { updated.dictationLLMModifier = UInt(value) }
        if let value = obj["silence_duration"] as? Double { updated.silenceDuration = value }
        if let value = obj["silence_threshold"] as? Double { updated.silenceThreshold = value }
        if let value = obj["sample_rate"] as? Double { updated.sampleRate = value }
        if let v = obj["silence_enabled"] as? Bool { updated.silenceEnabled = v }
        if let value = obj["llm_enabled"] as? Bool { updated.llmEnabled = value }
        if let value = obj["llm_model_path"] as? String { updated.llmModelPath = value }
        if let value = obj["show_menu_bar_icon"] as? Bool { updated.showMenuBarIcon = value }
        if let value = obj["first_launch"] as? Bool { updated.firstLaunch = value }
        if let value = obj["python_path"] as? String { updated.pythonPath = value }
        if let value = obj["daemon_scripts_dir"] as? String { updated.daemonScriptsDir = value }
        if let value = obj["transcription_socket"] as? String { updated.transcriptionSocket = value }
        if let value = obj["llm_socket"] as? String { updated.llmSocket = value }
        if let value = obj["pedal_enabled"] as? Bool { updated.pedalEnabled = value }
        if let value = obj["pedal_position"] as? Int { updated.pedalPosition = value }
        if let v = obj["trackpad_enabled"] as? Bool { updated.trackpadEnabled = v }
        if let v = obj["trackpad_gesture"] as? Int { updated.trackpadGesture = max(0, min(v, 1)) }
        if let v = obj["trackpad_mode"] as? Int { updated.trackpadMode = max(0, min(v, 1)) }
        if let value = obj["overlay_position_mode"] as? Int { updated.overlayPositionMode = value == 1 ? 1 : 0 }
        if let v = obj["transcription_engine"] as? String { updated.transcriptionEngine = v }
        if let value = obj["whisper_model"] as? String { updated.whisperModel = WhisperKitTranscriber.migrateModelName(value) }
        if let value = obj["whisper_idle_timeout"] as? Int { updated.whisperIdleTimeout = value == 0 ? 0 : max(60, min(value, 86400)) }
        if let v = obj["parakeet_model"] as? String { updated.parakeetModel = v }
        if let value = obj["input_device_uid"] as? String { updated.inputDeviceUID = value }

        // New activation mode fields
        if let v = obj["caps_lock_enabled"] as? Bool { updated.capsLockEnabled = v }
        if let v = obj["mouse_enabled"] as? Bool { updated.mouseEnabled = v }
        if let v = obj["mouse_mode"] as? Int { updated.mouseMode = max(0, min(v, 1)) }
        if let v = obj["keyboard_enabled"] as? Bool { updated.keyboardEnabled = v }
        if let v = obj["keyboard_mode"] as? Int { updated.keyboardMode = max(0, min(v, 1)) }

        // Behavior fields
        if let v = obj["auto_copy_to_clipboard"] as? Bool { updated.autoCopyToClipboard = v }
        if let v = obj["history_enabled"] as? Bool { updated.historyEnabled = v }
        if let v = obj["menu_bar_history_enabled"] as? Bool { updated.menuBarHistoryEnabled = v }
        if let v = obj["max_history_count"] as? Int { updated.maxHistoryCount = max(10, min(v, 500)) }

        // Theme fields
        if let v = obj["theme_preset"] as? String { updated.themePreset = v }
        if let v = obj["color_recording"] as? String { updated.colorRecording = v }
        if let v = obj["color_processing"] as? String { updated.colorProcessing = v }
        if let v = obj["color_success"] as? String { updated.colorSuccess = v }
        if let v = obj["color_error"] as? String { updated.colorError = v }
        if let v = obj["color_loading"] as? String { updated.colorLoading = v }
        if let v = obj["color_waveform"] as? String { updated.colorWaveform = v }
        if let v = obj["color_bg_dark"] as? String { updated.colorBgDark = v }
        if let v = obj["color_bg_light"] as? String { updated.colorBgLight = v }

        // Migrate from legacy transcription_mode if new activation fields not yet in config
        if obj["caps_lock_enabled"] == nil, let v = obj["transcription_mode"] as? Int {
            updated.capsLockEnabled = v == 2
            updated.mouseEnabled = v != 2
            updated.keyboardEnabled = v != 2
            updated.mouseMode = v == 1 ? 1 : 0
            updated.keyboardMode = v == 1 ? 1 : 0
        }

        model = updated
    }

    private func save() {
        var dict: [String: Any] = [:]
        if let data = try? Data(contentsOf: fileURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            dict = existing
        }

        dict["trigger_button"] = model.triggerButton
        dict["dictation_keycode"] = model.dictationKeyCode
        dict["dictation_modifiers"] = model.dictationModifiers
        dict["dictation_llm_modifier"] = model.dictationLLMModifier
        dict["silence_duration"] = model.silenceDuration
        dict["silence_threshold"] = model.silenceThreshold
        dict["sample_rate"] = model.sampleRate
        dict["silence_enabled"] = model.silenceEnabled
        dict["llm_enabled"] = model.llmEnabled
        dict["llm_model_path"] = model.llmModelPath
        dict["show_menu_bar_icon"] = model.showMenuBarIcon
        dict["first_launch"] = model.firstLaunch
        dict["python_path"] = model.pythonPath
        dict["daemon_scripts_dir"] = model.daemonScriptsDir
        dict["transcription_socket"] = model.transcriptionSocket
        dict["llm_socket"] = model.llmSocket
        dict["pedal_enabled"] = model.pedalEnabled
        dict["pedal_position"] = model.pedalPosition
        dict["trackpad_enabled"] = model.trackpadEnabled
        dict["trackpad_gesture"] = model.trackpadGesture
        dict["trackpad_mode"] = model.trackpadMode
        dict["overlay_position_mode"] = model.overlayPositionMode
        dict["transcription_engine"] = model.transcriptionEngine
        dict["whisper_model"] = model.whisperModel
        dict["whisper_idle_timeout"] = model.whisperIdleTimeout
        dict["parakeet_model"] = model.parakeetModel
        dict["input_device_uid"] = model.inputDeviceUID
        dict["caps_lock_enabled"] = model.capsLockEnabled
        dict["mouse_enabled"] = model.mouseEnabled
        dict["mouse_mode"] = model.mouseMode
        dict["keyboard_enabled"] = model.keyboardEnabled
        dict["keyboard_mode"] = model.keyboardMode
        dict["auto_copy_to_clipboard"] = model.autoCopyToClipboard
        dict["history_enabled"] = model.historyEnabled
        dict["menu_bar_history_enabled"] = model.menuBarHistoryEnabled
        dict["max_history_count"] = model.maxHistoryCount
        dict["theme_preset"] = model.themePreset
        dict["color_recording"] = model.colorRecording
        dict["color_processing"] = model.colorProcessing
        dict["color_success"] = model.colorSuccess
        dict["color_error"] = model.colorError
        dict["color_loading"] = model.colorLoading
        dict["color_waveform"] = model.colorWaveform
        dict["color_bg_dark"] = model.colorBgDark
        dict["color_bg_light"] = model.colorBgLight

        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private static func defaultPythonPath() -> String {
        if let resourcePath = Bundle.main.resourcePath {
            let bundled = (resourcePath as NSString).appendingPathComponent("venv/bin/python3")
            if FileManager.default.isExecutableFile(atPath: bundled) {
                return bundled
            }
        }
        // Fall back to specific Python versions known to work (3.13+ has tiktoken crashes)
        for path in ["/opt/homebrew/bin/python3.12", "/opt/homebrew/bin/python3.11", "/usr/bin/python3"] {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return "/opt/homebrew/bin/python3"
    }

    private static func defaultDaemonsDir() -> String {
        if let resourcePath = Bundle.main.resourcePath {
            return resourcePath
        }
        return FileManager.default.currentDirectoryPath
    }
}

extension Notification.Name {
    static let textechoConfigChanged = Notification.Name("TextEchoConfigChanged")
    static let textechoAccessibilityFailed = Notification.Name("TextEchoAccessibilityFailed")
}
