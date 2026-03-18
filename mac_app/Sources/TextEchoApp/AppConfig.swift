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
        var triggerButton: Int
        var dictationKeyCode: Int
        var dictationModifiers: UInt
        var dictationLLMModifier: UInt
        var silenceDuration: Double
        var silenceThreshold: Double
        var sampleRate: Double
        var llmEnabled: Bool
        var llmModelPath: String
        var showMenuBarIcon: Bool
        var firstLaunch: Bool
        var pythonPath: String
        var daemonScriptsDir: String
        var transcriptionSocket: String
        var llmSocket: String
        var pedalEnabled: Bool
        var pedalPosition: Int // 0=left, 1=center, 2=right
    }

    private(set) var model = Model(
        triggerButton: 2,
        dictationKeyCode: 2,
        dictationModifiers: UInt(NSEvent.ModifierFlags.control.rawValue),
        dictationLLMModifier: UInt(NSEvent.ModifierFlags.shift.rawValue),
        silenceDuration: 2.5,
        silenceThreshold: 0.015,
        sampleRate: 16000,
        llmEnabled: false,
        llmModelPath: "",
        showMenuBarIcon: true,
        firstLaunch: true,
        pythonPath: AppConfig.defaultPythonPath(),
        daemonScriptsDir: AppConfig.defaultDaemonsDir(),
        transcriptionSocket: "/tmp/textecho_transcription.sock",
        llmSocket: "/tmp/textecho_llm.sock",
        pedalEnabled: true,
        pedalPosition: 1
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

        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]) {
            try? data.write(to: fileURL)
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
}
