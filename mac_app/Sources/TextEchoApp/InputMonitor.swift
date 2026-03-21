import AppKit
import Foundation

enum InputEvent {
    case triggerDown
    case triggerUp
    case dictateDown
    case dictateUp
    case dictateLLMDown
    case dictateLLMUp
    case settingsHotkey
    case escape
    case register(Int)
    case clearRegisters
    case capsLockChanged(Bool)
}

final class InputMonitor {
    var onEvent: ((InputEvent) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var configObserver: NSObjectProtocol?

    private var triggerButton: Int { AppConfig.shared.triggerButton }
    private var dictationKeyCode: Int { AppConfig.shared.dictationKeyCode }
    private var dictationModifiers: CGEventFlags {
        modifierFlags(from: AppConfig.shared.dictationModifiers)
    }
    private var dictationLLMModifier: CGEventFlags {
        modifierFlags(from: AppConfig.shared.dictationLLMModifier)
    }
    private var dictationActive = false
    private var dictationLLM = false

    func start() {
        guard eventTap == nil else { return }

        var mask: CGEventMask = 0
        mask |= (1 << CGEventType.leftMouseDown.rawValue)
        mask |= (1 << CGEventType.leftMouseUp.rawValue)
        mask |= (1 << CGEventType.rightMouseDown.rawValue)
        mask |= (1 << CGEventType.rightMouseUp.rawValue)
        mask |= (1 << CGEventType.otherMouseDown.rawValue)
        mask |= (1 << CGEventType.otherMouseUp.rawValue)
        mask |= (1 << CGEventType.keyDown.rawValue)
        mask |= (1 << CGEventType.keyUp.rawValue)
        mask |= (1 << CGEventType.flagsChanged.rawValue)

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, refcon in
                let monitor = Unmanaged<InputMonitor>.fromOpaque(refcon!).takeUnretainedValue()
                return monitor.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let eventTap else {
            AppLogger.shared.error("Failed to create event tap. Accessibility permission likely missing.")
            return
        }

        AppLogger.shared.info("Input monitor started (event tap active)")

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: eventTap, enable: true)

        setupConfigObserverIfNeeded()
        syncCapsLockStateIfNeeded()
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }
    }

    deinit {
        stop()
    }

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS disables the event tap if our callback takes too long — re-enable it.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                AppLogger.shared.info("Event tap was disabled by system, re-enabling")
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        // Neutralize Caps Lock side effect on regular typing when caps lock mode is active
        if AppConfig.shared.model.capsLockEnabled {
            neutralizeCapsLockForTyping(type: type, event: event)
        }

        switch type {
        case .otherMouseDown, .otherMouseUp:
            handleOtherMouse(event: event, down: type == .otherMouseDown)
        case .leftMouseDown, .leftMouseUp:
            handleMouseButton(button: 0, down: type == .leftMouseDown)
        case .rightMouseDown, .rightMouseUp:
            handleMouseButton(button: 1, down: type == .rightMouseDown)
        case .keyDown:
            handleKeyDown(event: event)
        case .keyUp:
            handleKeyUp(event: event)
        case .flagsChanged:
            handleFlagsChanged(event: event)
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    private func neutralizeCapsLockForTyping(type: CGEventType, event: CGEvent) {
        guard type == .keyDown || type == .keyUp else { return }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode != 57 else { return } // keep Caps Lock event itself untouched

        var flags = event.flags
        if flags.contains(.maskAlphaShift) {
            flags.remove(.maskAlphaShift)
            event.flags = flags
        }
    }

    private func handleOtherMouse(event: CGEvent, down: Bool) {
        let buttonNumber = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        handleMouseButton(button: buttonNumber, down: down)
    }

    private func handleMouseButton(button: Int, down: Bool) {
        guard AppConfig.shared.model.mouseEnabled else { return }
        if button == triggerButton {
            AppLogger.shared.info("Mouse trigger \(down ? "down" : "up") (button=\(button))")
            if down {
                onEvent?(.triggerDown)
            } else {
                onEvent?(.triggerUp)
            }
        }
    }

    private func handleKeyDown(event: CGEvent) {
        let flags = event.flags
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        if keyCode == 53 { // ESC
            onEvent?(.escape)
            return
        }

        let cmd = flags.contains(.maskCommand)
        let opt = flags.contains(.maskAlternate)

        if cmd && opt {
            switch keyCode {
            case 18: onEvent?(.register(1))
            case 19: onEvent?(.register(2))
            case 20: onEvent?(.register(3))
            case 21: onEvent?(.register(4))
            case 23: onEvent?(.register(5))
            case 22: onEvent?(.register(6))
            case 26: onEvent?(.register(7))
            case 28: onEvent?(.register(8))
            case 25: onEvent?(.register(9))
            case 29: onEvent?(.clearRegisters)
            case 49: onEvent?(.settingsHotkey) // space
            default: break
            }
        }

        guard AppConfig.shared.model.keyboardEnabled else { return }

        if keyCode == dictationKeyCode {
            let required = dictationModifiers
            let requiredSet = flags.contains(required)
            let llmSet = flags.contains(dictationLLMModifier)
            AppLogger.shared.info("Key trigger keyCode=\(keyCode) required=\(required.rawValue) flags=\(flags.rawValue) requiredSet=\(requiredSet) llmSet=\(llmSet)")
            if requiredSet && !dictationActive {
                dictationActive = true
                if llmSet {
                    dictationLLM = true
                    onEvent?(.dictateLLMDown)
                } else {
                    dictationLLM = false
                    onEvent?(.dictateDown)
                }
            }
        }
    }

    private func handleKeyUp(event: CGEvent) {
        guard AppConfig.shared.model.keyboardEnabled else { return }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if dictationActive && keyCode == dictationKeyCode {
            dictationActive = false
            if dictationLLM {
                onEvent?(.dictateLLMUp)
            } else {
                onEvent?(.dictateUp)
            }
        }
    }

    private func handleFlagsChanged(event: CGEvent) {
        guard AppConfig.shared.model.capsLockEnabled else { return }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == 57 else { return } // Caps Lock
        let isOn = event.flags.contains(.maskAlphaShift)
        AppLogger.shared.info("Caps Lock changed: \(isOn ? "ON" : "OFF")")
        onEvent?(.capsLockChanged(isOn))
    }

    private func setupConfigObserverIfNeeded() {
        guard configObserver == nil else { return }
        configObserver = NotificationCenter.default.addObserver(
            forName: .textechoConfigChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.syncCapsLockStateIfNeeded()
        }
    }

    private func syncCapsLockStateIfNeeded() {
        guard AppConfig.shared.model.capsLockEnabled else { return }
        onEvent?(.capsLockChanged(NSEvent.modifierFlags.contains(.capsLock)))
    }

    private func modifierFlags(from stored: UInt) -> CGEventFlags {
        var flags: CGEventFlags = []
        if (stored & UInt(NSEvent.ModifierFlags.control.rawValue)) != 0 { flags.insert(.maskControl) }
        if (stored & UInt(NSEvent.ModifierFlags.option.rawValue)) != 0 { flags.insert(.maskAlternate) }
        if (stored & UInt(NSEvent.ModifierFlags.command.rawValue)) != 0 { flags.insert(.maskCommand) }
        if (stored & UInt(NSEvent.ModifierFlags.shift.rawValue)) != 0 { flags.insert(.maskShift) }
        return flags
    }
}
