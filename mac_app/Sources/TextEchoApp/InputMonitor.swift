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
}

final class InputMonitor {
    var onEvent: ((InputEvent) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

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

        let mask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.rightMouseUp.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
            | (1 << CGEventType.otherMouseUp.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

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
    }

    deinit {
        stop()
    }

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
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
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    private func handleOtherMouse(event: CGEvent, down: Bool) {
        let buttonNumber = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        handleMouseButton(button: buttonNumber, down: down)
    }

    private func handleMouseButton(button: Int, down: Bool) {
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

    private func modifierFlags(from stored: UInt) -> CGEventFlags {
        var flags: CGEventFlags = []
        if (stored & UInt(NSEvent.ModifierFlags.control.rawValue)) != 0 { flags.insert(.maskControl) }
        if (stored & UInt(NSEvent.ModifierFlags.option.rawValue)) != 0 { flags.insert(.maskAlternate) }
        if (stored & UInt(NSEvent.ModifierFlags.command.rawValue)) != 0 { flags.insert(.maskCommand) }
        if (stored & UInt(NSEvent.ModifierFlags.shift.rawValue)) != 0 { flags.insert(.maskShift) }
        return flags
    }
}
