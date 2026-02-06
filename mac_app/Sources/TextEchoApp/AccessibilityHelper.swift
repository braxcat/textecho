import ApplicationServices
import Foundation

enum AccessibilityHelper {
    static func requestIfNeeded() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }
}
