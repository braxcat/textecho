import AppKit
import Foundation

final class TextInjector {
    private let registersURL: URL
    private var registers: [String]
    private let registersQueue = DispatchQueue(label: "textecho.registers")

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        registersURL = home.appendingPathComponent(".textecho_registers.json")
        registers = Array(repeating: "", count: 9)
        loadRegisters()
    }

    func inject(_ text: String) {
        guard !text.isEmpty else { return }
        guard AppConfig.shared.model.autoCopyToClipboard else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        sendPasteKeystroke()
    }

    func captureClipboardToRegister(_ index: Int) {
        guard index >= 1 && index <= 9 else { return }
        let pasteboard = NSPasteboard.general
        if let text = pasteboard.string(forType: .string) {
            registersQueue.async {
                self.registers[index - 1] = text
                self.saveRegisters()
            }
        }
    }

    func clearRegisters() {
        registersQueue.async {
            self.registers = Array(repeating: "", count: 9)
            self.saveRegisters()
        }
    }

    func registersContext() -> String {
        return registersQueue.sync {
            var lines: [String] = []
            for (idx, value) in registers.enumerated() {
                if !value.isEmpty {
                    lines.append("[Register \(idx + 1)]\n\(value)")
                }
            }
            return lines.joined(separator: "\n\n")
        }
    }

    private func loadRegisters() {
        registersQueue.sync {
            guard let data = try? Data(contentsOf: registersURL),
                  let decoded = try? JSONDecoder().decode([String].self, from: data) else {
                return
            }
            if decoded.count == 9 {
                registers = decoded
            }
        }
    }

    private func saveRegisters() {
        if let data = try? JSONEncoder().encode(registers) {
            try? data.write(to: registersURL)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: registersURL.path)
        }
    }

    /// Send Cmd+V paste keystroke (public for pedal use)
    func sendPaste() {
        sendPasteKeystroke()
    }

    /// Send Return/Enter keystroke
    func sendEnter() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let returnKey = CGKeyCode(36) // Return
        let keyDown = CGEvent(keyboardEventSource: src, virtualKey: returnKey, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: src, virtualKey: returnKey, keyDown: false)
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    private func sendPasteKeystroke() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey = CGKeyCode(9) // V

        let cmdDown = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(55), keyDown: true)
        let vDown = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        let vUp = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        let cmdUp = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(55), keyDown: false)

        vDown?.flags = .maskCommand
        vUp?.flags = .maskCommand

        cmdDown?.post(tap: .cghidEventTap)
        vDown?.post(tap: .cghidEventTap)
        vUp?.post(tap: .cghidEventTap)
        cmdUp?.post(tap: .cghidEventTap)
    }
}
